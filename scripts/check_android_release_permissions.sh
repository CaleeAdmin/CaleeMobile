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
#   scripts/check_android_release_permissions.sh check --manifest-xml PATH
#   scripts/check_android_release_permissions.sh check --permissions-file PATH
#   scripts/check_android_release_permissions.sh extract-manifest PATH
#
# check mode requires at least one artifact. The AAB is the artifact uploaded
# to Google Play, so release workflows must always pass --aab.
#
#   --apk PATH   inspect a built APK via aapt2/aapt (Android SDK build-tools)
#   --aab PATH   inspect a built AAB via bundletool `dump manifest`; the
#                bundletool jar is located through $BUNDLETOOL_JAR
#   --manifest-xml PATH
#                inspect a manifest XML document directly (e.g. a saved
#                bundletool dump, or a merged manifest); parsed with the same
#                XML parser used for --aab
#   --permissions-file PATH
#                evaluate a plain-text permission list (one permission name
#                per line). FOR SELFTEST/FIXTURE USE ONLY — real verification
#                must inspect the compiled artifacts with --apk/--aab.
#
# extract-manifest prints the uses-permission names of a manifest XML document
# without evaluating policy (diagnostics and selftests).
#
# The check FAILS CLOSED: a missing artifact, a bundletool failure, an
# unparseable manifest, or an extraction that yields zero permissions is an
# error, never a pass.
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
  sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

