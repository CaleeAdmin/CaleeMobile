#!/usr/bin/env python3
"""Tiered Flutter CI: classification + aggregate-gate decision (fail closed).

Standard-library only, same convention as the other scripts in this
directory. Three CI-facing commands plus their own tests:

  classify  -- decide `promotion` / `sensitive` for the current event from
               environment variables (EVENT_NAME, HEAD_REF, BASE_REF,
               HEAD_REPO, REPOSITORY, CHANGED_FILES_PATH) and append both
               outputs to $GITHUB_OUTPUT. Any missing/inconsistent input is
               a hard error: the change-scope job then FAILS, which the
               fail-closed job conditions and the gate below translate into
               "run full validation AND fail the gate", never a silent skip.

  decide    -- the "Flutter CI gate" aggregate verdict, from environment
               variables (EVENT_NAME, CHANGE_SCOPE_RESULT, PROMOTION,
               SENSITIVE, ANALYZE_RESULT, ANDROID_RESULT). Exit 0 only for
               an explicitly recognised PASS shape; every other combination
               (classifier failure, missing/unrecognised classifier output,
               failed job, cancelled job, unexpected skip) exits 1.

  contract  -- workflow-contract check over the raw text of
               .github/workflows/flutter-ci.yml proving the YAML wiring
               matches the fail-closed design (heavy jobs re-run on
               classifier failure, promotion requires the same-repository
               condition, the gate exists / always() / needs all three).

  selftest  -- deterministic decision-table tests for classify + decide
               (all the promotion / fork / hotfix / failure-mode cases).

The PASS/FAIL rules encoded in `decide`:

  * change-scope did not succeed                  -> FAIL (fail closed)
  * promotion/sensitive not exactly true/false    -> FAIL (fail closed)
  * pull_request with promotion=true              -> analyze/android may be
    skipped (the intentional promotion fast path) or success; anything
    else fails
  * every other event/classification              -> analyze/android must
    BOTH be success; a skip here is unexpected and FAILS
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "flutter-ci.yml"

# A change to any of these can alter the packaged release manifest /
# permission surface, so the PR release-AAB permission gate must run.
SENSITIVE_PREFIXES = ("android/",)
SENSITIVE_FILES = (
    "pubspec.yaml",
    "pubspec.lock",
    "scripts/check_android_release_permissions.sh",
    "scripts/fetch_bundletool.sh",
    ".github/workflows/flutter-ci.yml",
    ".github/scripts/flutter_ci_tiering.py",
)

PROMOTIONS = (("dev", "stage"), ("stage", "main"))


def _bool_str(value: bool) -> str:
    return "true" if value else "false"


# --- classify ---------------------------------------------------------------

def classify(env: dict, changed_files: "list[str] | None") -> "tuple[bool, bool]":
    """Return (promotion, sensitive). Raises ValueError on bad input."""
    event = env.get("EVENT_NAME", "")
    if not event:
        raise ValueError("EVENT_NAME is not set")
    if event != "pull_request":
        # push / workflow_dispatch always take the full path.
        return False, True

    head_ref = env.get("HEAD_REF", "")
    base_ref = env.get("BASE_REF", "")
    head_repo = env.get("HEAD_REPO", "")
    repository = env.get("REPOSITORY", "")
    if not head_ref or not base_ref or not repository:
        raise ValueError("pull_request event but HEAD_REF/BASE_REF/REPOSITORY missing")
    # SECURITY: the promotion fast path is only for THIS repository's own
    # dev/stage branches. A fork can name its branches dev/stage too; a fork
    # PR must never be classified as a trusted promotion. An empty HEAD_REPO
    # is treated as untrusted, never as a match.
    same_repo = bool(head_repo) and head_repo == repository
    promotion = same_repo and (head_ref, base_ref) in PROMOTIONS

    if changed_files is None:
        raise ValueError("pull_request event but no changed-files list was provided")
    sensitive = False
    for name in changed_files:
        name = name.strip()
        if not name:
            continue
        if name in SENSITIVE_FILES or any(name.startswith(p) for p in SENSITIVE_PREFIXES):
            sensitive = True
            break
    return promotion, sensitive


def cmd_classify() -> int:
    env = dict(os.environ)
    changed: "list[str] | None" = None
    if env.get("EVENT_NAME") == "pull_request":
        path = env.get("CHANGED_FILES_PATH", "")
        if not path or not Path(path).is_file():
            print("classify: CHANGED_FILES_PATH missing or not a file", file=sys.stderr)
            return 1
        changed = Path(path).read_text(encoding="utf-8").splitlines()
    try:
        promotion, sensitive = classify(env, changed)
    except ValueError as exc:
        print(f"classify: {exc}", file=sys.stderr)
        return 1
    out_path = env.get("GITHUB_OUTPUT")
    if not out_path:
        print("classify: GITHUB_OUTPUT is not set", file=sys.stderr)
        return 1
    with open(out_path, "a", encoding="utf-8") as f:
        f.write(f"promotion={_bool_str(promotion)}\n")
        f.write(f"sensitive={_bool_str(sensitive)}\n")
    print(f"classify: promotion={_bool_str(promotion)} sensitive={_bool_str(sensitive)}")
    return 0


# --- decide (the aggregate gate) --------------------------------------------

def decide(env: dict) -> "tuple[bool, str]":
    """Return (passed, reason)."""
    event = env.get("EVENT_NAME", "")
    scope = env.get("CHANGE_SCOPE_RESULT", "")
    promotion = env.get("PROMOTION", "")
    sensitive = env.get("SENSITIVE", "")
    analyze = env.get("ANALYZE_RESULT", "")
    android = env.get("ANDROID_RESULT", "")

    if not event:
        return False, "FAIL: EVENT_NAME missing"
    if scope != "success":
        return False, (
            f"FAIL: the change-scope classifier did not succeed (result={scope!r}). "
            "A classification failure can never reduce validation: the heavy jobs "
            "were forced to run anyway, and this gate fails closed regardless of "
            "their results."
        )
    if promotion not in ("true", "false") or sensitive not in ("true", "false"):
        return False, (
            f"FAIL: classifier outputs missing/unrecognised "
            f"(promotion={promotion!r}, sensitive={sensitive!r})"
        )

    promotion_fast_path = event == "pull_request" and promotion == "true"
    allowed = ("success", "skipped") if promotion_fast_path else ("success",)
    for name, result in (("Format, Analyze & Test", analyze), ("Android debug build", android)):
        if result in allowed:
            continue
        if result == "skipped":
            return False, f"FAIL: required job {name!r} was UNEXPECTEDLY skipped"
        return False, f"FAIL: required job {name!r} result={result!r}"

    if promotion_fast_path:
        return True, (
            "PASS: standard same-repository promotion PR — the heavy jobs were "
            "intentionally skipped; the promoted commits already passed full PR "
            "CI and the destination-branch push re-verifies the release build."
        )
    return True, "PASS: all applicable validation succeeded"


def cmd_decide() -> int:
    passed, reason = decide(dict(os.environ))
    print(reason)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write("### Flutter CI gate\n\n" + reason + "\n")
    return 0 if passed else 1


# --- contract ---------------------------------------------------------------

def contract_problems(text: str) -> "list[str]":
    problems: "list[str]" = []

    def require(needle: str, why: str) -> None:
        if needle not in text:
            problems.append(f"missing {needle!r}: {why}")

    # Fail-closed job wiring: both heavy jobs must run whenever the
    # classifier did NOT succeed, and must not be dropped by a cancelled/
    # failed needs-chain silently.
    if text.count("needs.change-scope.result != 'success'") < 2:
        problems.append(
            "both heavy jobs must run when change-scope did not succeed "
            "(expected `needs.change-scope.result != 'success'` in both job ifs)"
        )
    if text.count("!cancelled()") < 2:
        problems.append(
            "both heavy jobs must use !cancelled() so a failed classifier still "
            "lets them run (a bare `if:` on a failed needs-chain silently skips)"
        )
    # Same-repository promotion requirement.
    require(
        "HEAD_REPO: ${{ github.event.pull_request.head.repo.full_name }}",
        "promotion classification must receive the PR head repository via env",
    )
    require(
        "REPOSITORY: ${{ github.repository }}",
        "promotion classification must compare against this repository",
    )
    # The aggregate gate.
    require("flutter-ci-gate:", "the always-resolved aggregate gate job must exist")
    require("name: Flutter CI gate", "the gate's stable check name must not drift")
    m = re.search(r"flutter-ci-gate:.*?steps:", text, re.DOTALL)
    if not m:
        problems.append("could not locate the flutter-ci-gate job block")
    else:
        block = m.group(0)
        if "if: ${{ always() }}" not in block:
            problems.append("flutter-ci-gate must run with `if: ${{ always() }}`")
        if not re.search(r"needs:\s*\[change-scope, analyze-and-test, android-debug-build\]", block):
            problems.append("flutter-ci-gate must need all three upstream jobs")
        if "continue-on-error" in block:
            problems.append("flutter-ci-gate must never use continue-on-error")
    # The gate decision itself must come from this script (unit-tested table),
    # not an ad-hoc inline expression.
    require(
        "flutter_ci_tiering.py decide",
        "the gate verdict must use the unit-tested decision table",
    )
    require(
        "flutter_ci_tiering.py selftest",
        "the decision table's selftest must run in CI",
    )
    return problems


def cmd_contract() -> int:
    text = WORKFLOW.read_text(encoding="utf-8")
    problems = contract_problems(text)
    if problems:
        print("flutter-ci workflow contract FAILED:")
        for p in problems:
            print(f"  - {p}")
        return 1
    print("flutter-ci workflow contract OK")
    return 0


# --- selftest ---------------------------------------------------------------

def cmd_selftest() -> int:
    failures: "list[str]" = []

    def check(name: str, ok: bool) -> None:
        print(f"  {'PASS' if ok else 'FAIL'}: {name}")
        if not ok:
            failures.append(name)

    repo = "CaleeAdmin/CaleeMobile"
    fork = "fork-owner/CaleeMobile"

    def cls(event, head=None, base=None, head_repo=None, files=None):
        env = {"EVENT_NAME": event, "REPOSITORY": repo}
        if head is not None:
            env["HEAD_REF"] = head
        if base is not None:
            env["BASE_REF"] = base
        if head_repo is not None:
            env["HEAD_REPO"] = head_repo
        return classify(env, files)

    print("selftest: promotion recognition requires SAME-REPOSITORY head")
    check("same-repo dev->stage is promotion",
          cls("pull_request", "dev", "stage", repo, ["lib/main.dart"]) == (True, False))
    check("same-repo stage->main is promotion",
          cls("pull_request", "stage", "main", repo, ["lib/main.dart"]) == (True, False))
    check("fork dev->stage is NOT promotion",
          cls("pull_request", "dev", "stage", fork, ["lib/main.dart"]) == (False, False))
    check("fork stage->main is NOT promotion",
          cls("pull_request", "stage", "main", fork, ["lib/main.dart"]) == (False, False))
    check("empty head-repo is NOT promotion",
          cls("pull_request", "dev", "stage", "", ["lib/main.dart"]) == (False, False))

    print("selftest: non-promotion PR shapes")
    check("feature->dev is not promotion",
          cls("pull_request", "feature-x", "dev", repo, ["lib/a.dart"]) == (False, False))
    check("feature->stage (direct) is not promotion",
          cls("pull_request", "feature-x", "stage", repo, ["lib/a.dart"]) == (False, False))
    check("hotfix->main (direct) is not promotion",
          cls("pull_request", "hotfix-y", "main", repo, ["lib/a.dart"]) == (False, False))
    check("main->stage reversed is not promotion",
          cls("pull_request", "main", "stage", repo, ["lib/a.dart"]) == (False, False))

    print("selftest: sensitivity from changed files")
    check("dart-only PR is not sensitive",
          cls("pull_request", "f", "dev", repo, ["lib/a.dart", "test/b.dart"]) == (False, False))
    check("android manifest change is sensitive",
          cls("pull_request", "f", "dev", repo, ["android/app/src/main/AndroidManifest.xml"])[1])
    check("pubspec.yaml change is sensitive",
          cls("pull_request", "f", "dev", repo, ["pubspec.yaml"])[1])
    check("pubspec.lock change is sensitive",
          cls("pull_request", "f", "dev", repo, ["pubspec.lock"])[1])
    check("permission-script change is sensitive",
          cls("pull_request", "f", "dev", repo, ["scripts/check_android_release_permissions.sh"])[1])
    check("workflow change is sensitive",
          cls("pull_request", "f", "dev", repo, [".github/workflows/flutter-ci.yml"])[1])
    check("this script's change is sensitive",
          cls("pull_request", "f", "dev", repo, [".github/scripts/flutter_ci_tiering.py"])[1])
    check("prefix must not false-positive (androidx.dart)",
          not cls("pull_request", "f", "dev", repo, ["lib/androidx.dart"])[1])

    print("selftest: non-PR events always take the full path")
    check("push classifies promotion=false sensitive=true",
          cls("push") == (False, True))
    check("workflow_dispatch classifies promotion=false sensitive=true",
          cls("workflow_dispatch") == (False, True))

    print("selftest: classify fails closed on missing input")
    for name, env, files in (
        ("missing EVENT_NAME", {"REPOSITORY": repo}, ["a"]),
        ("PR without refs", {"EVENT_NAME": "pull_request", "REPOSITORY": repo}, ["a"]),
        ("PR without changed files", {"EVENT_NAME": "pull_request", "HEAD_REF": "f",
                                      "BASE_REF": "dev", "HEAD_REPO": repo,
                                      "REPOSITORY": repo}, None),
    ):
        try:
            classify(env, files)
            check(f"{name} raises", False)
        except ValueError:
            check(f"{name} raises", True)

    print("selftest: gate decision table")

    def d(event, scope, promotion, sensitive, analyze, android):
        return decide({
            "EVENT_NAME": event, "CHANGE_SCOPE_RESULT": scope,
            "PROMOTION": promotion, "SENSITIVE": sensitive,
            "ANALYZE_RESULT": analyze, "ANDROID_RESULT": android,
        })[0]

    # Intentional PASS shapes.
    check("normal PR all-success passes",
          d("pull_request", "success", "false", "false", "success", "success"))
    check("sensitive PR all-success passes",
          d("pull_request", "success", "false", "true", "success", "success"))
    check("promotion PR with both jobs skipped passes",
          d("pull_request", "success", "true", "false", "skipped", "skipped"))
    check("stage/main push all-success passes",
          d("push", "success", "false", "true", "success", "success"))
    check("workflow_dispatch all-success passes",
          d("workflow_dispatch", "success", "false", "true", "success", "success"))
    # Classifier failure / bad output => FAIL even if everything else ran green.
    check("classifier failure fails even with green jobs",
          not d("pull_request", "failure", "false", "false", "success", "success"))
    check("classifier cancelled fails",
          not d("pull_request", "cancelled", "false", "false", "success", "success"))
    check("classifier skipped fails",
          not d("pull_request", "skipped", "false", "false", "success", "success"))
    check("classifier failure + heavy jobs skipped fails (never green by skip)",
          not d("pull_request", "failure", "", "", "skipped", "skipped"))
    check("missing promotion output fails",
          not d("pull_request", "success", "", "false", "success", "success"))
    check("unrecognised promotion output fails",
          not d("pull_request", "success", "yes", "false", "success", "success"))
    check("missing sensitive output fails",
          not d("pull_request", "success", "false", "", "success", "success"))
    # Required-job failures.
    check("failed analyze fails",
          not d("pull_request", "success", "false", "false", "failure", "success"))
    check("failed android fails",
          not d("pull_request", "success", "false", "false", "success", "failure"))
    check("cancelled android fails",
          not d("pull_request", "success", "false", "false", "success", "cancelled"))
    check("failed job on a promotion PR fails (skip-or-success only)",
          not d("pull_request", "success", "true", "false", "failure", "skipped"))
    # Unexpected skips.
    check("unexpected skip on a normal PR fails",
          not d("pull_request", "success", "false", "false", "success", "skipped"))
    check("unexpected skip on a push fails",
          not d("push", "success", "false", "true", "skipped", "success"))
    check("promotion=true on a push does NOT allow skips",
          not d("push", "success", "true", "true", "skipped", "skipped"))

    print("selftest: workflow contract holds for the real workflow file")
    real_problems = contract_problems(WORKFLOW.read_text(encoding="utf-8"))
    for p in real_problems:
        print(f"    contract problem: {p}")
    check("contract check passes on flutter-ci.yml", not real_problems)
    check("contract check rejects a gutted workflow",
          bool(contract_problems("jobs: {}")))

    if failures:
        print(f"\nflutter_ci_tiering selftest FAILED ({len(failures)} case(s))")
        return 1
    print("\nflutter_ci_tiering selftest passed.")
    return 0


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in ("classify", "decide", "contract", "selftest"):
        print(__doc__)
        return 2
    return {"classify": cmd_classify, "decide": cmd_decide,
            "contract": cmd_contract, "selftest": cmd_selftest}[sys.argv[1]]()


if __name__ == "__main__":
    sys.exit(main())
