#!/usr/bin/env bash
#
# Guard the final built Android artifacts against broad storage/media
# permissions.
#
# Google Play rejected the Calee AAB for undeclared READ_MEDIA_IMAGES /
# READ_MEDIA_VIDEO usage. Calee never needs broad media-library access: it
# uses the platform camera/photo/document pickers for user-selected files and
# FileProvider content-URI grants for its own downloaded attachments. The
# application manifest strips these permissions with tools:node="remove"
# (android/app/src/main/AndroidManifest.xml), but a dependency bump could
# reintroduce them through manifest merging, so this script inspects the
# *final compiled artifacts* — not the source manifest.
#
# Usage:
#   scripts/check_android_release_permissions.sh selftest
#   scripts/check_android_release_permissions.sh check [--apk PATH] [--aab PATH]
#   scripts/check_android_release_permissions.sh check --permissions-file PATH
#
# check mode requires at least one artifact. The AAB is the artifact uploaded
# to Google Play, so release workflows must always pass --aab.
#
#   --apk PATH   inspect a built APK via aapt2/aapt (Android SDK build-tools)
#   --aab PATH   inspect a built AAB via bundletool `dump manifest`; the
#                bundletool jar is located through $BUNDLETOOL_JAR
#   --permissions-file PATH
#                evaluate a plain-text permission list (one permission name
#                per line). FOR SELFTEST/FIXTURE USE ONLY — real verification
#                must inspect the compiled artifacts with --apk/--aab.
#
# Exit status: 0 when no prohibited permission is present, non-zero otherwise.
# No signing information is read or printed.

set -euo pipefail

# Single source of truth for the prohibited-permission policy. Both the
# signed-release workflow and normal PR CI call this script, so the list is
# never duplicated. Every entry grants broad, ongoing storage or media-library
# access that Calee's picker + FileProvider architecture must never need.
PROHIBITED_PERMISSIONS=(
  "android.permission.READ_EXTERNAL_STORAGE"
  "android.permission.WRITE_EXTERNAL_STORAGE"
  "android.permission.MANAGE_EXTERNAL_STORAGE"
  "android.permission.READ_MEDIA_IMAGES"
  "android.permission.READ_MEDIA_VIDEO"
  "android.permission.READ_MEDIA_AUDIO"
  # Play treats the "user selected" photo permission as media access too;
  # Calee's system-picker flows never require it, so its appearance would be
  # the same class of regression as the entries above.
  "android.permission.READ_MEDIA_VISUAL_USER_SELECTED"
)

usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

err() {
  printf '%s\n' "$*" >&2
}

# --- extraction helpers -----------------------------------------------------