# Print the android:name of every <uses-permission> element in an Android
# manifest XML document, one per line.
#
# Uses a real XML parser (Python standard library — already present on
# GitHub-hosted runners, no third-party dependency) rather than line-oriented
# text matching. Regex/sed scraping of XML is unreliable here: bundletool is
# free to change indentation, wrap attributes across lines, order attributes
# differently (android:maxSdkVersion before android:name), emit explicit
# closing tags instead of self-closing ones, or vary namespace formatting —
# and every one of those variations could silently hide a prohibited
# permission from a text-matching extractor. Parsing fails closed.
parse_manifest_permissions() {
  local manifest_path="$1"

  if ! command -v python3 >/dev/null 2>&1; then
    err "python3 is required to parse the manifest XML but was not found on PATH."
    return 1
  fi

  python3 - "$manifest_path" <<'PYTHON'
import sys
import xml.etree.ElementTree as ET

ANDROID_NS = "http://schemas.android.com/apk/res/android"
# uses-permission-sdk-23 grants the same access on API 23+, so it is subject
# to exactly the same policy.
PERMISSION_TAGS = {"uses-permission", "uses-permission-sdk-23"}

manifest_path = sys.argv[1]

try:
    root = ET.parse(manifest_path).getroot()
except (ET.ParseError, OSError) as error:
    sys.stderr.write(f"Failed to parse manifest XML '{manifest_path}': {error}\n")
    sys.exit(1)

names = []
for element in root.iter():
    tag = element.tag
    if not isinstance(tag, str):
        continue  # comments / processing instructions
    # Strip any '{namespace}' prefix ElementTree resolved on the tag itself.
    if tag.rsplit("}", 1)[-1] not in PERMISSION_TAGS:
        continue

    # Attribute order is irrelevant to a parser. Prefer the properly
    # namespace-resolved attribute; fall back to a literal 'android:name'
    # (a document with no xmlns:android binding) and finally bare 'name'.
    name = element.get(f"{{{ANDROID_NS}}}name")
    if name is None:
        name = element.get("android:name")
    if name is None:
        name = element.get("name")

    if name is None or not name.strip():
        sys.stderr.write(
            f"Found a <{tag}> element with no android:name attribute in "
            f"'{manifest_path}'; refusing to report an incomplete permission "
            "list.\n"
        )
        sys.exit(1)

    names.append(name.strip())

for name in names:
    print(name)
PYTHON
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
  # to plain XML. Capture it to a file first so a bundletool failure is a
  # hard error here instead of an empty parse further down the pipeline.
  local manifest_xml
  manifest_xml="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$manifest_xml'" RETURN

  if ! java -jar "$bundletool_jar" dump manifest --bundle "$aab_path" > "$manifest_xml"; then
    err "bundletool failed to dump the manifest of '$aab_path'."
    return 1
  fi
  if [[ ! -s "$manifest_xml" ]]; then
    err "bundletool produced an empty manifest dump for '$aab_path'."
    return 1
  fi

  parse_manifest_permissions "$manifest_xml"
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
    manifest) parse_manifest_permissions "$artifact_path" > "$tmp_list" ;;
    *) err "Unknown artifact kind: $kind"; return 1 ;;
  esac

  # Fail closed. Calee always declares android.permission.INTERNET, so an
  # empty extraction means the extraction itself broke (tool change, format
  # change, wrong artifact) — never that the artifact is clean.
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
  local apk_path="" aab_path="" manifest_path="" permissions_file=""

  while (( $# > 0 )); do
    case "$1" in
      --apk)
        [[ $# -ge 2 ]] || { err "--apk requires a path argument"; return 2; }
        apk_path="$2"; shift 2 ;;
      --aab)
        [[ $# -ge 2 ]] || { err "--aab requires a path argument"; return 2; }
        aab_path="$2"; shift 2 ;;
      --manifest-xml)
        [[ $# -ge 2 ]] || { err "--manifest-xml requires a path argument"; return 2; }
        manifest_path="$2"; shift 2 ;;
      --permissions-file)
        [[ $# -ge 2 ]] || { err "--permissions-file requires a path argument"; return 2; }
        permissions_file="$2"; shift 2 ;;
      *)
        err "Unknown argument: $1"; usage >&2; return 2 ;;
    esac
  done

  if [[ -n "$permissions_file" ]]; then
    if [[ -n "$apk_path" || -n "$aab_path" || -n "$manifest_path" ]]; then
      err "--permissions-file cannot be combined with --apk/--aab/--manifest-xml."
      return 2
    fi
    if [[ ! -f "$permissions_file" ]]; then
      err "Permissions fixture not found: $permissions_file"
      return 1
    fi
    evaluate_permissions "permission list $permissions_file" "$permissions_file"
    return
  fi

  if [[ -z "$apk_path" && -z "$aab_path" && -z "$manifest_path" ]]; then
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
  if [[ -n "$manifest_path" ]]; then
    check_artifact manifest "$manifest_path" || failed=1
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

  # --- XML extraction selftests --------------------------------------------
  # The policy cases above only prove the comparison logic. These prove the
  # part that actually reads a bundletool manifest dump: attribute order,
  # line breaks, indentation, self-closing vs explicit closing tags, extra
  # android:* attributes, and namespace formatting must all be handled, and
  # unparseable input must fail rather than silently extract nothing.

  # write_manifest <name> <body...> -> path of a manifest XML fixture
  write_manifest() {
    local name="$1"
    shift
    local path="$tmp_dir/$name.xml"
    {
      echo '<?xml version="1.0" encoding="utf-8"?>'
      echo '<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="au.com.calee.mobile">'
      printf '%s\n' "$@"
      echo '</manifest>'
    } > "$path"
    printf '%s\n' "$path"
  }

  # expect_extraction <name> <expected-newline-separated-names> <manifest-path>
  expect_extraction() {
    local name="$1" expected="$2" manifest="$3"
    local actual
    if ! actual="$(bash "$self_path" extract-manifest "$manifest" 2>/dev/null)"; then
      echo "  FAIL: $name (extraction exited non-zero)"
      failures=$((failures + 1))
      return
    fi
    if [[ "$actual" == "$expected" ]]; then
      echo "  PASS: $name"
    else
      echo "  FAIL: $name"
      echo "    expected: $(printf '%s' "$expected" | tr '\n' ' ')"
      echo "    actual:   $(printf '%s' "$actual" | tr '\n' ' ')"
      failures=$((failures + 1))
    fi
  }

  echo "selftest: XML extraction handles real bundletool manifest shapes"

  expect_extraction self-closing \
    "android.permission.READ_MEDIA_IMAGES" \
    "$(write_manifest self-closing \
      '    <uses-permission android:name="android.permission.READ_MEDIA_IMAGES"/>')"

  # android:name is NOT the first attribute, and the element wraps lines.
  expect_extraction name-after-other-attribute \
    "android.permission.READ_EXTERNAL_STORAGE" \
    "$(write_manifest name-after-other-attribute \
      '    <uses-permission' \
      '        android:maxSdkVersion="32"' \
      '        android:name="android.permission.READ_EXTERNAL_STORAGE" />')"

  # Explicit closing tag rather than a self-closing element.
  expect_extraction explicit-closing-tag \
    "android.permission.READ_MEDIA_VIDEO" \
    "$(write_manifest explicit-closing-tag \
      '    <uses-permission android:name="android.permission.READ_MEDIA_VIDEO">' \
      '    </uses-permission>')"

  # Trailing extra attribute after android:name, multi-line.
  expect_extraction extra-trailing-attribute \
    "android.permission.READ_MEDIA_AUDIO" \
    "$(write_manifest extra-trailing-attribute \
      '    <uses-permission' \
      '        android:name="android.permission.READ_MEDIA_AUDIO"' \
      '        android:maxSdkVersion="34" />')"

  expect_extraction ordinary-allowed-permissions \
    "$(printf 'android.permission.INTERNET\nandroid.permission.CAMERA')" \
    "$(write_manifest ordinary-allowed-permissions \
      '    <uses-permission android:name="android.permission.INTERNET"/>' \
      '    <uses-permission android:name="android.permission.CAMERA"/>')"

  # Many permissions, mixed formatting, plus non-permission elements that
  # must be ignored.
  expect_extraction multiple-mixed-permissions \
    "$(printf 'android.permission.INTERNET\nandroid.permission.CAMERA\nandroid.permission.READ_MEDIA_IMAGES\nandroid.permission.POST_NOTIFICATIONS')" \
    "$(write_manifest multiple-mixed-permissions \
      '    <uses-permission android:name="android.permission.INTERNET"/>' \
      '    <uses-feature android:name="android.hardware.camera" android:required="false"/>' \
      '    <uses-permission' \
      '        android:name="android.permission.CAMERA" />' \
      '    <uses-permission android:maxSdkVersion="33" android:name="android.permission.READ_MEDIA_IMAGES">' \
      '    </uses-permission>' \
      '    <application android:label="Calee"/>' \
      '    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>')"

  # uses-permission-sdk-23 grants the same access and must be extracted too.
  expect_extraction uses-permission-sdk-23 \
    "android.permission.READ_MEDIA_VIDEO" \
    "$(write_manifest uses-permission-sdk-23 \
      '    <uses-permission-sdk-23 android:name="android.permission.READ_MEDIA_VIDEO"/>')"

  # A lookalike must be extracted verbatim (and later not match the policy).
  expect_extraction lookalike-extracted-verbatim \
    "com.example.permission.READ_MEDIA_IMAGES" \
    "$(write_manifest lookalike-extracted-verbatim \
      '    <uses-permission android:name="com.example.permission.READ_MEDIA_IMAGES"/>')"

  echo "selftest: XML edge cases must fail closed"

  local malformed="$tmp_dir/malformed.xml"
  cat > "$malformed" <<'MALFORMED'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.READ_MEDIA_IMAGES"
</manifest>
MALFORMED
  status=0
  bash "$self_path" extract-manifest "$malformed" >/dev/null 2>&1 || status=$?
  if (( status != 0 )); then
    echo "  PASS: malformed-xml-extraction (exit $status)"
  else
    echo "  FAIL: malformed-xml-extraction (expected non-zero, got 0)"
    failures=$((failures + 1))
  fi

  # A malformed manifest must also fail the *overall* check, not just the
  # extractor helper.
  status=0
  bash "$self_path" check --manifest-xml "$malformed" >/dev/null 2>&1 || status=$?
  if (( status != 0 )); then
    echo "  PASS: malformed-xml-check (exit $status)"
  else
    echo "  FAIL: malformed-xml-check (expected non-zero, got 0)"
    failures=$((failures + 1))
  fi

  # No uses-permission elements at all: extraction is empty, and because
  # Calee always declares INTERNET the check must treat that as a failure.
  local no_permissions
  no_permissions="$(write_manifest no-permissions '    <application android:label="Calee"/>')"
  status=0
  bash "$self_path" check --manifest-xml "$no_permissions" >/dev/null 2>&1 || status=$?
  if (( status != 0 )); then
    echo "  PASS: empty-extraction-fails-closed (exit $status)"
  else
    echo "  FAIL: empty-extraction-fails-closed (expected non-zero, got 0)"
    failures=$((failures + 1))
  fi

  # A uses-permission element with no android:name means the parser cannot
  # produce a complete list; refuse rather than under-report.
  local nameless
  nameless="$(write_manifest nameless-permission \
    '    <uses-permission android:maxSdkVersion="32"/>')"
  status=0
  bash "$self_path" extract-manifest "$nameless" >/dev/null 2>&1 || status=$?
  if (( status != 0 )); then
    echo "  PASS: nameless-permission-fails-closed (exit $status)"
  else
    echo "  FAIL: nameless-permission-fails-closed (expected non-zero, got 0)"
    failures=$((failures + 1))
  fi

  echo "selftest: policy detection over parsed XML"

  # End-to-end through XML: a prohibited permission hidden behind another
  # attribute must still fail the whole command.
  local prohibited_manifest
  prohibited_manifest="$(write_manifest prohibited-in-xml \
    '    <uses-permission android:name="android.permission.INTERNET"/>' \
    '    <uses-permission' \
    '        android:maxSdkVersion="32"' \
    '        android:name="android.permission.READ_MEDIA_VIDEO" />')"
  status=0
  bash "$self_path" check --manifest-xml "$prohibited_manifest" >/dev/null 2>&1 || status=$?
  if (( status != 0 )); then
    echo "  PASS: prohibited-permission-in-xml-fails (exit $status)"
  else
    echo "  FAIL: prohibited-permission-in-xml-fails (expected non-zero, got 0)"
    failures=$((failures + 1))
  fi

  # The permission set Calee actually ships must pass end-to-end through XML.
  local clean_manifest
  clean_manifest="$(write_manifest clean-xml \
    '    <uses-permission android:name="android.permission.INTERNET"/>' \
    '    <uses-permission android:name="android.permission.CAMERA"/>' \
    '    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>' \
    '    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>' \
    '    <uses-permission android:name="com.example.permission.READ_MEDIA_IMAGES"/>')"
  status=0
  bash "$self_path" check --manifest-xml "$clean_manifest" >/dev/null 2>&1 || status=$?
  if (( status == 0 )); then
    echo "  PASS: clean-xml-with-lookalike-passes (exit 0)"
  else
    echo "  FAIL: clean-xml-with-lookalike-passes (expected 0, got $status)"
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
    # Diagnostic/selftest helper: print the uses-permission names of a
    # manifest XML document (e.g. a saved `bundletool dump manifest` output)
    # without evaluating policy.
    extract-manifest)
      if (( $# != 1 )); then
        err "extract-manifest requires exactly one manifest XML path"
        return 2 2>/dev/null || exit 2
      fi
      parse_manifest_permissions "$1"
      ;;
    -h|--help|help) usage ;;
    *) err "Unknown command: $command"; usage >&2; exit 2 ;;
  esac
}

main "$@"
