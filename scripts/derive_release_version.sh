#!/usr/bin/env bash
set -euo pipefail

pubspec_path="${1:-pubspec.yaml}"

if [[ ! -f "$pubspec_path" ]]; then
  echo "pubspec file not found: $pubspec_path" >&2
  exit 1
fi

version_line="$(awk -F': ' '/^version:/{print $2; exit}' "$pubspec_path")"
if [[ -z "$version_line" ]]; then
  echo "No version found in $pubspec_path" >&2
  exit 1
fi

if [[ ! "$version_line" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)$ ]]; then
  echo "Invalid version format '$version_line' in $pubspec_path; expected X.Y.Z+N" >&2
  exit 1
fi

build_name="${BASH_REMATCH[1]}"
build_number="${BASH_REMATCH[2]}"

sanitized_build_name="$(echo "$build_name" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//')"
if [[ -z "$sanitized_build_name" ]]; then
  echo "Sanitized build name is empty for version '$build_name'" >&2
  exit 1
fi

printf 'Resolved release version from %s -> build_name=%s, build_number=%s\n' "$pubspec_path" "$build_name" "$build_number" >&2

echo "build_name=$build_name"
echo "build_number=$build_number"
echo "sanitized_build_name=$sanitized_build_name"
