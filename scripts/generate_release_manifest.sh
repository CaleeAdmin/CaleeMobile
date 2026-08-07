#!/usr/bin/env bash
#
# Emit a machine-readable release manifest so every uploaded artifact can be
# traced back to the exact source and CI run that produced it.
#
# The manifest records, for one platform's release build:
#   * the source Git SHA and ref
#   * the app version (build name) and build number
#   * the GitHub Actions workflow, run id, run attempt and run URL
#   * every artifact's file name, size and SHA-256 checksum
#   * the non-secret signing identity summary, when the caller supplies one
#
# Usage:
#   scripts/generate_release_manifest.sh \
#     --platform android|ios \
#     --build-name 0.0.30 \
#     --build-number 30 \
#     --artifact PATH [--artifact PATH ...] \
#     [--signing-identity "non-secret summary"] \
#     [--output PATH]
#
# Git/CI metadata is read from the standard GitHub Actions environment
# (GITHUB_SHA, GITHUB_REF_NAME, GITHUB_WORKFLOW, GITHUB_RUN_ID,
# GITHUB_RUN_ATTEMPT, GITHUB_SERVER_URL, GITHUB_REPOSITORY) and falls back to
# the local git checkout when run outside CI.
#
# SECURITY: --signing-identity is for NON-SECRET identity information only —
# a certificate common name, a SHA-256 certificate fingerprint, a provisioning
# profile name. Never pass a password, a private key, or the contents of a
# .p12/.jks/.mobileprovision file. The script writes exactly what it is given.
#
# Exit status: 0 on success, non-zero if a named artifact is missing or a
# required argument is absent.

set -euo pipefail

err() {
  printf '%s\n' "$*" >&2
}

usage() {
  sed -n '2,35p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

platform=""
build_name=""
build_number=""
signing_identity=""
output=""
artifacts=()

while (( $# > 0 )); do
  case "$1" in
    --platform)
      [[ $# -ge 2 ]] || { err "--platform requires a value"; exit 2; }
      platform="$2"; shift 2 ;;
    --build-name)
      [[ $# -ge 2 ]] || { err "--build-name requires a value"; exit 2; }
      build_name="$2"; shift 2 ;;
    --build-number)
      [[ $# -ge 2 ]] || { err "--build-number requires a value"; exit 2; }
      build_number="$2"; shift 2 ;;
    --artifact)
      [[ $# -ge 2 ]] || { err "--artifact requires a value"; exit 2; }
      artifacts+=("$2"); shift 2 ;;
    --signing-identity)
      [[ $# -ge 2 ]] || { err "--signing-identity requires a value"; exit 2; }
      signing_identity="$2"; shift 2 ;;
    --output)
      [[ $# -ge 2 ]] || { err "--output requires a value"; exit 2; }
      output="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      err "Unknown option: $1"; usage >&2; exit 2 ;;
  esac
done

case "$platform" in
  android|ios) ;;
  *) err "--platform must be android or ios (got '${platform:-<empty>}')"; exit 2 ;;
esac

[[ -n "$build_name" ]] || { err "--build-name is required"; exit 2; }
[[ -n "$build_number" ]] || { err "--build-number is required"; exit 2; }
(( ${#artifacts[@]} > 0 )) || { err "at least one --artifact is required"; exit 2; }

for artifact in "${artifacts[@]}"; do
  if [[ ! -f "$artifact" ]]; then
    err "Artifact not found: $artifact"
    exit 1
  fi
done

git_sha="${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo "unknown")}"
git_ref="${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")}"
repository="${GITHUB_REPOSITORY:-unknown}"
workflow="${GITHUB_WORKFLOW:-local}"
run_id="${GITHUB_RUN_ID:-local}"
run_attempt="${GITHUB_RUN_ATTEMPT:-local}"
server_url="${GITHUB_SERVER_URL:-https://github.com}"

if [[ "$run_id" != "local" && "$repository" != "unknown" ]]; then
  run_url="$server_url/$repository/actions/runs/$run_id"
else
  run_url=""
fi

if [[ -z "$output" ]]; then
  output="build/release-manifest-$platform-$build_name+$build_number.json"
fi
mkdir -p "$(dirname "$output")"

# sha256 tool differs between the Linux (Android) and macOS (iOS) runners.
sha256_of() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    echo "unavailable"
  fi
}

size_of() {
  wc -c < "$1" | tr -d '[:space:]'
}

# Build the JSON with python3 so every value is correctly escaped rather than
# hand-interpolated into a string (python3 is already a CI dependency of the
# existing .github/scripts checks). The collected values go through a temp file
# because the python program itself occupies stdin.
values_file="$(mktemp)"
trap 'rm -f "$values_file"' EXIT

{
  printf '%s\n' "$platform" "$build_name" "$build_number" "$git_sha" "$git_ref" \
    "$repository" "$workflow" "$run_id" "$run_attempt" "$run_url" "$signing_identity"
  printf '%s\n' "---ARTIFACTS---"
  for artifact in "${artifacts[@]}"; do
    printf '%s\t%s\t%s\n' "$(basename "$artifact")" "$(size_of "$artifact")" "$(sha256_of "$artifact")"
  done
} > "$values_file"

python3 - "$output" "$values_file" <<'PY'
import json
import sys

out_path = sys.argv[1]
with open(sys.argv[2], encoding="utf-8") as handle:
    lines = handle.read().split("\n")

(
    platform, build_name, build_number, git_sha, git_ref, repository,
    workflow, run_id, run_attempt, run_url, signing_identity,
) = lines[:11]

artifacts = []
for line in lines[12:]:
    if not line.strip():
        continue
    name, size, digest = line.split("\t")
    artifacts.append(
        {"name": name, "size_bytes": int(size), "sha256": digest}
    )

manifest = {
    "schema": "calee-mobile-release-manifest/1",
    "app": {
        "display_name": "Calee",
        "android_application_id": "au.com.calee.mobile",
        "ios_bundle_id": "au.com.calee.mobile",
    },
    "platform": platform,
    "version": {"build_name": build_name, "build_number": build_number},
    "source": {"repository": repository, "git_sha": git_sha, "git_ref": git_ref},
    "ci": {
        "workflow": workflow,
        "run_id": run_id,
        "run_attempt": run_attempt,
        "run_url": run_url or None,
    },
    "artifacts": artifacts,
    # Non-secret identity summary only; see the header of the generating script.
    "signing_identity": signing_identity or None,
    "store_readiness": (
        "A successful build is NOT store readiness. This manifest records only "
        "what was built. Store metadata, review requirements, approval and "
        "rollout are tracked in docs/STORE_RELEASE_CHECKLIST.md."
    ),
}

with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")

print(json.dumps(manifest, indent=2, sort_keys=True))
PY

printf 'Wrote release manifest: %s\n' "$output" >&2
