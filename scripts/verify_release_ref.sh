#!/usr/bin/env bash
#
# Prove that a signed build is being cut from a real BRANCH, and report whether
# that branch is an authorised RELEASE branch.
#
# `workflow_dispatch` can target a branch **or a tag**, and GITHUB_REF_NAME is
# the short name for both — so a tag named `main` or `stage` presents exactly
# like the real branch. Checking the short name alone is therefore not a
# release gate. This script checks the fully-qualified ref and the ref type.
#
# Usage:
#   scripts/verify_release_ref.sh check [--any-branch]
#   scripts/verify_release_ref.sh selftest
#
# `check` (the default rule) requires an authorised RELEASE branch:
# refs/heads/stage or refs/heads/main. The signed iOS workflow uses it.
#
# `check --any-branch` requires only that the ref is a real BRANCH, of any name,
# so a signed Android APK can be produced from a feature branch for testing. A
# TAG is still refused — a tag is not a branch, and that is the exact confusion
# this script exists to prevent. A build from a non-release branch is NOT a
# release candidate and must not be submitted to a store.
#
# `check` reads the standard GitHub Actions ref environment:
#   GITHUB_REF        fully-qualified ref, e.g. refs/heads/main
#   GITHUB_REF_TYPE   "branch" or "tag"
#   GITHUB_REF_NAME   short name, e.g. main
#
# It fails closed: an absent GITHUB_REF, a tag, a type/ref disagreement, or a
# ref outside the rule being applied is rejected. There is no override.
#
# On success, and only on success, `check` appends to GITHUB_OUTPUT when that
# variable is set:
#   release_ref=<fully-qualified ref>
#   is_release_branch=true|false
# so a workflow can demand the per-release readiness evidence for a real
# release while still allowing an unqualified signed build off a branch.
#
# This is the FIRST of two independent layers. `scripts/release_preflight.sh`
# implements the same rules separately (`--allow-branch` / `--require-branch`),
# so a mistake in one layer does not silently re-open the hole.
#
# Exit status: 0 when the ref satisfies the rule being applied, 1 otherwise.

set -euo pipefail

# The only refs from which production release candidates may be produced.
readonly AUTHORISED_RELEASE_REFS=(
  "refs/heads/stage"
  "refs/heads/main"
)

# Which rule `check` is applying: "release" (an authorised release branch only)
# or "any-branch" (any branch, never a tag).
CHECK_MODE="release"

err() {
  printf '%s\n' "$*" >&2
}

