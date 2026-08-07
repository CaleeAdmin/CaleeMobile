#!/usr/bin/env bash
#
# Emit a machine-readable release manifest so every uploaded artifact can be
# traced back to the exact source and CI run that produced it.
#
# The manifest records, for one platform's release build:
#   * the source Git SHA and ref
#   * the app version (build name) and build number
#   * the GitHub Actions workflow, run id, run attempt and run URL
#   * EVERY uploaded artifact: name, role, size and SHA-256
#   * the non-secret signing identity summary, when the caller supplies one
#
# Both signed-release workflows must pass every artifact they upload, not only
# the store binary, so the manifest is a complete record of the release output.
#
# Usage:
#   scripts/generate_release_manifest.sh \
#     --platform android|ios \
#     --build-name 0.0.30 \
#     --build-number 30 \
#     --artifact [ROLE=]PATH [--artifact ...] \
#     [--artifact-dir [ROLE=]DIR ...] \
#     [--signing-identity "non-secret summary"] \
#     [--output PATH]
#
#   scripts/generate_release_manifest.sh selftest
#
# --artifact takes a file. --artifact-dir takes a directory artifact (an
# .xcarchive, a split-debug-info directory): it is recorded with a file count,
# a total size and a `tree_sha256` computed over every contained file's path and
# digest, so a directory artifact is as verifiable as a single file.
#
# ROLE is an optional label describing what the artifact is (app_bundle, apk,
# ipa, native_debug_symbols, dart_debug_symbols, xcarchive, ...). When omitted it
# is inferred from the file name.
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
# Exit status: 0 on success; non-zero if a named artifact is missing, is the
# wrong kind, or a required argument is absent. It fails closed: a release must
# never ship an artifact the manifest does not cover.

set -euo pipefail

err() {
  printf '%s\n' "$*" >&2
}

