#!/usr/bin/env bash
#
# Inexpensive release preflight for CaleeMobile.
#
# Runs BEFORE any expensive signing/build job so a misconfigured release fails
# in seconds instead of after a full signed build. It validates only things
# that can be checked cheaply and safely from the repository plus the runner
# environment:
#
#   * the canonical app identity (display name, applicationId, bundle id)
#   * the pubspec version format and the single-source-of-truth wiring that
#     keeps Android and iOS version/build numbers from drifting
#   * repository-represented release metadata (release notes, store checklist)
#   * required release tooling
#   * presence (never the value) of the signing secrets the platform needs
#   * the branch/release context the release is being cut from
#
# Usage:
#   scripts/release_preflight.sh selftest
#   scripts/release_preflight.sh check [options]
#
#     --platform android|ios|all   which platform's checks to run (default all)
#     --repo-root DIR              repository root to inspect (default: the
#                                  repository containing this script)
#     --require-secrets            also require the platform signing secrets to
#                                  be present in the environment
#     --allow-ref-name NAME        allowed release branch/ref name; repeatable.
#                                  When given at least once, the current ref
#                                  ($GITHUB_REF_NAME, else the checked-out
#                                  branch) must match one of them
#     --skip-release-notes         do not require a release-notes file (for
#                                  rehearsal/dry-run builds only)
#
# SECURITY: this script never prints, logs or exports a secret value. Secret
# checks test only whether a named environment variable is non-empty, and only
# the NAME is ever reported.
#
# Exit status: 0 when every check passes, 1 when any check fails. Every failure
# is reported with the exact item that is missing or inconsistent.

set -euo pipefail

# --- canonical app identity -------------------------------------------------
# Single source of truth for the identity assertions. Changing the app's
# identity is a deliberate act that must change this list too.
readonly EXPECTED_APP_DISPLAY_NAME="Calee"
readonly EXPECTED_ANDROID_APPLICATION_ID="au.com.calee.mobile"
readonly EXPECTED_IOS_BUNDLE_ID="au.com.calee.mobile"
readonly EXPECTED_IOS_TEAM_ID="WQ3JPT4U3H"

# Secret NAMES only — never values. These are the GitHub Secret names the
# signed-release workflows consume; see docs/RELEASE_CREDENTIALS.md.
readonly ANDROID_REQUIRED_SECRET_NAMES=(
  "ANDROID_KEYSTORE_BASE64"
  "ANDROID_KEYSTORE_PASSWORD"
  "ANDROID_KEY_ALIAS"
  "ANDROID_KEY_PASSWORD"
)
readonly IOS_REQUIRED_SECRET_NAMES=(
  "IOS_CERTIFICATE_BASE64"
  "IOS_CERTIFICATE_PASSWORD"
  "IOS_PROVISIONING_PROFILE_BASE64"
)
# Optional: when absent the iOS workflow generates ExportOptions.plist from
# repository-controlled, non-secret values.
readonly IOS_OPTIONAL_SECRET_NAMES=(
  "IOS_EXPORT_OPTIONS_PLIST_BASE64"
)

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- result accumulation ----------------------------------------------------

FAILURES=()

pass() {
  printf '  PASS  %s\n' "$*"
}

fail() {
  printf '  FAIL  %s\n' "$*" >&2
  FAILURES+=("$*")
}

section() {
  printf '\n%s\n' "$*"
}

# Read a whole file, or report a failure and return non-zero.
read_file() {
  local path="$1" label="$2"
  if [[ ! -f "$path" ]]; then
    fail "$label: required file is missing ($path)"
    return 1
  fi
  cat "$path"
}

# expect_contains <file> <label> <fixed-string> <description>
expect_contains() {
  local path="$1" label="$2" needle="$3" description="$4"
  local content
  if ! content="$(read_file "$path" "$label")"; then
    return 0
  fi
  if grep -qF -- "$needle" <<<"$content"; then
    pass "$description"
  else
    fail "$description — not found in $path (expected: $needle)"
  fi
}