usage() {
  sed -n '2,43p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Print the ref type implied by a fully-qualified ref.
derive_ref_type() {
  case "$1" in
    refs/heads/*) printf 'branch\n' ;;
    refs/tags/*) printf 'tag\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

is_authorised_release_ref() {
  local ref="$1" allowed
  for allowed in "${AUTHORISED_RELEASE_REFS[@]}"; do
    [[ "$ref" == "$allowed" ]] && return 0
  done
  return 1
}

reject() {
  local reason="$1"
  local ref="${GITHUB_REF:-<unset>}"
  local ref_type="${GITHUB_REF_TYPE:-<unset>}"
  local ref_name="${GITHUB_REF_NAME:-<unset>}"

  local subject="production-signed Calee artifacts"
  [[ "$CHECK_MODE" == "any-branch" ]] && subject="signed Calee artifacts"

  # Actions annotation, so the reason is visible without opening the log.
  echo "::error::Refusing to build $subject: $reason (ref '$ref', type '$ref_type')"

  {
    echo "Refusing to produce signed artifacts."
    echo
    echo "Reason      : $reason"
    echo "Current ref : $ref"
    echo "Ref type    : $ref_type"
    echo "Ref name    : $ref_name"
    echo
    if [[ "$CHECK_MODE" == "any-branch" ]]; then
      echo "A signed build may be produced from any BRANCH (refs/heads/*), but"
      echo "never from a TAG: a tag named 'stage' or 'main' is not that branch."
      echo "Re-dispatch this workflow with a BRANCH selected."
    else
      echo "Production-signed artifacts may only be built from:"
      local allowed
      for allowed in "${AUTHORISED_RELEASE_REFS[@]}"; do
        echo "  $allowed  (branch)"
      done
      echo
      echo "A TAG named 'stage' or 'main' is NOT an authorised release ref."
      echo "Promote the change through dev -> stage -> main, then dispatch this"
      echo "workflow again with the 'stage' or 'main' BRANCH selected."
    fi
    echo "See docs/RELEASE_OPERATIONS.md section 4 (release path)."
  } >&2

  exit 1
}

# Publish the classification for the calling workflow. Written only after the
# ref has been accepted, so a rejected run leaves behind nothing a later job
# could mistake for an authorisation.
emit_ref_outputs() {
  local ref="$1" is_release="$2"

  [[ -n "${GITHUB_OUTPUT:-}" ]] || return 0

  {
    printf 'release_ref=%s\n' "$ref"
    printf 'is_release_branch=%s\n' "$is_release"
  } >> "$GITHUB_OUTPUT"
}

cmd_check() {
  CHECK_MODE="release"
  while (( $# > 0 )); do
    case "$1" in
      --any-branch)
        CHECK_MODE="any-branch"
        shift
        ;;
      *)
        err "Unknown option for check: $1"
        usage >&2
        return 2
        ;;
    esac
  done

  local ref="${GITHUB_REF:-}"
  local declared_type="${GITHUB_REF_TYPE:-}"
  local ref_name="${GITHUB_REF_NAME:-}"

  # Without the fully-qualified ref there is no way to tell a branch from a
  # tag, so this is a hard failure rather than a fallback to the short name.
  if [[ -z "$ref" ]]; then
    reject "GITHUB_REF is not set, so the ref cannot be proven to be a branch"
  fi

  local derived_type
  derived_type="$(derive_ref_type "$ref")"

  # A declared type that contradicts the ref itself means the environment is
  # not trustworthy; refuse rather than pick a winner.
  if [[ -n "$declared_type" && "$declared_type" != "$derived_type" ]]; then
    reject "GITHUB_REF_TYPE ('$declared_type') contradicts GITHUB_REF ('$ref', which is a $derived_type)"
  fi

  local effective_type="${declared_type:-$derived_type}"
  if [[ "$effective_type" != "branch" ]]; then
    reject "the release ref is a $effective_type, not a branch"
  fi

  # Same consistency requirement for the short name.
  if [[ -n "$ref_name" && "$ref" != "refs/heads/$ref_name" ]]; then
    reject "GITHUB_REF_NAME ('$ref_name') does not match GITHUB_REF ('$ref')"
  fi

  local is_release="false"
  if is_authorised_release_ref "$ref"; then
    is_release="true"
  fi

  if [[ "$CHECK_MODE" != "any-branch" && "$is_release" != "true" ]]; then
    reject "'$ref' is not an authorised release branch"
  fi

  emit_ref_outputs "$ref" "$is_release"

  if [[ "$is_release" == "true" ]]; then
    echo "Release ref '$ref' (branch) is authorised for production-signed builds."
    return 0
  fi

  # Reachable only under --any-branch: a real branch, but not a release one.
  # Say so loudly, because the artifacts are indistinguishable by filename.
  echo "::warning::'$ref' is a branch but NOT a release branch — the artifacts this run produces are test builds, not a release candidate, and must not be submitted to a store."
  echo "Ref '$ref' (branch) is accepted for a signed test build."
  echo "It is not one of: ${AUTHORISED_RELEASE_REFS[*]}"
  echo "This run does NOT produce a release candidate."
  return 0
}

# --- selftest ---------------------------------------------------------------
#
# Exercises the real entry point, so a rule that stops being enforced fails the
# test rather than passing silently.

cmd_selftest() {
  local self_path
  self_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

  local failures=0

  # run_check <GITHUB_REF> <GITHUB_REF_TYPE> <GITHUB_REF_NAME> [check args...]
  # A literal "-" means "leave that variable unset". Returns the exit status of
  # the real entry point.
  run_check() {
    local ref="$1" ref_type="$2" ref_name="$3"
    shift 3
    (
      if [[ "$ref" == "-" ]]; then unset GITHUB_REF; else export GITHUB_REF="$ref"; fi
      if [[ "$ref_type" == "-" ]]; then unset GITHUB_REF_TYPE; else export GITHUB_REF_TYPE="$ref_type"; fi
      if [[ "$ref_name" == "-" ]]; then unset GITHUB_REF_NAME; else export GITHUB_REF_NAME="$ref_name"; fi
      bash "$self_path" check "$@" >/dev/null 2>&1
    )
  }

  record() {
    local expected="$1" name="$2" status="$3"

    local ok=0
    if [[ "$expected" == "nonzero" ]]; then
      (( status != 0 )) && ok=1
    elif (( status == expected )); then
      ok=1
    fi

    if (( ok )); then
      echo "  PASS: $name (exit $status)"
    else
      echo "  FAIL: $name (expected $expected, got $status)"
      failures=$((failures + 1))
    fi
  }

  # expect <expected|nonzero> <name> <GITHUB_REF> <GITHUB_REF_TYPE> <GITHUB_REF_NAME> [check args...]
  expect() {
    local expected="$1" name="$2"
    shift 2

    local status=0
    run_check "$@" || status=$?
    record "$expected" "$name" "$status"
  }

  echo "selftest: authorised release branches are accepted"
  expect 0 branch-stage refs/heads/stage branch stage
  expect 0 branch-main refs/heads/main branch main
  # GITHUB_REF_TYPE is always set by Actions, but the rule must hold without it.
  expect 0 branch-main-type-derived refs/heads/main - main
  expect 0 branch-stage-no-short-name refs/heads/stage branch -

  echo "selftest: other branches are rejected for a production release"
  expect nonzero branch-dev refs/heads/dev branch dev
  expect nonzero branch-feature refs/heads/feature/foo branch feature/foo
  expect nonzero branch-claude refs/heads/claude/formalize-app-store-play-releases-15450z branch claude/formalize-app-store-play-releases-15450z
  expect nonzero branch-lookalike-stage refs/heads/stage-2 branch stage-2
  expect nonzero branch-lookalike-main refs/heads/mainline branch mainline
  expect nonzero branch-nested-main refs/heads/release/main branch release/main

  echo "selftest: TAGS are rejected even when named like a release branch"
  expect nonzero tag-main refs/tags/main tag main
  expect nonzero tag-stage refs/tags/stage tag stage
  expect nonzero tag-version refs/tags/v0.0.30 tag v0.0.30
  # A tag whose declared type was stripped must still be caught by the ref path.
  expect nonzero tag-main-type-derived refs/tags/main - main
  expect nonzero tag-stage-type-derived refs/tags/stage - stage

  echo "selftest: inconsistent or absent ref information is rejected"
  expect nonzero missing-ref - branch main
  expect nonzero missing-everything - - -
  expect nonzero empty-ref "" branch main
  # The exact bypass this script exists to close: a real branch ref paired with
  # a contradictory type, or a tag ref dressed up as a branch.
  expect nonzero main-declared-as-tag refs/heads/main tag main
  expect nonzero stage-declared-as-tag refs/heads/stage tag stage
  expect nonzero tag-declared-as-branch refs/tags/main branch main
  expect nonzero tag-stage-declared-as-branch refs/tags/stage branch stage
  expect nonzero ref-name-disagrees refs/heads/dev branch main
  expect nonzero unknown-ref-namespace refs/pull/539/merge - 539/merge

  echo "selftest: --any-branch accepts any BRANCH, release or not"
  expect 0 any-branch-stage refs/heads/stage branch stage --any-branch
  expect 0 any-branch-main refs/heads/main branch main --any-branch
  expect 0 any-branch-dev refs/heads/dev branch dev --any-branch
  expect 0 any-branch-feature refs/heads/feature/foo branch feature/foo --any-branch
  expect 0 any-branch-claude refs/heads/claude/release-preflight-android-failure-p5s38n branch claude/release-preflight-android-failure-p5s38n --any-branch
  expect 0 any-branch-lookalike refs/heads/stage-2 branch stage-2 --any-branch
  expect 0 any-branch-nested refs/heads/release/main branch release/main --any-branch
  expect 0 any-branch-type-derived refs/heads/dev - dev --any-branch
  expect 0 any-branch-no-short-name refs/heads/dev branch - --any-branch

  echo "selftest: --any-branch still refuses TAGS and untrustworthy ref data"
  # Relaxing WHICH branch may be built must not relax whether it is a branch
  # at all — that is the confusion this whole script exists to prevent.
  expect nonzero any-branch-tag-main refs/tags/main tag main --any-branch
  expect nonzero any-branch-tag-version refs/tags/v0.0.30 tag v0.0.30 --any-branch
  expect nonzero any-branch-tag-type-derived refs/tags/main - main --any-branch
  expect nonzero any-branch-tag-declared-as-branch refs/tags/main branch main --any-branch
  expect nonzero any-branch-branch-declared-as-tag refs/heads/dev tag dev --any-branch
  expect nonzero any-branch-missing-ref - branch dev --any-branch
  expect nonzero any-branch-empty-ref "" branch dev --any-branch
  expect nonzero any-branch-name-disagrees refs/heads/dev branch main --any-branch
  expect nonzero any-branch-unknown-namespace refs/pull/539/merge - 539/merge --any-branch

  echo "selftest: an unknown check option is rejected rather than ignored"
  # A typo'd flag must not silently fall back to a laxer rule.
  expect nonzero unknown-check-option refs/heads/main branch main --all-branches

  echo "selftest: the release-branch classification handed to the workflow is correct"
  # is_release_branch is what a workflow uses to decide whether the per-release
  # readiness evidence is required, so a wrong answer here would let a test
  # build masquerade as a qualified release candidate.

  # expect_outputs <expected is_release_branch|none> <name> <GITHUB_REF> <TYPE> <NAME> [check args...]
  expect_outputs() {
    local expected="$1" name="$2"
    shift 2

    local out_file
    out_file="$(mktemp)"

    (
      export GITHUB_OUTPUT="$out_file"
      run_check "$@"
    ) || true

    local actual
    actual="$(sed -n 's/^is_release_branch=//p' "$out_file" | tail -n1)"
    [[ -z "$actual" ]] && actual="none"
    rm -f "$out_file"

    if [[ "$actual" == "$expected" ]]; then
      echo "  PASS: $name (is_release_branch=$actual)"
    else
      echo "  FAIL: $name (expected is_release_branch=$expected, got $actual)"
      failures=$((failures + 1))
    fi
  }

  expect_outputs true classify-main refs/heads/main branch main --any-branch
  expect_outputs true classify-stage refs/heads/stage branch stage --any-branch
  expect_outputs false classify-feature refs/heads/feature/foo branch feature/foo --any-branch
  expect_outputs false classify-lookalike refs/heads/mainline branch mainline --any-branch
  expect_outputs true classify-release-mode-main refs/heads/main branch main
  # A rejected ref must publish nothing at all: a later job reading these
  # outputs must never see a value written by a run that failed the gate.
  expect_outputs none classify-rejected-tag refs/tags/main tag main --any-branch
  expect_outputs none classify-rejected-branch refs/heads/dev branch dev

  echo
  if (( failures > 0 )); then
    echo "verify_release_ref selftest FAILED ($failures failing case(s))" >&2
    return 1
  fi
  echo "verify_release_ref selftest passed."
  return 0
}

main() {
  local command="${1:-}"
  case "$command" in
    check)
      shift
      cmd_check "$@"
      ;;
    selftest)
      shift
      cmd_selftest "$@"
      ;;
    -h|--help|help|"")
      usage
      ;;
    *)
      err "Unknown command: $command"
      usage >&2
      return 2
      ;;
  esac
}

main "$@"
