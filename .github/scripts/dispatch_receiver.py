# VENDORED COPY -- authoritative, unit-tested source of truth lives at
# CaleeMobile-Regression/ui/dispatch_receiver.py (see ui/test_dispatch_receiver.py).
# Keep this file byte-for-byte in sync with that module; it is vendored here
# only so the sender workflow can run it without checking out that repo
# (the dispatch token carries Actions:write, not Contents:read).
"""Parse and validate a cross-repo workflow_dispatch response and the resulting
CaleeMobile-Regression selector-contract run (Priority 3).

The CaleeMobile "Trigger selector contract" workflow POSTs a workflow_dispatch
to this repository's ci.yml. This module is the tested logic the sender uses to
turn that dispatch into a *verified* receiver result:

  1. parse the dispatch response body directly -- when it carries the created
     run's id/url, use them (no polling needed);
  2. otherwise fall back to correlation-id matching against the recent
     workflow_dispatch runs (the run name embeds ``[corr:<id>]``);
  3. either way, the run MUST belong to CaleeMobile-Regression -- a run in any
     other repository is rejected;
  4. the receiver's ``selector-contract`` job MUST conclude success;
  5. the resulting ``selector-contract-result`` artifact's id + digest are
     recorded.

All functions here are pure (JSON in, decision out) so the contract is unit
tested without any live GitHub API. The CLI (``main``) is the thin adapter the
workflow calls, reading a JSON file / stdin and emitting ``key=value`` lines
suitable for ``>> "$GITHUB_OUTPUT"``.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from typing import Any

RECEIVER_REPO = "CaleeAdmin/CaleeMobile-Regression"
# The receiver ci.yml job that gates the selector contract. Matched by a
# case-insensitive substring of the job's display name so a cosmetic rename of
# the "(must pass before UI analysis)" suffix does not silently stop enforcing
# it. Keep in sync with ci.yml's `selector-contract` job `name:`.
SELECTOR_JOB_NAME_SUBSTRING = "selector contract"
ARTIFACT_NAME = "selector-contract-result"


@dataclass
class DispatchResult:
    run_id: "str | None" = None
    run_url: "str | None" = None
    html_url: "str | None" = None
    source: "str | None" = None  # "response" | "correlation" | None

    @property
    def resolved(self) -> bool:
        return bool(self.run_id)


def _load(value: "str | None") -> "Any":
    """Parse a JSON string that may be empty/whitespace (a 204 body) -> None."""
    if value is None:
        return None
    text = value.strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


def _s(value: "Any") -> "str | None":
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def parse_dispatch_response(body: "str | None") -> DispatchResult:
    """Parse the workflow_dispatch response body directly.

    GitHub's current endpoint, when it returns a body, includes the created
    run's id + urls. Accepts the documented ``workflow_run_id``/``run_url``/
    ``html_url`` shape as well as a bare run object (``id``/``url``/``html_url``).
    An empty body (the older 204 behaviour) yields an unresolved result, so the
    caller falls back to correlation polling.
    """
    data = _load(body)
    if not isinstance(data, dict):
        return DispatchResult()
    run_id = _s(data.get("workflow_run_id")) or _s(data.get("run_id")) or _s(data.get("id"))
    run_url = _s(data.get("run_url")) or _s(data.get("url"))
    html_url = _s(data.get("html_url"))
    if not run_id:
        return DispatchResult()
    return DispatchResult(run_id=run_id, run_url=run_url, html_url=html_url, source="response")


def run_belongs_to_receiver(run: "Any", expected_repo: str = RECEIVER_REPO) -> bool:
    """True only when a run object's repository is the receiver repo. A run in
    any other repository (or an unreadable one) is rejected."""
    if not isinstance(run, dict):
        return False
    repo = run.get("repository")
    full_name = None
    if isinstance(repo, dict):
        full_name = _s(repo.get("full_name"))
    return full_name == expected_repo


def select_run_by_correlation(
    runs_response: "Any", correlation_id: str, expected_repo: str = RECEIVER_REPO
) -> DispatchResult:
    """Fallback: find the receiver run whose name embeds ``[corr:<id>]``.

    Only runs that belong to the receiver repo are considered, so a correlation
    collision in another repository can never be selected.
    """
    if not correlation_id:
        return DispatchResult()
    marker = f"[corr:{correlation_id}]"
    runs = []
    if isinstance(runs_response, dict):
        runs = runs_response.get("workflow_runs") or []
    elif isinstance(runs_response, list):
        runs = runs_response
    for run in runs:
        if not isinstance(run, dict):
            continue
        name = run.get("name") or ""
        if marker not in name:
            continue
        if not run_belongs_to_receiver(run, expected_repo):
            continue
        run_id = _s(run.get("id"))
        if run_id:
            return DispatchResult(
                run_id=run_id, run_url=_s(run.get("url")),
                html_url=_s(run.get("html_url")), source="correlation",
            )
    return DispatchResult()


def selector_job_conclusion(jobs_response: "Any") -> "str | None":
    """The conclusion of the receiver's selector-contract job, or None when it
    is not present. Matches by case-insensitive name substring."""
    jobs = []
    if isinstance(jobs_response, dict):
        jobs = jobs_response.get("jobs") or []
    elif isinstance(jobs_response, list):
        jobs = jobs_response
    for job in jobs:
        if not isinstance(job, dict):
            continue
        name = (job.get("name") or "").lower()
        if SELECTOR_JOB_NAME_SUBSTRING in name:
            return _s(job.get("conclusion"))
    return None


def selector_job_passed(jobs_response: "Any") -> bool:
    return selector_job_conclusion(jobs_response) == "success"


def find_selector_artifact(
    artifacts_response: "Any", name: str = ARTIFACT_NAME
) -> "tuple[str, str | None] | None":
    """Return ``(artifact_id, digest)`` for the selector-contract-result
    artifact, or None when it is absent. ``digest`` is the GitHub-provided
    ``digest`` when available (older API responses omit it)."""
    artifacts = []
    if isinstance(artifacts_response, dict):
        artifacts = artifacts_response.get("artifacts") or []
    elif isinstance(artifacts_response, list):
        artifacts = artifacts_response
    for art in artifacts:
        if not isinstance(art, dict):
            continue
        if _s(art.get("name")) == name and not art.get("expired", False):
            art_id = _s(art.get("id"))
            if art_id:
                return art_id, _s(art.get("digest"))
    return None


# --------------------------------------------------------------------------
# CLI adapter used by the sender workflow
# --------------------------------------------------------------------------


def _read(path: "str | None") -> str:
    if path and path != "-":
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    return sys.stdin.read()


def _emit(pairs: "dict[str, Any]") -> None:
    for key, value in pairs.items():
        print(f"{key}={value if value is not None else ''}")


def main(argv: "list[str] | None" = None) -> int:
    parser = argparse.ArgumentParser(description="Cross-repo dispatch receiver-run resolver (Priority 3).")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_resp = sub.add_parser("parse-response", help="Parse the workflow_dispatch response body.")
    p_resp.add_argument("--input", default="-")

    p_sel = sub.add_parser("select-run", help="Correlation fallback: find the receiver run by [corr:<id>].")
    p_sel.add_argument("--input", default="-")
    p_sel.add_argument("--correlation", required=True)

    p_job = sub.add_parser("check-selector-job", help="Exit 0 iff the receiver selector-contract job passed.")
    p_job.add_argument("--input", default="-")

    p_art = sub.add_parser("find-artifact", help="Emit the selector-contract-result artifact id + digest.")
    p_art.add_argument("--input", default="-")

    args = parser.parse_args(argv)

    if args.cmd == "parse-response":
        result = parse_dispatch_response(_read(args.input))
        _emit({"run_id": result.run_id, "run_url": result.run_url,
                "html_url": result.html_url, "source": result.source})
        return 0

    if args.cmd == "select-run":
        result = select_run_by_correlation(_load(_read(args.input)), args.correlation)
        _emit({"run_id": result.run_id, "run_url": result.run_url,
                "html_url": result.html_url, "source": result.source})
        return 0

    if args.cmd == "check-selector-job":
        conclusion = selector_job_conclusion(_load(_read(args.input)))
        _emit({"selector_job_conclusion": conclusion})
        return 0 if conclusion == "success" else 1

    if args.cmd == "find-artifact":
        found = find_selector_artifact(_load(_read(args.input)))
        if found is None:
            _emit({"artifact_id": None, "artifact_digest": None})
            return 1
        art_id, digest = found
        _emit({"artifact_id": art_id, "artifact_digest": digest})
        return 0

    return 2


if __name__ == "__main__":
    raise SystemExit(main())