find_aapt() {
  # Prefer aapt2 anywhere on PATH, then the newest Android SDK build-tools.
  local candidate
  for candidate in aapt2 aapt; do
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done

  local sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [[ -n "$sdk_root" && -d "$sdk_root/build-tools" ]]; then
    local latest
    latest="$(ls -1 "$sdk_root/build-tools" | sort -V | tail -n1)"
    for candidate in "$sdk_root/build-tools/$latest/aapt2" "$sdk_root/build-tools/$latest/aapt"; do
      if [[ -x "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  fi

  return 1
}

# Print the uses-permission names of an APK, one per line.
extract_apk_permissions() {
  local apk_path="$1"
  local aapt_bin
  if ! aapt_bin="$(find_aapt)"; then
    err "No aapt2/aapt found (checked PATH and \$ANDROID_HOME/build-tools); cannot inspect APK '$apk_path'."
    return 1
  fi

  # Both aapt and aapt2 print lines like:
  #   uses-permission: name='android.permission.INTERNET'
  "$aapt_bin" dump permissions "$apk_path" \
    | sed -n "s/^uses-permission\(-sdk-23\)\{0,1\}: name='\([^']*\)'.*/\2/p"
}

# Print the uses-permission names of an AAB, one per line.
extract_aab_permissions() {
  local aab_path="$1"
  local bundletool_jar="${BUNDLETOOL_JAR:-}"

  if [[ -z "$bundletool_jar" || ! -f "$bundletool_jar" ]]; then
    err "BUNDLETOOL_JAR is not set or does not point to a file; cannot inspect AAB '$aab_path'."
    err "Provide a pinned, checksum-verified bundletool jar via the BUNDLETOOL_JAR environment variable."
    return 1
  fi
  if ! command -v java >/dev/null 2>&1; then
    err "java is required to run bundletool but was not found on PATH."
    return 1
  fi

  # `bundletool dump manifest` decodes the compiled (protobuf) manifest back
  # to plain XML, e.g.:
  #   <uses-permission android:name="android.permission.INTERNET"/>
  java -jar "$bundletool_jar" dump manifest --bundle "$aab_path" \
    | tr '>' '>\n' \
    | sed -n 's/.*<uses-permission[^a-zA-Z]*android:name="\([^"]*\)".*/\1/p'
}

# --- policy evaluation --------------------------------------------------------

# Reads permission names (one per line) from the file given as $2 and fails if
# any exactly matches a prohibited permission. $1 is a human-readable label.
evaluate_permissions() {
  local label="$1"
  local permissions_file="$2"

  local -a found_prohibited=()
  local permission prohibited
  while IFS= read -r permission; do
    [[ -n "$permission" ]] || continue
    for prohibited in "${PROHIBITED_PERMISSIONS[@]}"; do
      # Exact match only: similar-but-different names (e.g. a vendor-prefixed
      # com.example.android.permission.READ_MEDIA_IMAGES) must not trip this.
      if [[ "$permission" == "$prohibited" ]]; then
        found_prohibited+=("$permission")
      fi
    done
  done < "$permissions_file"

  echo "Permissions in $label:"
  sed 's/^/  /' "$permissions_file"

  if (( ${#found_prohibited[@]} > 0 )); then
    err ""
    err "FAIL: $label contains prohibited broad storage/media permission(s):"
    for permission in "${found_prohibited[@]}"; do
      err "  - $permission"
    done
    err ""
    err "Calee must not request broad storage or media-library access."
    err "These permissions usually arrive through a dependency's Android"
    err "library manifest during manifest merging. Fix: add or restore a"
    err "tools:node=\"remove\" <uses-permission> entry for each permission in"
    err "android/app/src/main/AndroidManifest.xml, or drop/adjust the"
    err "dependency that introduces it. See that manifest's comment block."
    return 1
  fi

  echo "OK: $label contains no prohibited broad storage/media permissions."
  return 0
}

check_artifact() {
  local kind="$1"
  local artifact_path="$2"

  if [[ ! -f "$artifact_path" ]]; then
    err "$kind not found: $artifact_path"
    return 1
  fi

  local tmp_list
  tmp_list="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp_list'" RETURN

  case "$kind" in
    APK) extract_apk_permissions "$artifact_path" > "$tmp_list" ;;
    AAB) extract_aab_permissions "$artifact_path" > "$tmp_list" ;;
    *) err "Unknown artifact kind: $kind"; return 1 ;;
  esac

  if [[ ! -s "$tmp_list" ]]; then
    err "FAIL: extracted zero permissions from $kind '$artifact_path'."
    err "Calee always declares android.permission.INTERNET, so an empty list"
    err "means the extraction itself failed; refusing to report success."
    return 1
  fi

  evaluate_permissions "$kind $artifact_path" "$tmp_list"
}

# --- commands -----------------------------------------------------------------

cmd_check() {
  local apk_path="" aab_path="" permissions_file=""

  while (( $# > 0 )); do
    case "$1" in
      --apk)
        [[ $# -ge 2 ]] || { err "--apk requires a path argument"; return 2; }
        apk_path="$2"; shift 2 ;;
      --aab)
        [[ $# -ge 2 ]] || { err "--aab requires a path argument"; return 2; }
        aab_path="$2"; shift 2 ;;
      --permissions-file)
        [[ $# -ge 2 ]] || { err "--permissions-file requires a path argument"; return 2; }
        permissions_file="$2"; shift 2 ;;
      *)
        err "Unknown argument: $1"; usage >&2; return 2 ;;
    esac
  done

  if [[ -n "$permissions_file" ]]; then
    if [[ -n "$apk_path" || -n "$aab_path" ]]; then
      err "--permissions-file cannot be combined with --apk/--aab."
      return 2
    fi
    if [[ ! -f "$permissions_file" ]]; then
      err "Permissions fixture not found: $permissions_file"
      return 1
    fi
    evaluate_permissions "permission list $permissions_file" "$permissions_file"
    return
  fi

  if [[ -z "$apk_path" && -z "$aab_path" ]]; then
    err "check requires at least one artifact (--apk PATH and/or --aab PATH)."
    usage >&2
    return 2
  fi

  local failed=0
  if [[ -n "$apk_path" ]]; then
    check_artifact APK "$apk_path" || failed=1
    echo ""
  fi
  if [[ -n "$aab_path" ]]; then
    check_artifact AAB "$aab_path" || failed=1
    echo ""
  fi

  if (( failed )); then
    err "Prohibited permissions detected; failing the release permission check."
    return 1
  fi
  echo "All inspected artifacts are free of prohibited storage/media permissions."
}

# Synthetic-fixture selftest. Proves the policy evaluation and exit-status
# propagation without needing the Android SDK, bundletool, or any built
# artifact — safe to run first in every CI job that uses this script.
cmd_selftest() {
  local self_path
  self_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp_dir'" RETURN

  local failures=0

  # expect_status <expected> <fixture-name> <fixture-content...>
  expect_status() {
    local expected="$1" name="$2"
    shift 2
    local fixture="$tmp_dir/$name.txt"
    printf '%s\n' "$@" > "$fixture"

    local status=0
    # Run through the real entry point so a failing check is proven to
    # propagate a non-zero exit status to the caller.
    bash "$self_path" check --permissions-file "$fixture" >/dev/null 2>&1 || status=$?

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

  echo "selftest: prohibited permissions must fail"
  expect_status nonzero read-media-images \
    "android.permission.INTERNET" "android.permission.READ_MEDIA_IMAGES"
  expect_status nonzero read-media-video \
    "android.permission.INTERNET" "android.permission.READ_MEDIA_VIDEO"
  expect_status nonzero read-media-audio \
    "android.permission.INTERNET" "android.permission.READ_MEDIA_AUDIO"
  expect_status nonzero read-external-storage \
    "android.permission.INTERNET" "android.permission.READ_EXTERNAL_STORAGE"
  expect_status nonzero write-external-storage \
    "android.permission.INTERNET" "android.permission.WRITE_EXTERNAL_STORAGE"
  expect_status nonzero manage-external-storage \
    "android.permission.INTERNET" "android.permission.MANAGE_EXTERNAL_STORAGE"
  expect_status nonzero read-media-visual-user-selected \
    "android.permission.INTERNET" "android.permission.READ_MEDIA_VISUAL_USER_SELECTED"

  echo "selftest: the expected Calee permission set must pass"
  expect_status 0 clean-calee-permissions \
    "android.permission.INTERNET" \
    "android.permission.CAMERA" \
    "android.permission.POST_NOTIFICATIONS" \
    "android.permission.RECEIVE_BOOT_COMPLETED" \
    "android.permission.WAKE_LOCK" \
    "android.permission.VIBRATE" \
    "android.permission.SCHEDULE_EXACT_ALARM"

  echo "selftest: similar but non-identical names must NOT match"
  expect_status 0 lookalike-permissions \
    "com.example.android.permission.READ_MEDIA_IMAGES" \
    "android.permission.READ_MEDIA_IMAGES_EXTENDED" \
    "android.permission.READ_MEDIA_IMAGE" \
    "myapp.READ_EXTERNAL_STORAGE" \
    "android.permission.MANAGE_EXTERNAL_STORAGE_SOMETHING"

  echo "selftest: a missing fixture must fail"
  local status=0
  bash "$self_path" check --permissions-file "$tmp_dir/does-not-exist.txt" >/dev/null 2>&1 || status=$?
  if (( status != 0 )); then
    echo "  PASS: missing-fixture (exit $status)"
  else
    echo "  FAIL: missing-fixture (expected non-zero, got 0)"
    failures=$((failures + 1))
  fi

  if (( failures > 0 )); then
    err "selftest FAILED with $failures failing case(s)."
    return 1
  fi
  echo "selftest passed."
}

main() {
  if (( $# < 1 )); then
    usage >&2
    exit 2
  fi

  local command="$1"
  shift

  case "$command" in
    check) cmd_check "$@" ;;
    selftest) cmd_selftest "$@" ;;
    -h|--help|help) usage ;;
    *) err "Unknown command: $command"; usage >&2; exit 2 ;;
  esac
}

main "$@"
