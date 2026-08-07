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
#   * per-release store-readiness evidence, when a real release is being built
#
# Two distinct levels of validation, deliberately separated:
#
#   repository correctness  (default)
#       Everything checkable from the repository alone. Safe to run on every
#       pull request. Passing this does NOT mean a release may be submitted.
#
#   store submission readiness  (--require-store-readiness)
#       Additionally requires docs/release_evidence/<version>.json, in which
#       the Release Operator records that the listing, screenshots, privacy
#       disclosures, review notes, device qualification and approver are
#       actually done for THIS version. Only the signed release workflows ask
#       for this level.
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
#     --require-store-readiness    also require valid per-release store-readiness
#                                  evidence for the current version
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

# Per-release store-readiness evidence.
#
# The checklist in docs/STORE_RELEASE_CHECKLIST.md tells an operator what to do;
# this file is where the operator records that they actually did it, for one
# specific version. Existence of the checklist proves nothing, so a real release
# build requires this evidence and fails closed without it.
check_store_readiness() {
  section "Store-readiness evidence"

  if (( ! REQUIRE_STORE_READINESS )); then
    printf '  SKIP  store readiness: not required for this run (--require-store-readiness not given)\n'
    printf '        Repository correctness alone is NOT store readiness.\n'
    return 0
  fi

  if [[ -z "${BUILD_NAME:-}" ]]; then
    fail "store readiness: cannot locate release evidence because the version could not be derived"
    return 0
  fi

  local evidence="$REPO_ROOT/docs/release_evidence/$BUILD_NAME.json"
  if [[ ! -f "$evidence" ]]; then
    fail "store readiness: release evidence for $BUILD_NAME is missing — create docs/release_evidence/$BUILD_NAME.json from docs/release_evidence/TEMPLATE.json and complete it"
    return 0
  fi

  local report status=0
  report="$(
    PREFLIGHT_PLATFORM="$PLATFORM" \
    PREFLIGHT_BUILD_NAME="$BUILD_NAME" \
    PREFLIGHT_BUILD_NUMBER="$BUILD_NUMBER" \
    python3 - "$evidence" <<'PY' 2>&1
import json
import os
import re
import sys
from datetime import date, datetime

path = sys.argv[1]
platform = os.environ["PREFLIGHT_PLATFORM"]
expected_version = os.environ["PREFLIGHT_BUILD_NAME"]
expected_build_number = os.environ["PREFLIGHT_BUILD_NUMBER"]

EXPECTED_SCHEMA = "calee-mobile-release-evidence/1"

# An operator who leaves a template value in place has not reviewed anything.
PLACEHOLDER = re.compile(
    r"(^|[^A-Za-z])("
    r"TODO|TBD|TBC|FIXME|XXX|PLACEHOLDER|CHANGEME|UNKNOWN|UNCONFIRMED"
    r"|NAME HERE|OPERATOR DECISION REQUIRED|TO BE (RECORDED|CONFIRMED|DECIDED)"
    r")([^A-Za-z]|$)",
    re.IGNORECASE,
)

SHARED_CHECKS = {
    "release_notes_reviewed": "release notes / What's New agreed",
    "screenshots_reviewed": "screenshots checked against current product behaviour",
    "privacy_disclosures_reviewed": "privacy disclosures reviewed",
    "support_url_reviewed": "support URL reachable and correct",
    "privacy_policy_url_reviewed": "privacy policy URL reachable and current",
    "age_rating_reviewed": "age/content rating reviewed",
    "review_notes_prepared": "store review notes prepared",
    "test_account_verified": "reviewer test account verified against this build",
}
ANDROID_CHECKS = {
    "android_listing_reviewed": "Google Play listing text reviewed",
    "google_play_data_safety_reviewed": "Google Play Data Safety declaration reviewed",
}
IOS_CHECKS = {
    "ios_listing_reviewed": "App Store listing text reviewed",
    "apple_app_privacy_reviewed": "Apple App Privacy declaration reviewed",
}

failures = []
groups = {}


def bad(message):
    failures.append(message)


def group(name, okay):
    groups[name] = groups.get(name, True) and okay


try:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
except (OSError, ValueError) as exc:
    print(f"FAIL\tstore readiness: {os.path.basename(path)} is not valid JSON: {exc}")
    sys.exit(0)

if not isinstance(data, dict):
    print("FAIL\tstore readiness: release evidence must be a JSON object")
    sys.exit(0)


def text_field(key, label, group_name):
    value = data.get(key)
    if not isinstance(value, str) or not value.strip():
        bad(f"store readiness: '{key}' ({label}) is missing or empty")
        group(group_name, False)
        return None
    if PLACEHOLDER.search(value):
        bad(f"store readiness: '{key}' ({label}) still holds a placeholder value — it must name a real person or record")
        group(group_name, False)
        return None
    group(group_name, True)
    return value.strip()


def date_field(key, label, group_name, must_be_future=False, allow_future=True):
    raw = data.get(key)
    if not isinstance(raw, str) or not raw.strip():
        bad(f"store readiness: '{key}' ({label}) is missing or empty")
        group(group_name, False)
        return None
    try:
        value = datetime.strptime(raw.strip(), "%Y-%m-%d").date()
    except ValueError:
        bad(f"store readiness: '{key}' ({label}) must be an ISO date (YYYY-MM-DD), got '{raw}'")
        group(group_name, False)
        return None
    today = date.today()
    if must_be_future and value <= today:
        bad(f"store readiness: '{key}' ({label}) is {raw}, which is not in the future — renew it before releasing (docs/RELEASE_CREDENTIALS.md)")
        group(group_name, False)
        return None
    if not allow_future and value > today:
        bad(f"store readiness: '{key}' ({label}) is {raw}, which is in the future")
        group(group_name, False)
        return None
    group(group_name, True)
    return value


# --- identity of the evidence itself ---------------------------------------
schema = data.get("schema")
if schema != EXPECTED_SCHEMA:
    bad(f"store readiness: 'schema' must be '{EXPECTED_SCHEMA}', got {schema!r}")
    group("identity", False)
else:
    group("identity", True)

version = data.get("version")
if not isinstance(version, str) or version.strip() != expected_version:
    bad(
        f"store readiness: evidence 'version' is {version!r} but this build is "
        f"{expected_version} — the evidence does not belong to this release"
    )
    group("identity", False)
else:
    group("identity", True)

evidence_build_number = data.get("build_number")
if str(evidence_build_number).strip() != str(expected_build_number):
    bad(
        f"store readiness: evidence 'build_number' is {evidence_build_number!r} but this "
        f"build is {expected_build_number}"
    )
    group("identity", False)
else:
    group("identity", True)

date_field("reviewed_at", "date the evidence was completed", "identity", allow_future=False)

# --- accountable people -----------------------------------------------------
text_field("release_approver", "who approved this production release", "people")
text_field("release_operator", "who is performing this release", "people")
if platform in ("android", "all"):
    text_field("credential_owner_android", "owner of the Android signing credentials", "people")
if platform in ("ios", "all"):
    text_field("credential_owner_apple", "owner of the Apple signing credentials", "people")

# --- review checks ----------------------------------------------------------
required_checks = dict(SHARED_CHECKS)
if platform in ("android", "all"):
    required_checks.update(ANDROID_CHECKS)
if platform in ("ios", "all"):
    required_checks.update(IOS_CHECKS)

checks = data.get("checks")
if not isinstance(checks, dict):
    bad("store readiness: 'checks' object is missing from the release evidence")
    group("checks", False)
else:
    for key in sorted(required_checks):
        label = required_checks[key]
        if key not in checks:
            bad(f"store readiness: 'checks.{key}' ({label}) is missing")
            group("checks", False)
        elif checks[key] is True:
            group("checks", True)
        elif checks[key] is False:
            bad(f"store readiness: 'checks.{key}' ({label}) is not confirmed")
            group("checks", False)
        else:
            bad(
                f"store readiness: 'checks.{key}' ({label}) must be the boolean true, "
                f"got {checks[key]!r}"
            )
            group("checks", False)

# --- device qualification ---------------------------------------------------
def qualification(key, label):
    record = data.get(key)
    if not isinstance(record, dict):
        bad(f"store readiness: '{key}' ({label}) is missing")
        group("qualification", False)
        return

    for sub, sub_label in (("device", "device model"), ("os_version", "OS version")):
        value = record.get(sub)
        if not isinstance(value, str) or not value.strip():
            bad(f"store readiness: '{key}.{sub}' ({sub_label}) is missing or empty")
            group("qualification", False)
        elif PLACEHOLDER.search(value):
            bad(f"store readiness: '{key}.{sub}' ({sub_label}) still holds a placeholder value")
            group("qualification", False)
        else:
            group("qualification", True)

    outcome = record.get("outcome")
    if not isinstance(outcome, str) or outcome.strip().lower() != "pass":
        bad(
            f"store readiness: '{key}.outcome' must be 'pass'; got {outcome!r} — "
            "a release cannot proceed on an unqualified build"
        )
        group("qualification", False)
    else:
        group("qualification", True)

    qualified_build = record.get("build_number")
    if str(qualified_build).strip() != str(expected_build_number):
        bad(
            f"store readiness: '{key}.build_number' is {qualified_build!r} but this build is "
            f"{expected_build_number} — qualification must be against the build being released"
        )
        group("qualification", False)
    else:
        group("qualification", True)


if platform in ("android", "all"):
    qualification("android_device_qualification", "Android device qualification")
if platform in ("ios", "all"):
    qualification("ios_device_qualification", "iOS device qualification")

# --- credential expiry ------------------------------------------------------
# Nothing in the repository can observe an Apple expiry date, so the operator
# records it here and the release fails if it has lapsed.
if platform in ("ios", "all"):
    date_field(
        "apple_certificate_expiry",
        "Apple Distribution certificate expiry",
        "credentials",
        must_be_future=True,
    )
    date_field(
        "apple_provisioning_profile_expiry",
        "App Store provisioning profile expiry",
        "credentials",
        must_be_future=True,
    )

for message in failures:
    print(f"FAIL\t{message}")

labels = {
    "identity": f"store readiness: evidence matches this release ({expected_version}+{expected_build_number})",
    "people": "store readiness: approver, operator and credential owner recorded",
    "checks": f"store readiness: {len(required_checks)} required review item(s) confirmed",
    "qualification": "store readiness: device qualification recorded against this build",
    "credentials": "store readiness: Apple credential expiry dates are in the future",
}
for name, okay in groups.items():
    if okay:
        print(f"PASS\t{labels[name]}")
PY
  )" || status=$?

  if (( status != 0 )); then
    fail "store readiness: release evidence inspection failed to run (python3 available?)"
    return 0
  fi

  local verdict message
  while IFS=$'\t' read -r verdict message; do
    [[ -z "${verdict:-}" ]] && continue
    if [[ "$verdict" == "PASS" ]]; then
      pass "$message"
    else
      fail "$message"
    fi
  done <<<"$report"
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
  REQUIRE_STORE_READINESS=0
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
      --require-store-readiness)
        REQUIRE_STORE_READINESS=1
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
  if (( REQUIRE_STORE_READINESS )); then
    printf '  validation level: repository correctness + store submission readiness\n'
  else
    printf '  validation level: repository correctness only (NOT store readiness)\n'
  fi

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
  check_store_readiness

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

  if (( REQUIRE_STORE_READINESS )); then
    printf 'Release preflight passed (repository correctness + store submission readiness).\n'
    printf 'NOTE: store readiness is still not store APPROVAL, and approval is not rollout\n'
    printf '      completion. See docs/RELEASE_OPERATIONS.md section 11.\n'
  else
    printf 'Release preflight passed (repository correctness).\n'
    printf 'NOTE: this level does NOT establish store readiness. A real release build must\n'
    printf '      run with --require-store-readiness, which requires completed evidence in\n'
    printf '      docs/release_evidence/<version>.json.\n'
  fi
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

  # fixture_version <fixture-root> -> prints "build_name build_number"
  fixture_version() {
    sed -nE 's/^version: ([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)$/\1 \2/p' "$1/pubspec.yaml"
  }

  # write_valid_evidence <fixture-root>
  # Produces complete, internally consistent store-readiness evidence for the
  # fixture's own version, so the negative cases below differ from a passing
  # file by exactly one mutation.
  write_valid_evidence() {
    local root="$1" version build_number
    read -r version build_number <<<"$(fixture_version "$root")"
    mkdir -p "$root/docs/release_evidence"

    EVIDENCE_VERSION="$version" EVIDENCE_BUILD_NUMBER="$build_number" \
      python3 - "$root/docs/release_evidence/$version.json" <<'PY'
import json
import os
import sys
from datetime import date, timedelta

version = os.environ["EVIDENCE_VERSION"]
build_number = os.environ["EVIDENCE_BUILD_NUMBER"]
future = (date.today() + timedelta(days=180)).isoformat()

checks = [
    "release_notes_reviewed",
    "screenshots_reviewed",
    "privacy_disclosures_reviewed",
    "support_url_reviewed",
    "privacy_policy_url_reviewed",
    "age_rating_reviewed",
    "review_notes_prepared",
    "test_account_verified",
    "android_listing_reviewed",
    "google_play_data_safety_reviewed",
    "ios_listing_reviewed",
    "apple_app_privacy_reviewed",
]

qualification = {
    "device": "Selftest Device",
    "os_version": "1.0",
    "build_number": build_number,
    "outcome": "pass",
}

data = {
    "schema": "calee-mobile-release-evidence/1",
    "version": version,
    "build_number": build_number,
    "reviewed_at": date.today().isoformat(),
    "release_approver": "Selftest Approver",
    "release_operator": "Selftest Operator",
    "credential_owner_android": "Selftest Android Owner",
    "credential_owner_apple": "Selftest Apple Owner",
    "checks": {name: True for name in checks},
    "android_device_qualification": dict(qualification),
    "ios_device_qualification": dict(qualification),
    "apple_certificate_expiry": future,
    "apple_provisioning_profile_expiry": future,
}

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY
  }

  # mutate_evidence <fixture-root> <python statements operating on `data`>
  mutate_evidence() {
    local root="$1" code="$2" version
    read -r version _ <<<"$(fixture_version "$root")"
    python3 - "$root/docs/release_evidence/$version.json" "$code" <<'PY'
import json
import sys

path, code = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
exec(code)  # noqa: S102 - selftest fixture mutation
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY
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

  # --- release-branch enforcement -------------------------------------------
  # Production-signed artifacts may only be built from stage or main. These
  # cases run the real entry point with GITHUB_REF_NAME set the way GitHub
  # Actions sets it.

  # expect_ref <expected|nonzero> <name> <ref-name> [extra args...]
  expect_ref() {
    local expected="$1" name="$2" ref="$3"
    shift 3

    local status=0
    (
      export GITHUB_REF_NAME="$ref"
      bash "$self_path" check --repo-root "$repo_root" \
        --allow-ref-name stage --allow-ref-name main "$@" >/dev/null 2>&1
    ) || status=$?

    local ok=0
    if [[ "$expected" == "nonzero" ]]; then
      (( status != 0 )) && ok=1
    elif (( status == expected )); then
      ok=1
    fi

    if (( ok )); then
      echo "  PASS: $name (ref '$ref', exit $status)"
    else
      echo "  FAIL: $name (ref '$ref', expected $expected, got $status)"
      failures=$((failures + 1))
    fi
  }

  echo "selftest: release branches stage/main are accepted"
  expect_ref 0 release-branch-stage stage
  expect_ref 0 release-branch-main main

  echo "selftest: every other branch must be rejected for a production release"
  expect_ref nonzero release-branch-dev dev
  expect_ref nonzero release-branch-feature feature/some-work
  expect_ref nonzero release-branch-claude claude/formalize-app-store-play-releases-15450z
  expect_ref nonzero release-branch-empty ""
  expect_ref nonzero release-branch-lookalike stage-2
  expect_ref nonzero release-branch-lookalike-main mainline

  # --- store-readiness evidence ---------------------------------------------
  # Repository correctness and store submission readiness are separate levels;
  # the evidence file is what turns "the checklist exists" into "the checklist
  # was completed for THIS build by a named person".

  echo "selftest: complete store-readiness evidence is accepted"
  fixture="$(make_fixture evidence-valid)"
  write_valid_evidence "$fixture"
  expect_status 0 evidence-valid "$fixture" --require-store-readiness
  expect_status 0 evidence-valid-android "$fixture" --platform android --require-store-readiness
  expect_status 0 evidence-valid-ios "$fixture" --platform ios --require-store-readiness

  echo "selftest: store readiness is not claimed when it was not requested"
  fixture="$(make_fixture evidence-absent)"
  expect_status 0 evidence-not-required-by-default "$fixture"
  expect_status nonzero evidence-missing "$fixture" --require-store-readiness

  echo "selftest: evidence that does not match this build must fail"
  fixture="$(make_fixture evidence-version-mismatch)"
  write_valid_evidence "$fixture"
  mutate_evidence "$fixture" "data['version'] = '9.9.9'"
  expect_status nonzero evidence-version-mismatch "$fixture" --require-store-readiness

  fixture="$(make_fixture evidence-build-number-mismatch)"
  write_valid_evidence "$fixture"
  mutate_evidence "$fixture" "data['build_number'] = '999'"
  expect_status nonzero evidence-build-number-mismatch "$fixture" --require-store-readiness

  fixture="$(make_fixture evidence-bad-schema)"
  write_valid_evidence "$fixture"
  mutate_evidence "$fixture" "data['schema'] = 'something-else/1'"
  expect_status nonzero evidence-bad-schema "$fixture" --require-store-readiness

  echo "selftest: an unconfirmed store-readiness item must fail"
  fixture="$(make_fixture evidence-false-check)"
  write_valid_evidence "$fixture"
  mutate_evidence "$fixture" "data['checks']['screenshots_reviewed'] = False"
  expect_status nonzero evidence-false-check "$fixture" --require-store-readiness

  fixture="$(make_fixture evidence-missing-check)"
  write_valid_evidence "$fixture"
  mutate_evidence "$fixture" "del data['checks']['google_play_data_safety_reviewed']"
  expect_status nonzero evidence-missing-check "$fixture" --platform android --require-store-readiness

  fixture="$(make_fixture evidence-placeholder-check)"
  write_valid_evidence "$fixture"
  mutate_evidence "$fixture" "data['checks']['age_rating_reviewed'] = 'TODO'"
  expect_status nonzero evidence-placeholder-check "$fixture" --require-store-readiness

  echo "selftest: unidentified approver/operator must fail"
  fixture="$(make_fixture evidence-placeholder-approver)"
  write_valid_evidence "$fixture"
  mutate_evidence "$fixture" "data['release_approver'] = 'TBD'"
  expect_status nonzero evidence-placeholder-approver "$fixture" --require-store-readiness

  fixture="$(make_fixture evidence-empty-operator)"
  write_valid_evidence "$fixture"
  mutate_evidence "$fixture" "data['release_operator'] = ''"
  expect_status nonzero evidence-empty-operator "$fixture" --require-store-readiness

  fixture="$(make_fixture evidence-placeholder-credential-owner)"
  write_valid_evidence "$fixture"
  mutate_evidence "$fixture" "data['credential_owner_apple'] = 'Operator decision required'"
  expect_status nonzero evidence-placeholder-credential-owner "$fixture" \
    --platform ios --require-store-readiness

  echo "selftest: device qualification must be against this build and must pass"
  fixture="$(make_fixture evidence-qualification-failed)"
  write_valid_evidence "$fixture"
  mutate_evidence "$fixture" "data['android_device_qualification']['outcome'] = 'fail'"
  expect_status nonzero evidence-qualification-failed "$fixture" \
    --platform android --require-store-readiness

  fixture="$(make_fixture evidence-qualification-other-build)"
  write_valid_evidence "$fixture"
  mutate_evidence "$fixture" "data['ios_device_qualification']['build_number'] = '1'"
  expect_status nonzero evidence-qualification-other-build "$fixture" \
    --platform ios --require-store-readiness

  fixture="$(make_fixture evidence-qualification-placeholder-device)"
  write_valid_evidence "$fixture"
  mutate_evidence "$fixture" "data['android_device_qualification']['device'] = 'TBD'"
  expect_status nonzero evidence-qualification-placeholder-device "$fixture" \
    --platform android --require-store-readiness

  echo "selftest: expired Apple signing material must fail the release"
  fixture="$(make_fixture evidence-expired-certificate)"
  write_valid_evidence "$fixture"
  mutate_evidence "$fixture" "data['apple_certificate_expiry'] = '2000-01-01'"
  expect_status nonzero evidence-expired-certificate "$fixture" \
    --platform ios --require-store-readiness

  fixture="$(make_fixture evidence-expired-profile)"
  write_valid_evidence "$fixture"
  mutate_evidence "$fixture" "data['apple_provisioning_profile_expiry'] = '2000-01-01'"
  expect_status nonzero evidence-expired-profile "$fixture" \
    --platform ios --require-store-readiness

  echo "selftest: malformed evidence must fail rather than be ignored"
  fixture="$(make_fixture evidence-malformed-json)"
  write_valid_evidence "$fixture"
  printf 'not json at all\n' > "$fixture/docs/release_evidence/$(fixture_version "$fixture" | cut -d' ' -f1).json"
  expect_status nonzero evidence-malformed-json "$fixture" --require-store-readiness

  fixture="$(make_fixture evidence-future-review-date)"
  write_valid_evidence "$fixture"
  mutate_evidence "$fixture" "data['reviewed_at'] = '2099-01-01'"
  expect_status nonzero evidence-future-review-date "$fixture" --require-store-readiness

  echo "selftest: a real release must satisfy branch, secrets and evidence together"
  fixture="$(make_fixture evidence-release-shape)"
  write_valid_evidence "$fixture"
  (
    export GITHUB_REF_NAME="main"
    export ANDROID_KEYSTORE_BASE64="fixture-value-aaa"
    export ANDROID_KEYSTORE_PASSWORD="fixture-value-bbb"
    export ANDROID_KEY_ALIAS="fixture-value-ccc"
    export ANDROID_KEY_PASSWORD="fixture-value-ddd"
    bash "$self_path" check --repo-root "$fixture" --platform android \
      --require-secrets --require-store-readiness \
      --allow-ref-name stage --allow-ref-name main >/dev/null 2>&1
  ) && echo "  PASS: full-release-gate-passes" \
    || { echo "  FAIL: full-release-gate-passes (expected exit 0)"; failures=$((failures + 1)); }

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