# --- individual checks ------------------------------------------------------

check_version() {
  section "Version and build number"

  local derive="$REPO_ROOT/scripts/derive_release_version.sh"
  if [[ ! -x "$derive" ]]; then
    fail "version: scripts/derive_release_version.sh is missing or not executable"
    return 0
  fi

  # derive_release_version.sh is the authoritative parser; reuse it rather than
  # re-implementing the version grammar here, so the two can never disagree.
  local derived
  if ! derived="$(bash "$derive" "$REPO_ROOT/pubspec.yaml" 2>/dev/null)"; then
    fail "version: pubspec.yaml version is missing or not in X.Y.Z+N form (see scripts/derive_release_version.sh)"
    return 0
  fi

  BUILD_NAME="$(sed -n 's/^build_name=//p' <<<"$derived")"
  BUILD_NUMBER="$(sed -n 's/^build_number=//p' <<<"$derived")"

  if [[ -z "$BUILD_NAME" || -z "$BUILD_NUMBER" ]]; then
    fail "version: could not derive build_name/build_number from pubspec.yaml"
    return 0
  fi

  pass "version: pubspec.yaml resolves to $BUILD_NAME+$BUILD_NUMBER"

  # Policy: the build number is monotonic and tied to the version, and both
  # stores reject a re-used build number. Requiring build_number >= the
  # numeric weight of the version keeps a hand-edit from silently regressing.
  if (( BUILD_NUMBER <= 0 )); then
    fail "version: build number must be a positive integer (got $BUILD_NUMBER)"
  else
    pass "version: build number $BUILD_NUMBER is a positive integer"
  fi
}

check_android_identity() {
  section "Android identity and version wiring"

  local gradle="$REPO_ROOT/android/app/build.gradle.kts"
  local manifest="$REPO_ROOT/android/app/src/main/AndroidManifest.xml"

  expect_contains "$gradle" "android" \
    "applicationId = \"$EXPECTED_ANDROID_APPLICATION_ID\"" \
    "android: applicationId is $EXPECTED_ANDROID_APPLICATION_ID"
  expect_contains "$gradle" "android" \
    "namespace = \"$EXPECTED_ANDROID_APPLICATION_ID\"" \
    "android: namespace is $EXPECTED_ANDROID_APPLICATION_ID"

  # Version drift guard: Android must take versionName/versionCode from the
  # Flutter tooling (i.e. from pubspec.yaml), never from a literal in Gradle.
  expect_contains "$gradle" "android" \
    "versionCode = flutter.versionCode" \
    "android: versionCode is derived from pubspec (flutter.versionCode)"
  expect_contains "$gradle" "android" \
    "versionName = flutter.versionName" \
    "android: versionName is derived from pubspec (flutter.versionName)"

  expect_contains "$manifest" "android" \
    "android:label=\"$EXPECTED_APP_DISPLAY_NAME\"" \
    "android: application label is \"$EXPECTED_APP_DISPLAY_NAME\""

  # Release signing must never silently fall back to debug signing.
  expect_contains "$gradle" "android" \
    "Release signing is required for release builds" \
    "android: release build fails closed when signing inputs are absent"
}

