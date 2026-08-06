#!/usr/bin/env bash
#
# Fetch Google's bundletool jar for AAB manifest inspection
# (scripts/check_android_release_permissions.sh) with a pinned version and a
# verified checksum, so CI never executes an unchecked or "latest" jar.
#
# Usage:
#   scripts/fetch_bundletool.sh [DEST_DIR]
#
# DEST_DIR defaults to build/bundletool (safe to cache between CI runs). If
# the jar already exists it is reused, but its checksum is ALWAYS re-verified
# before the path is trusted. On success the absolute jar path is printed on
# stdout — callers should export it as BUNDLETOOL_JAR.

set -euo pipefail

# Single source of truth for the bundletool pin used by every workflow.
BUNDLETOOL_VERSION="1.18.1"
# SHA-256 of bundletool-all-1.18.1.jar as published on the official Google
# release page (https://github.com/google/bundletool/releases).
BUNDLETOOL_SHA256="675786493983787ffa11550bdb7c0715679a44e1643f3ff980a529e9c822595c"
BUNDLETOOL_URL="https://github.com/google/bundletool/releases/download/${BUNDLETOOL_VERSION}/bundletool-all-${BUNDLETOOL_VERSION}.jar"

dest_dir="${1:-build/bundletool}"
jar_path="${dest_dir}/bundletool-all-${BUNDLETOOL_VERSION}.jar"

mkdir -p "$dest_dir"

verify_checksum() {
  printf '%s  %s\n' "$BUNDLETOOL_SHA256" "$jar_path" | sha256sum -c - >&2
}

if [[ -f "$jar_path" ]] && verify_checksum; then
  echo "Reusing verified bundletool ${BUNDLETOOL_VERSION} at ${jar_path}" >&2
else
  echo "Downloading bundletool ${BUNDLETOOL_VERSION} from ${BUNDLETOOL_URL}" >&2
  curl -fsSL --retry 3 --retry-delay 2 -o "$jar_path" "$BUNDLETOOL_URL"
  if ! verify_checksum; then
    rm -f "$jar_path"
    echo "bundletool checksum verification FAILED; refusing to use the downloaded jar." >&2
    exit 1
  fi
fi

# Absolute path so callers can cd elsewhere safely.
cd "$dest_dir"
printf '%s/%s\n' "$(pwd)" "$(basename "$jar_path")"