usage() {
  sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- selftest ---------------------------------------------------------------
#
# Proves the generator produces a complete, valid manifest and — just as
# importantly — that it refuses to produce one when an artifact is missing.

cmd_selftest() {
  local self_path
  self_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp_dir'" RETURN

  local failures=0

  printf 'fake-aab\n' > "$tmp_dir/calee-mobile-0.0.30.aab"
  printf 'fake-apk\n' > "$tmp_dir/calee-mobile-0.0.30.apk"
  printf 'fake-symbols\n' > "$tmp_dir/native-debug-symbols.zip"
  mkdir -p "$tmp_dir/symbols/nested"
  printf 'sym-a\n' > "$tmp_dir/symbols/app.android-arm64.symbols"
  printf 'sym-b\n' > "$tmp_dir/symbols/nested/app.android-arm.symbols"

  local manifest="$tmp_dir/manifest.json"
  local status=0
  GITHUB_SHA="0123456789abcdef0123456789abcdef01234567" \
  GITHUB_REF_NAME="main" \
  GITHUB_REPOSITORY="CaleeAdmin/CaleeMobile" \
  GITHUB_WORKFLOW="Build Signed Android Artifacts" \
  GITHUB_RUN_ID="12345" \
  GITHUB_RUN_ATTEMPT="1" \
  bash "$self_path" \
    --platform android \
    --build-name 0.0.30 \
    --build-number 30 \
    --artifact "app_bundle=$tmp_dir/calee-mobile-0.0.30.aab" \
    --artifact "$tmp_dir/calee-mobile-0.0.30.apk" \
    --artifact "$tmp_dir/native-debug-symbols.zip" \
    --artifact-dir "dart_debug_symbols=$tmp_dir/symbols" \
    --signing-identity "CN=Example, certificate SHA-256 00:11" \
    --output "$manifest" >/dev/null 2>&1 || status=$?

  if (( status == 0 )); then
    echo "  PASS: complete-manifest (exit 0)"
  else
    echo "  FAIL: complete-manifest (expected exit 0, got $status)"
    failures=$((failures + 1))
  fi

  # Validate the manifest's structure and that every artifact was recorded.
  if python3 - "$manifest" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["schema"] == "calee-mobile-release-manifest/2", data["schema"]
assert data["platform"] == "android"
assert data["version"] == {"build_name": "0.0.30", "build_number": "30"}
assert data["source"]["git_sha"] == "0123456789abcdef0123456789abcdef01234567"
assert data["source"]["git_ref"] == "main"
assert data["ci"]["run_id"] == "12345"
assert data["ci"]["run_attempt"] == "1"
assert data["ci"]["run_url"].endswith("/actions/runs/12345")

artifacts = data["artifacts"]
assert len(artifacts) == 4, artifacts
by_name = {a["name"]: a for a in artifacts}

aab = by_name["calee-mobile-0.0.30.aab"]
assert aab["kind"] == "file" and aab["role"] == "app_bundle"
assert len(aab["sha256"]) == 64 and aab["size_bytes"] > 0

# Roles are inferred when not given explicitly.
assert by_name["calee-mobile-0.0.30.apk"]["role"] == "apk"
assert by_name["native-debug-symbols.zip"]["role"] == "native_debug_symbols"

symbols = by_name["symbols"]
assert symbols["kind"] == "directory" and symbols["role"] == "dart_debug_symbols"
assert symbols["file_count"] == 2, symbols
assert len(symbols["tree_sha256"]) == 64
assert symbols["total_size_bytes"] > 0

assert data["signing_identity"].startswith("CN=Example")
assert "store readiness" in data["store_readiness"].lower()
PY
  then
    echo "  PASS: manifest-contents"
  else
    echo "  FAIL: manifest-contents"
    failures=$((failures + 1))
  fi

  # expect_failure <name> <args...>
  expect_failure() {
    local name="$1"
    shift
    local status=0
    bash "$self_path" "$@" >/dev/null 2>&1 || status=$?
    if (( status != 0 )); then
      echo "  PASS: $name (exit $status)"
    else
      echo "  FAIL: $name (expected non-zero, got 0)"
      failures=$((failures + 1))
    fi
  }

  echo "selftest: incomplete or invalid input must fail closed"
  expect_failure missing-artifact --platform android --build-name 0.0.30 --build-number 30 \
    --artifact "$tmp_dir/does-not-exist.aab" --output "$tmp_dir/m1.json"
  expect_failure missing-artifact-among-present --platform android --build-name 0.0.30 \
    --build-number 30 --artifact "$tmp_dir/calee-mobile-0.0.30.aab" \
    --artifact "$tmp_dir/does-not-exist.zip" --output "$tmp_dir/m2.json"
  expect_failure missing-artifact-dir --platform ios --build-name 0.0.30 --build-number 30 \
    --artifact "$tmp_dir/calee-mobile-0.0.30.aab" \
    --artifact-dir "$tmp_dir/no-such-dir" --output "$tmp_dir/m3.json"
  expect_failure directory-passed-as-file --platform android --build-name 0.0.30 \
    --build-number 30 --artifact "$tmp_dir/symbols" --output "$tmp_dir/m4.json"
  expect_failure file-passed-as-directory --platform android --build-name 0.0.30 \
    --build-number 30 --artifact-dir "$tmp_dir/calee-mobile-0.0.30.aab" --output "$tmp_dir/m5.json"
  mkdir -p "$tmp_dir/empty-dir"
  expect_failure empty-directory-artifact --platform android --build-name 0.0.30 \
    --build-number 30 --artifact-dir "$tmp_dir/empty-dir" --output "$tmp_dir/m6.json"
  expect_failure no-artifacts --platform android --build-name 0.0.30 --build-number 30 \
    --output "$tmp_dir/m7.json"
  expect_failure missing-build-name --platform android --build-number 30 \
    --artifact "$tmp_dir/calee-mobile-0.0.30.aab" --output "$tmp_dir/m8.json"
  expect_failure missing-build-number --platform android --build-name 0.0.30 \
    --artifact "$tmp_dir/calee-mobile-0.0.30.aab" --output "$tmp_dir/m9.json"
  expect_failure invalid-platform --platform windows --build-name 0.0.30 --build-number 30 \
    --artifact "$tmp_dir/calee-mobile-0.0.30.aab" --output "$tmp_dir/m10.json"

  echo
  if (( failures > 0 )); then
    echo "generate_release_manifest selftest FAILED ($failures failing case(s))" >&2
    return 1
  fi
  echo "generate_release_manifest selftest passed."
  return 0
}

if [[ "${1:-}" == "selftest" ]]; then
  cmd_selftest
  exit $?
fi

platform=""
build_name=""
build_number=""
signing_identity=""
output=""
# Entries are "kind<TAB>role<TAB>path"; role may be empty (inferred later).
entries=()

# split_role_path <argument> -> prints "role<TAB>path"
#
# The role is never emitted empty: tab is an IFS *whitespace* character, so
# `read` would collapse two adjacent tabs into one delimiter and shift the path
# into the role field. "auto" means "infer the role from the file name".
split_role_path() {
  local raw="$1"
  # A role prefix is a bare identifier before '=' — this keeps paths that
  # contain '=' from being misread as role separators.
  if [[ "$raw" =~ ^([A-Za-z][A-Za-z0-9_]*)=(.+)$ ]]; then
    printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    printf 'auto\t%s\n' "$raw"
  fi
}

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
      entries+=("file"$'\t'"$(split_role_path "$2")"); shift 2 ;;
    --artifact-dir)
      [[ $# -ge 2 ]] || { err "--artifact-dir requires a value"; exit 2; }
      entries+=("directory"$'\t'"$(split_role_path "$2")"); shift 2 ;;
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
(( ${#entries[@]} > 0 )) || { err "at least one --artifact or --artifact-dir is required"; exit 2; }

# Fail closed before any hashing work: a release artifact that is missing, or is
# not the kind the caller declared, means the manifest would misdescribe the
# release.
for entry in "${entries[@]}"; do
  IFS=$'\t' read -r kind _role path <<<"$entry"
  case "$kind" in
    file)
      if [[ ! -f "$path" ]]; then
        if [[ -d "$path" ]]; then
          err "Artifact '$path' is a directory; pass it with --artifact-dir"
        else
          err "Artifact not found: $path"
        fi
        exit 1
      fi
      ;;
    directory)
      if [[ ! -d "$path" ]]; then
        if [[ -f "$path" ]]; then
          err "Artifact '$path' is a file; pass it with --artifact"
        else
          err "Artifact directory not found: $path"
        fi
        exit 1
      fi
      ;;
  esac
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

# Hashing and JSON assembly happen in python3 (already a CI dependency of the
# existing .github/scripts checks): one implementation for both the Linux
# Android runner and the macOS iOS runner, and correct escaping by construction.
values_file="$(mktemp)"
trap 'rm -f "$values_file"' EXIT

{
  printf '%s\n' "$platform" "$build_name" "$build_number" "$git_sha" "$git_ref" \
    "$repository" "$workflow" "$run_id" "$run_attempt" "$run_url" "$signing_identity"
  printf '%s\n' "---ARTIFACTS---"
  printf '%s\n' "${entries[@]}"
} > "$values_file"

python3 - "$output" "$values_file" <<'PY'
import hashlib
import json
import os
import sys

out_path = sys.argv[1]
with open(sys.argv[2], encoding="utf-8") as handle:
    lines = handle.read().split("\n")

(
    platform, build_name, build_number, git_sha, git_ref, repository,
    workflow, run_id, run_attempt, run_url, signing_identity,
) = lines[:11]

# Role inference keeps the workflows terse for the obvious cases while still
# allowing an explicit role where the file name is not self-describing.
ROLE_BY_SUFFIX = (
    (".aab", "app_bundle"),
    (".apk", "apk"),
    (".ipa", "ipa"),
    (".xcarchive", "xcarchive"),
    (".dSYM", "dsym"),
)


def infer_role(name, kind):
    lowered = name.lower()
    if "native" in lowered and "symbol" in lowered:
        return "native_debug_symbols"
    if "dsym" in lowered:
        return "dsym"
    for suffix, role in ROLE_BY_SUFFIX:
        if name.endswith(suffix):
            return role
    if kind == "directory":
        return "directory_artifact"
    return "file"


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def describe_file(path, role):
    name = os.path.basename(path)
    return {
        "name": name,
        "kind": "file",
        "role": role or infer_role(name, "file"),
        "size_bytes": os.path.getsize(path),
        "sha256": sha256_of(path),
    }


def describe_directory(path, role):
    name = os.path.basename(os.path.normpath(path))
    records = []
    total = 0
    for root, _dirs, files in os.walk(path):
        for file_name in files:
            full = os.path.join(root, file_name)
            if os.path.islink(full) or not os.path.isfile(full):
                continue
            rel = os.path.relpath(full, path)
            records.append((rel, sha256_of(full)))
            total += os.path.getsize(full)

    if not records:
        print(f"Directory artifact '{path}' contains no files", file=sys.stderr)
        sys.exit(1)

    records.sort()
    # A stable digest over every contained path+digest, so the directory
    # artifact is verifiable the same way a single file is.
    tree = hashlib.sha256()
    for rel, digest in records:
        tree.update(f"{rel}\0{digest}\n".encode("utf-8"))

    return {
        "name": name,
        "kind": "directory",
        "role": role or infer_role(name, "directory"),
        "file_count": len(records),
        "total_size_bytes": total,
        "tree_sha256": tree.hexdigest(),
    }


artifacts = []
for line in lines[12:]:
    if not line.strip():
        continue
    kind, role, path = line.split("\t", 2)
    if role == "auto":
        role = ""
    if kind == "file":
        artifacts.append(describe_file(path, role))
    else:
        artifacts.append(describe_directory(path, role))

manifest = {
    "schema": "calee-mobile-release-manifest/2",
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
        "rollout are tracked in docs/STORE_RELEASE_CHECKLIST.md and recorded in "
        "docs/release_evidence/<version>.json."
    ),
}

with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")

print(json.dumps(manifest, indent=2, sort_keys=True))
PY

printf 'Wrote release manifest: %s\n' "$output" >&2