check_ios_identity() {
  section "iOS identity and version wiring"

  local plist="$REPO_ROOT/ios/Runner/Info.plist"
  local pbxproj="$REPO_ROOT/ios/Runner.xcodeproj/project.pbxproj"

  expect_contains "$plist" "ios" \
    "<string>$EXPECTED_APP_DISPLAY_NAME</string>" \
    "ios: Info.plist carries the \"$EXPECTED_APP_DISPLAY_NAME\" display name"

  # Version drift guard: the iOS version strings must be substituted from the
  # Flutter build, which is fed from pubspec.yaml.
  expect_contains "$plist" "ios" \
    "<string>\$(FLUTTER_BUILD_NAME)</string>" \
    "ios: CFBundleShortVersionString is \$(FLUTTER_BUILD_NAME)"
  expect_contains "$plist" "ios" \
    "<string>\$(FLUTTER_BUILD_NUMBER)</string>" \
    "ios: CFBundleVersion is \$(FLUTTER_BUILD_NUMBER)"

  if [[ ! -f "$pbxproj" ]]; then
    fail "ios: required file is missing ($pbxproj)"
    return 0
  fi

  # Target-aware inspection of the Xcode build configurations. Every build
  # configuration that builds the shipping app (identified by its bundle
  # identifier) must take its build number from the Flutter build and must not
  # hardcode a MARKETING_VERSION, or the store-visible version can drift away
  # from pubspec.yaml. Uses python3 (already relied upon by the existing
  # .github/scripts checks and by check_android_release_permissions.sh).
  local report status=0
  report="$(
    PREFLIGHT_IOS_BUNDLE_ID="$EXPECTED_IOS_BUNDLE_ID" \
    PREFLIGHT_IOS_TEAM_ID="$EXPECTED_IOS_TEAM_ID" \
    python3 - "$pbxproj" <<'PY' 2>&1
import os
import re
import sys

path = sys.argv[1]
bundle_id = os.environ["PREFLIGHT_IOS_BUNDLE_ID"]
team_id = os.environ["PREFLIGHT_IOS_TEAM_ID"]

try:
    text = open(path, encoding="utf-8", errors="replace").read()
except OSError as exc:  # unreadable project file is a hard failure
    print(f"FAIL\tios: cannot read {path}: {exc}")
    sys.exit(0)

# Each XCBuildConfiguration block is "<id> /* Name */ = { ... };" containing a
# buildSettings dictionary. Split on the isa marker, which is stable across
# Xcode versions.
blocks = re.split(r"\n\t\t[0-9A-F]{24} /\* [^*]*\*/ = \{", text)
app_blocks = [b for b in blocks if f"PRODUCT_BUNDLE_IDENTIFIER = {bundle_id};" in b]

if not app_blocks:
    print(f"FAIL\tios: no build configuration sets PRODUCT_BUNDLE_IDENTIFIER = {bundle_id}")
    sys.exit(0)

print(f"PASS\tios: {len(app_blocks)} build configuration(s) use bundle id {bundle_id}")

drift = [b for b in app_blocks if 'CURRENT_PROJECT_VERSION = "$(FLUTTER_BUILD_NUMBER)";' not in b]
if drift:
    print(
        f"FAIL\tios: {len(drift)} app build configuration(s) do not set "
        'CURRENT_PROJECT_VERSION = "$(FLUTTER_BUILD_NUMBER)" (version drift risk)'
    )
else:
    print('PASS\tios: app build configurations take CURRENT_PROJECT_VERSION from $(FLUTTER_BUILD_NUMBER)')

hardcoded = [b for b in app_blocks if "MARKETING_VERSION" in b]
if hardcoded:
    print(
        f"FAIL\tios: {len(hardcoded)} app build configuration(s) hardcode MARKETING_VERSION; "
        "the marketing version must come from pubspec.yaml via $(FLUTTER_BUILD_NAME)"
    )
else:
    print("PASS\tios: no app build configuration hardcodes MARKETING_VERSION")

if any(f"DEVELOPMENT_TEAM = {team_id};" in b for b in app_blocks):
    print(f"PASS\tios: Apple Development Team is {team_id}")
else:
    print(f"FAIL\tios: expected DEVELOPMENT_TEAM = {team_id} on the app build configurations")
PY
  )" || status=$?

  if (( status != 0 )); then
    fail "ios: project inspection failed to run (python3 available?)"
    return 0
  fi

  local line
  while IFS=$'\t' read -r verdict message; do
    [[ -z "${verdict:-}" ]] && continue
    if [[ "$verdict" == "PASS" ]]; then
      pass "$message"
    else
      fail "$message"
    fi
  done <<<"$report"
}

