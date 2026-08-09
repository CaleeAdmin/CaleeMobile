#!/usr/bin/env bash
#
# Prove that a signed release build is being cut from an authorised release
# BRANCH.
#
# `workflow_dispatch` can target a branch **or a tag**, and GITHUB_REF_NAME is
# the short name for both — so a tag named `main` or `stage` presents exactly
# like the real branch. Checking the short name alone is therefore not a
# release gate. This script checks the fully-qualified ref and the ref type.
#
# Usage:
#   scripts/verify_release_ref.sh check
#   scripts/verify_release_ref.sh selftest
#
# `check` reads the standard GitHub Actions ref environment:
#   GITHUB_REF        fully-qualified ref, e.g. refs/heads/main
#   GITHUB_REF_TYPE   "branch" or "tag"
#   GITHUB_REF_NAME   short name, e.g. main
#
# It fails closed: an absent GITHUB_REF, a tag, a type/ref disagreement, or any
# ref outside the authorised list is rejected. There is no override.
#
# This is the FIRST of two independent layers. `scripts/release_preflight.sh`
# implements the same rule separately (`--allow-branch`), so a mistake in one
# layer does not silently re-open the hole.
#
# Exit status: 0 when the ref is an authorised release branch, 1 otherwise.

set -euo pipefail

# The only refs from which production-signed artifacts may be produced.
readonly AUTHORISED_RELEASE_REFS=(
  "refs/heads/stage"
  "refs/heads/main"
)

err() {
  printf '%s\n' "$*" >&2
}

usage() {
  sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Print the ref type implied by a fully-qualified ref.
derive_ref_type() {
  case "$1" in
    refs/heads/*) printf 'branch\n' ;;
    refs/tags/*) printf 'tag\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

reject() {
  local reason="$1"
  local ref="${GITHUB_REF:-<unset>}"
  local ref_type="${GITHUB_REF_TYPE:-<unset>}"
  local ref_name="${GITHUB_REF_NAME:-<unset>}"

  # Actions annotation, so the reason is visible without opening the log.
  echo "::error::Refusing to build production-signed Calee artifacts: $reason (ref '$ref', type '$ref_type')"

  {
    echo "Refusing to produce production-signed artifacts."
    echo
    echo "Reason      : $reason"
    echo "Current ref : $ref"
    echo "Ref type    : $ref_type"
    echo "Ref name    : $ref_name"
    echo
    echo "Production-signed artifacts may only be built from:"
    local allowed
    for allowed in "${AUTHORISED_RELEASE_REFS[@]}"; do
      echo "  $allowed  (branch)"
    done
    echo
    echo "A TAG named 'stage' or 'main' is NOT an authorised release ref."
    echo "Promote the change through dev -> stage -> main, then dispatch this"
    echo "workflow again with the 'stage' or 'main' BRANCH selected."
    echo "See docs/RELEASE_OPERATIONS.md section 4 (release path)."
  } >&2

  exit 1
}

cmd_check() {
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

  local allowed
  for allowed in "${AUTHORISED_RELEASE_REFS[@]}"; do
    if [[ "$ref" == "$allowed" ]]; then
      echo "Release ref '$ref' (branch) is authorised for production-signed builds."
      return 0
    fi
  done

  reject "'$ref' is not an authorised release branch"
}

# --- selftest ---------------------------------------------------------------
#
# Exercises the real entry point, so a rule that stops being enforced fails the
# test rather than passing silently.

cmd_selftest() {
  local self_path
  self_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

  local failures=0

  # expect <expected|nonzero> <name> <GITHUB_REF> <GITHUB_REF_TYPE> <GITHUB_REF_NAME>
  # A literal "-" means "leave that variable unset".
  expect() {
    local expected="$1" name="$2" ref="$3" ref_type="$4" ref_name="$5"

    local status=0
    (
      if [[ "$ref" == "-" ]]; then unset GITHUB_REF; else export GITHUB_REF="$ref"; fi
      if [[ "$ref_type" == "-" ]]; then unset GITHUB_REF_TYPE; else export GITHUB_REF_TYPE="$ref_type"; fi
      if [[ "$ref_name" == "-" ]]; then unset GITHUB_REF_NAME; else export GITHUB_REF_NAME="$ref_name"; fi
      bash "$self_path" check >/dev/null 2>&1
    ) || status=$?

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

  echo "selftest: authorised release branches are accepted"
  expect 0 branch-stage refs/heads/stage branch stage
  expect 0 branch-main refs/heads/main branch main
  # GITHUB_REF_TYPE is always set by Actions, but the rule must hold without it.
  expect 0 branch-main-type-derived refs/heads/main - main
  expect 0 branch-stage-no-short-name refs/heads/stage branch -

  echo "selftest: other branches are rejected"
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
