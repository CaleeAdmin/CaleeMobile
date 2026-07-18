"""Guard against a "promote to main" pull request accidentally opened against
`dev` (the PR #473 class of mistake: a PR *titled* a main promotion whose actual
base branch was `dev`, so the change never reached `main`).

Pure, unit-tested logic (title in, decision out) so the contract is verifiable
without any live GitHub API. The workflow (.github/workflows/promote-to-main-guard.yml)
runs `selftest` first, then `evaluate` against the real PR's title + base ref.

Detection: a title reads as a main promotion when it mentions promoting
("promote"/"promotion") AND names `main` as the target ("to main", "into main",
"-> main", or a standalone `main`). Such a PR is only a *mistake* when its base
branch is `dev` (or any non-`main` integration branch) -- a genuine promotion
must target `main`. Titles that merely contain "main" (e.g. "fix main menu") or
merely "promote" (e.g. "promote to stage") do NOT trip the guard.
"""

from __future__ import annotations

import argparse
import os
import re
import sys

# "promote" / "promotion" anywhere (case-insensitive).
_PROMOTE_RE = re.compile(r"promot(?:e|ion|ing)", re.IGNORECASE)
# `main` as a promotion TARGET: "to/into/onto main", "-> main", "= > main",
# or a standalone word `main`. Word-boundaried so "maintenance" never matches.
_MAIN_TARGET_RE = re.compile(r"(?:\bto\b|\binto\b|\bonto\b|->|=>|:)?\s*\bmain\b", re.IGNORECASE)

# Base branches on which a "promote to main" PR is a mistake. `main` itself is
# the correct target, so a promotion PR based on `main` is never flagged.
NON_MAIN_INTEGRATION_BASES = frozenset({"dev", "stage", "staging", "develop", "development"})


def looks_like_main_promotion(title: "str | None") -> bool:
    """True when the title reads as promoting something to `main`."""
    if not title:
        return False
    return bool(_PROMOTE_RE.search(title) and _MAIN_TARGET_RE.search(title))


def classify(title: "str | None", base_ref: "str | None") -> "tuple[bool, str]":
    """Return (is_violation, message).

    A violation is a main-promotion-titled PR whose base is a non-`main`
    integration branch. Everything else passes.
    """
    base = (base_ref or "").strip()
    if not looks_like_main_promotion(title):
        return False, "Title does not read as a promote-to-main PR; guard not applicable."
    if base == "main":
        return False, "Promote-to-main PR correctly targets `main`."
    if base in NON_MAIN_INTEGRATION_BASES:
        return True, (
            f"This PR is titled as a promotion to `main` but its base branch is `{base}`. "
            f"A workflow/file only reaches `main` when the PR's base IS `main`; a promotion "
            f"merged into `{base}` never lands on `main` (this is the PR #473 mistake). "
            f"Retarget this PR's base branch to `main`."
        )
    # Titled a main promotion but based on some other (feature) branch: not the
    # integration-branch mistake this guard is for -- don't block.
    return False, f"Promote-to-main title with non-integration base `{base}`; guard not applicable."


# --------------------------------------------------------------------------
# selftest -- the regression coverage the workflow runs before evaluating
# --------------------------------------------------------------------------

_CASES = [
    # (title, base_ref, expected_violation)
    ("Promote selector-contract cross-repo dispatch to main (P10)", "dev", True),   # the #473 bug
    ("Promote selector-contract cross-repo dispatch to main", "main", False),        # correct target
    ("Promote reminder feature into main", "stage", True),
    ("promotion of dispatch workflow -> main", "dev", True),
    ("Promote reminders to stage", "dev", False),          # promote, but not to main
    ("Fix main menu crash", "dev", False),                 # main, but not a promotion
    ("Add maintenance banner", "dev", False),              # "maintenance" != main
    ("Isolate calendar reminders across sessions", "dev", False),  # neither
    ("Promote build to main", "feature/x", False),          # not an integration base
    ("", "dev", False),
    (None, "dev", False),
    ("Promote to Main", "DEV", False),                      # base compared exactly; DEV != dev -> not flagged
]


def _selftest() -> int:
    failures = []
    for title, base, expected in _CASES:
        got, _msg = classify(title, base)
        if got != expected:
            failures.append(f"classify({title!r}, {base!r}) = {got}, expected {expected}")
    if failures:
        print("promote_guard selftest FAILED:", file=sys.stderr)
        for f in failures:
            print("  - " + f, file=sys.stderr)
        return 1
    print(f"promote_guard selftest OK ({len(_CASES)} cases).")
    return 0


def main(argv: "list[str] | None" = None) -> int:
    parser = argparse.ArgumentParser(description="Promote-to-main PR-base guard.")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("selftest", help="Run the built-in regression cases.")
    p_eval = sub.add_parser("evaluate", help="Evaluate a PR title + base ref; exit 1 on violation.")
    p_eval.add_argument("--title", default=os.environ.get("PR_TITLE", ""))
    p_eval.add_argument("--base", default=os.environ.get("PR_BASE_REF", ""))
    args = parser.parse_args(argv)

    if args.cmd == "selftest":
        return _selftest()

    violation, message = classify(args.title, args.base)
    print(message)
    if violation:
        print("::error title=Promote-to-main guard::" + message)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