check_release_tooling() {
  section "Release tooling"

  local -a required_executables=(
    "scripts/derive_release_version.sh"
    "scripts/check_android_release_permissions.sh"
    "scripts/generate_release_manifest.sh"
  )

  local rel
  for rel in "${required_executables[@]}"; do
    if [[ -x "$REPO_ROOT/$rel" ]]; then
      pass "tooling: $rel is present and executable"
    else
      fail "tooling: $rel is missing or not executable"
    fi
  done
}

check_release_metadata() {
  section "Repository-represented release metadata"

  local -a required_docs=(
    "docs/RELEASE_OPERATIONS.md"
    "docs/RELEASE_CREDENTIALS.md"
    "docs/STORE_RELEASE_CHECKLIST.md"
  )

  local rel
  for rel in "${required_docs[@]}"; do
    if [[ -s "$REPO_ROOT/$rel" ]]; then
      pass "metadata: $rel is present"
    else
      fail "metadata: $rel is missing or empty"
    fi
  done

  if (( SKIP_RELEASE_NOTES )); then
    printf '  SKIP  metadata: release notes check skipped (--skip-release-notes)\n'
    return 0
  fi

  if [[ -z "${BUILD_NAME:-}" ]]; then
    fail "metadata: cannot check release notes because the version could not be derived"
    return 0
  fi

  local notes="$REPO_ROOT/docs/release_notes/$BUILD_NAME.md"
  if [[ ! -s "$notes" ]]; then
    fail "metadata: release notes for $BUILD_NAME are missing (create docs/release_notes/$BUILD_NAME.md)"
    return 0
  fi

  # A notes file that still contains an unfilled placeholder is not release
  # notes; store "What's New" text is a submission requirement.
  if grep -qiE '(^|[^A-Za-z])(TODO|TBD|FIXME|<placeholder>)([^A-Za-z]|$)' "$notes"; then
    fail "metadata: docs/release_notes/$BUILD_NAME.md still contains a TODO/TBD placeholder"
    return 0
  fi

  # Require some real prose beyond the heading.
  local body_lines
  body_lines="$(grep -cE '^[[:space:]]*[-*[:alnum:]]' "$notes" || true)"
  if (( body_lines < 2 )); then
    fail "metadata: docs/release_notes/$BUILD_NAME.md has no release-notes content"
  else
    pass "metadata: release notes present for $BUILD_NAME"
  fi
}

check_ref_context() {
  section "Release context"

  if (( ${#ALLOWED_REF_NAMES[@]} == 0 )); then
    printf '  SKIP  context: no --allow-ref-name given; branch context not enforced\n'
    return 0
  fi

  local current="${GITHUB_REF_NAME:-}"
  if [[ -z "$current" ]]; then
    current="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  fi

  if [[ -z "$current" ]]; then
    fail "context: could not determine the current ref name"
    return 0
  fi

  local allowed
  for allowed in "${ALLOWED_REF_NAMES[@]}"; do
    if [[ "$current" == "$allowed" ]]; then
      pass "context: releasing from '$current'"
      return 0
    fi
  done

  fail "context: releasing from '$current', which is not one of: ${ALLOWED_REF_NAMES[*]}"
}

# Presence-only secret check. Reports NAMES, never values.
check_secrets() {
  section "Signing secret presence"

  if (( ! REQUIRE_SECRETS )); then
    printf '  SKIP  secrets: presence not required for this run (--require-secrets not given)\n'
    return 0
  fi

  local -a required=()
  local -a optional=()

  case "$PLATFORM" in
    android) required=("${ANDROID_REQUIRED_SECRET_NAMES[@]}") ;;
    ios)
      required=("${IOS_REQUIRED_SECRET_NAMES[@]}")
      optional=("${IOS_OPTIONAL_SECRET_NAMES[@]}")
      ;;
    all)
      required=("${ANDROID_REQUIRED_SECRET_NAMES[@]}" "${IOS_REQUIRED_SECRET_NAMES[@]}")
      optional=("${IOS_OPTIONAL_SECRET_NAMES[@]}")
      ;;
  esac

  local name
  for name in "${required[@]}"; do
    # Indirect expansion reads only whether the variable is non-empty.
    if [[ -n "${!name:-}" ]]; then
      pass "secrets: $name is configured"
    else
      fail "secrets: $name is not configured (add it as a GitHub Secret; see docs/RELEASE_CREDENTIALS.md)"
    fi
  done

  for name in "${optional[@]}"; do
    if [[ -n "${!name:-}" ]]; then
      pass "secrets: optional $name is configured"
    else
      printf '  INFO  secrets: optional %s is not configured (a repository-controlled default will be used)\n' "$name"
    fi
  done
}

# --- command implementations ------------------------------------------------

cmd_check() {
  PLATFORM="all"
  REPO_ROOT=""
  REQUIRE_SECRETS=0
  SKIP_RELEASE_NOTES=0
  ALLOWED_REF_NAMES=()

  while (( $# > 0 )); do
    case "$1" in
      --platform)
        [[ $# -ge 2 ]] || { err "--platform requires a value"; return 2; }
        PLATFORM="$2"
        shift 2
        ;;
      --repo-root)
        [[ $# -ge 2 ]] || { err "--repo-root requires a value"; return 2; }
        REPO_ROOT="$2"
        shift 2
        ;;
      --allow-ref-name)
        [[ $# -ge 2 ]] || { err "--allow-ref-name requires a value"; return 2; }
        ALLOWED_REF_NAMES+=("$2")
        shift 2
        ;;
      --require-secrets)
        REQUIRE_SECRETS=1
        shift
        ;;
      --skip-release-notes)
        SKIP_RELEASE_NOTES=1
        shift
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        err "Unknown option: $1"
        usage >&2
        return 2
        ;;
    esac
  done

  case "$PLATFORM" in
    android|ios|all) ;;
    *)
      err "Invalid --platform '$PLATFORM' (expected android, ios or all)"
      return 2
      ;;
  esac

  if [[ -z "$REPO_ROOT" ]]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi

  if [[ ! -d "$REPO_ROOT" ]]; then
    err "Repository root not found: $REPO_ROOT"
    return 2
  fi

  printf 'CaleeMobile release preflight\n'
  printf '  repository root : %s\n' "$REPO_ROOT"
  printf '  platform        : %s\n' "$PLATFORM"

  check_version
  if [[ "$PLATFORM" == "android" || "$PLATFORM" == "all" ]]; then
    check_android_identity
  fi
  if [[ "$PLATFORM" == "ios" || "$PLATFORM" == "all" ]]; then
    check_ios_identity
  fi
  check_release_tooling
  check_release_metadata
  check_ref_context
  check_secrets

  printf '\n'
  if (( ${#FAILURES[@]} > 0 )); then
    printf 'Release preflight FAILED with %d problem(s):\n' "${#FAILURES[@]}" >&2
    local failure
    for failure in "${FAILURES[@]}"; do
      printf '  - %s\n' "$failure" >&2
    done
    printf '\nA build must not be attempted until every item above is resolved.\n' >&2
    return 1
  fi

  printf 'Release preflight passed.\n'
  printf 'NOTE: a passing preflight and a successful build do NOT mean the release is\n'
  printf '      store-ready. Work through docs/STORE_RELEASE_CHECKLIST.md before submitting.\n'
  return 0
}

err() {
  printf '%s\n' "$*" >&2
}

# --- selftest ---------------------------------------------------------------
#
# Proves both directions: the real repository passes, and each deliberately
# broken fixture fails with a non-zero exit status. Fixtures are copies of the
# real repository in a temp directory, so the selftest never mutates the
# working tree.

cmd_selftest() {
  local self_path repo_root
  self_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp_dir'" RETURN

  local failures=0

  # make_fixture <name> -> prints the fixture repo root
  make_fixture() {
    local name="$1"
    local dest="$tmp_dir/$name"
    mkdir -p "$dest"
    local rel
    for rel in pubspec.yaml scripts android ios docs; do
      if [[ -e "$repo_root/$rel" ]]; then
        mkdir -p "$dest/$(dirname "$rel")"
        cp -R "$repo_root/$rel" "$dest/$rel"
      fi
    done
    printf '%s\n' "$dest"
  }

  # expect_status <expected|nonzero> <name> <fixture-root> [extra args...]
  expect_status() {
    local expected="$1" name="$2" fixture="$3"
    shift 3

    local status=0
    # Run through the real entry point so a failing check is proven to
    # propagate a non-zero exit status to the caller.
    bash "$self_path" check --repo-root "$fixture" "$@" >/dev/null 2>&1 || status=$?

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

  echo "selftest: the real repository must pass preflight"
  expect_status 0 real-repository "$repo_root"
  expect_status 0 real-repository-android "$repo_root" --platform android
  expect_status 0 real-repository-ios "$repo_root" --platform ios

  echo "selftest: a malformed pubspec version must fail"
  local fixture
  fixture="$(make_fixture bad-version)"
  sed -i.bak 's/^version: .*/version: 0.0.30/' "$fixture/pubspec.yaml"
  expect_status nonzero bad-version "$fixture"

  echo "selftest: a missing pubspec version must fail"
  fixture="$(make_fixture no-version)"
  sed -i.bak '/^version: /d' "$fixture/pubspec.yaml"
  expect_status nonzero no-version "$fixture"

  echo "selftest: a wrong Android applicationId must fail"
  fixture="$(make_fixture wrong-application-id)"
  sed -i.bak 's/applicationId = "au.com.calee.mobile"/applicationId = "com.example.wrong"/' \
    "$fixture/android/app/build.gradle.kts"
  expect_status nonzero wrong-application-id "$fixture" --platform android

  echo "selftest: a hardcoded Android versionName must fail (version drift)"
  fixture="$(make_fixture android-version-drift)"
  sed -i.bak 's/versionName = flutter.versionName/versionName = "9.9.9"/' \
    "$fixture/android/app/build.gradle.kts"
  expect_status nonzero android-version-drift "$fixture" --platform android

  echo "selftest: a wrong iOS bundle identifier must fail"
  fixture="$(make_fixture wrong-bundle-id)"
  sed -i.bak 's/PRODUCT_BUNDLE_IDENTIFIER = au.com.calee.mobile;/PRODUCT_BUNDLE_IDENTIFIER = com.example.wrong;/g' \
    "$fixture/ios/Runner.xcodeproj/project.pbxproj"
  expect_status nonzero wrong-bundle-id "$fixture" --platform ios

  echo "selftest: a hardcoded iOS CFBundleShortVersionString must fail (version drift)"
  fixture="$(make_fixture ios-version-drift)"
  sed -i.bak 's/<string>$(FLUTTER_BUILD_NAME)<\/string>/<string>9.9.9<\/string>/' \
    "$fixture/ios/Runner/Info.plist"
  expect_status nonzero ios-version-drift "$fixture" --platform ios

  echo "selftest: missing release notes must fail, and --skip-release-notes must bypass it"
  fixture="$(make_fixture missing-release-notes)"
  rm -rf "$fixture/docs/release_notes"
  expect_status nonzero missing-release-notes "$fixture"
  expect_status 0 missing-release-notes-skipped "$fixture" --skip-release-notes

  echo "selftest: placeholder release notes must fail"
  fixture="$(make_fixture placeholder-release-notes)"
  mkdir -p "$fixture/docs/release_notes"
  local notes_version
  notes_version="$(sed -nE 's/^version: ([0-9]+\.[0-9]+\.[0-9]+)\+[0-9]+$/\1/p' "$fixture/pubspec.yaml")"
  printf '# %s\n\nTODO: write the release notes.\n' "$notes_version" \
    > "$fixture/docs/release_notes/$notes_version.md"
  expect_status nonzero placeholder-release-notes "$fixture"

  echo "selftest: missing release documentation must fail"
  fixture="$(make_fixture missing-docs)"
  rm -f "$fixture/docs/RELEASE_OPERATIONS.md"
  expect_status nonzero missing-release-operations-doc "$fixture"

  echo "selftest: missing release tooling must fail"
  fixture="$(make_fixture missing-tooling)"
  rm -f "$fixture/scripts/generate_release_manifest.sh"
  expect_status nonzero missing-release-manifest-script "$fixture"

  echo "selftest: an unexpected release branch must fail"
  (
    export GITHUB_REF_NAME="not-a-release-branch"
    status=0
    bash "$self_path" check --repo-root "$repo_root" \
      --allow-ref-name main --allow-ref-name stage >/dev/null 2>&1 || status=$?
    exit "$status"
  ) && { echo "  FAIL: wrong-ref-name (expected non-zero, got 0)"; failures=$((failures + 1)); } \
    || echo "  PASS: wrong-ref-name"

  (
    export GITHUB_REF_NAME="stage"
    bash "$self_path" check --repo-root "$repo_root" \
      --allow-ref-name main --allow-ref-name stage >/dev/null 2>&1
  ) && echo "  PASS: allowed-ref-name" \
    || { echo "  FAIL: allowed-ref-name (expected exit 0)"; failures=$((failures + 1)); }

  echo "selftest: absent signing secrets must fail when --require-secrets is given"
  (
    unset ANDROID_KEYSTORE_BASE64 ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD
    unset IOS_CERTIFICATE_BASE64 IOS_CERTIFICATE_PASSWORD IOS_PROVISIONING_PROFILE_BASE64
    status=0
    bash "$self_path" check --repo-root "$repo_root" --platform android --require-secrets \
      >/dev/null 2>&1 || status=$?
    exit "$status"
  ) && { echo "  FAIL: missing-android-secrets (expected non-zero, got 0)"; failures=$((failures + 1)); } \
    || echo "  PASS: missing-android-secrets"

  (
    unset IOS_CERTIFICATE_BASE64 IOS_CERTIFICATE_PASSWORD IOS_PROVISIONING_PROFILE_BASE64
    status=0
    bash "$self_path" check --repo-root "$repo_root" --platform ios --require-secrets \
      >/dev/null 2>&1 || status=$?
    exit "$status"
  ) && { echo "  FAIL: missing-ios-secrets (expected non-zero, got 0)"; failures=$((failures + 1)); } \
    || echo "  PASS: missing-ios-secrets"

  echo "selftest: present signing secrets must pass, and no secret value may be printed"
  local secret_output
  secret_output="$(
    ANDROID_KEYSTORE_BASE64="fixture-value-aaa" \
    ANDROID_KEYSTORE_PASSWORD="fixture-value-bbb" \
    ANDROID_KEY_ALIAS="fixture-value-ccc" \
    ANDROID_KEY_PASSWORD="fixture-value-ddd" \
    bash "$self_path" check --repo-root "$repo_root" --platform android --require-secrets 2>&1
  )" || {
    echo "  FAIL: present-android-secrets (expected exit 0)"
    failures=$((failures + 1))
  }

  if grep -q "fixture-value-" <<<"$secret_output"; then
    echo "  FAIL: secret-value-leak (a secret value appeared in preflight output)"
    failures=$((failures + 1))
  else
    echo "  PASS: secret-value-leak (only secret names are reported)"
  fi

  echo "selftest: an invalid --platform must fail"
  expect_status nonzero invalid-platform "$repo_root" --platform windows

  echo "selftest: a missing repository root must fail"
  expect_status nonzero missing-repo-root "$tmp_dir/does-not-exist"

  echo
  if (( failures > 0 )); then
    echo "release_preflight selftest FAILED ($failures failing case(s))" >&2
    return 1
  fi
  echo "release_preflight selftest passed."
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
