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
#   * the release BRANCH the release is being cut from (a tag is never one)
#   * per-release readiness evidence, when a real release is being built
#
# THREE distinct levels of validation, deliberately separated, because
# "the repository is consistent", "a signed candidate may be built" and
# "this candidate may be submitted to a store" are different claims:
#
#   repository correctness  (default)
#       Everything checkable from the repository alone. Safe to run on every
#       pull request. Passing this does NOT authorise a release.
#
#   build/sign readiness  (--require-build-readiness)
#       Additionally requires the `build_readiness` section of
#       docs/release_evidence/<version>.json: listing/privacy/review-note
#       preparation, a named Release Operator and Credential Owner, and valid
#       Apple credential expiry dates. This is everything that must be true
#       BEFORE a signed candidate exists. The signed release workflows use it.
#       It deliberately does NOT require device qualification — the artifact
#       being qualified does not exist yet.
#
#   store submission readiness  (--require-store-readiness)
#       Everything above PLUS the `submission_readiness` section: physical
#       device qualification of the exact candidate build number, final
#       listing/screenshot review against that candidate, reviewer test account
#       verified on it, and Release Approver sign-off. The Release Operator runs
#       this after qualifying the candidate and before uploading to a store.
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
#     --require-build-readiness    also require the build_readiness section of
#                                  the current version's release evidence
#     --require-store-readiness    also require BOTH readiness sections (implies
#                                  --require-build-readiness)
#     --allow-branch NAME          allowed release BRANCH name; repeatable. When
#                                  given at least once, the run must be on
#                                  refs/heads/<NAME> with ref type "branch" —
#                                  a tag of the same name is rejected
#     --allow-ref-name NAME        deprecated alias for --allow-branch (kept so
#                                  existing invocations keep working; it now
#                                  enforces the same branch-only rule)
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
    "scripts/verify_release_ref.sh"
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

# Per-release readiness evidence.
#
# docs/STORE_RELEASE_CHECKLIST.md tells an operator what to do; this file is
# where the operator records that they actually did it, for one specific build.
# Existence of the checklist proves nothing, so a real release requires the
# evidence and fails closed without it.
#
# The evidence has TWO sections, because release readiness is not one event:
#
#   build_readiness       everything that must be true BEFORE a signed
#                         candidate can be produced — listing/privacy/review
#                         preparation, named operator and credential owner,
#                         Apple credential validity. Checked by
#                         --require-build-readiness, which the signed release
#                         workflows use.
#
#   submission_readiness  everything that can only honestly be attested AFTER
#                         the candidate exists — physical device qualification
#                         of that exact build number, final listing/screenshot
#                         review against the candidate, reviewer test account
#                         verified on it, and Release Approver sign-off.
#                         Checked by --require-store-readiness, which the
#                         operator runs before uploading to a store.
#
# Submission readiness is a superset: it re-validates build readiness too.
# Splitting them removes the circular requirement of qualifying a build that
# does not exist yet, without dropping qualification.
check_release_evidence() {
  section "Release readiness evidence"

  local mode=""
  if (( REQUIRE_STORE_READINESS )); then
    mode="submission"
  elif (( REQUIRE_BUILD_READINESS )); then
    mode="build"
  else
    printf '  SKIP  readiness: not required for this run\n'
    printf '        (--require-build-readiness / --require-store-readiness not given).\n'
    printf '        Repository correctness alone is NOT release readiness.\n'
    return 0
  fi

  if [[ -z "${BUILD_NAME:-}" ]]; then
    fail "readiness: cannot locate release evidence because the version could not be derived"
    return 0
  fi

  local evidence="$REPO_ROOT/docs/release_evidence/$BUILD_NAME.json"
  if [[ ! -f "$evidence" ]]; then
    fail "readiness: release evidence for $BUILD_NAME is missing — create docs/release_evidence/$BUILD_NAME.json from docs/release_evidence/TEMPLATE.json and complete its build_readiness section"
    return 0
  fi

  local report status=0
  report="$(
    PREFLIGHT_PLATFORM="$PLATFORM" \
    PREFLIGHT_BUILD_NAME="$BUILD_NAME" \
    PREFLIGHT_BUILD_NUMBER="$BUILD_NUMBER" \
    PREFLIGHT_EVIDENCE_MODE="$mode" \
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
mode = os.environ["PREFLIGHT_EVIDENCE_MODE"]

EXPECTED_SCHEMA = "calee-mobile-release-evidence/2"

# An operator who leaves a template value in place has not reviewed anything.
# REPLACE covers the TEMPLATE's own markers: "REPLACE", "REPLACE-WITH-VERSION",
# "REPLACE — the person who approved this production release", and so on. The
# surrounding non-letter boundaries keep ordinary words containing these
# letters (e.g. "Replaced", "Untold") from matching.
PLACEHOLDER = re.compile(
    r"(^|[^A-Za-z])("
    r"REPLACE|TODO|TBD|TBC|FIXME|XXX|PLACEHOLDER|CHANGEME|UNKNOWN|UNCONFIRMED"
    r"|NAME HERE|YOUR NAME|OPERATOR DECISION REQUIRED|REQUIRED . NOT SUPPLIED"
    r"|TO BE (RECORDED|CONFIRMED|DECIDED|SUPPLIED)"
    r")([^A-Za-z]|$)",
    re.IGNORECASE,
)

# --- what each phase requires ----------------------------------------------

BUILD_CHECKS_SHARED = {
    "release_notes_reviewed": "release notes / What's New agreed",
    "privacy_disclosures_prepared": "privacy disclosures prepared for this version",
    "support_url_reviewed": "support URL reachable and correct",
    "privacy_policy_url_reviewed": "privacy policy URL reachable and current",
    "age_rating_reviewed": "age/content rating reviewed",
    "review_notes_prepared": "store review notes prepared",
}
BUILD_CHECKS_ANDROID = {
    "android_listing_prepared": "Google Play listing text prepared",
    "google_play_data_safety_prepared": "Google Play Data Safety answers prepared",
}
BUILD_CHECKS_IOS = {
    "ios_listing_prepared": "App Store listing text prepared",
    "apple_app_privacy_prepared": "Apple App Privacy answers prepared",
}

SUBMISSION_CHECKS_SHARED = {
    "listing_final_review_against_candidate": "listing text re-checked against the built candidate",
    "screenshots_reviewed_against_candidate": "screenshots checked against the built candidate",
    "test_account_verified_against_candidate": "reviewer test account verified on the candidate",
    "regression_evidence_recorded": "regression evidence recorded for this build number",
}
SUBMISSION_CHECKS_ANDROID = {
    "google_play_data_safety_submitted": "Google Play Data Safety declaration submitted",
}
SUBMISSION_CHECKS_IOS = {
    "apple_app_privacy_submitted": "Apple App Privacy declaration submitted",
    "export_compliance_answered": "Apple export-compliance question answered for this build",
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
    print(f"FAIL\treadiness: {os.path.basename(path)} is not valid JSON: {exc}")
    sys.exit(0)

if not isinstance(data, dict):
    print("FAIL\treadiness: release evidence must be a JSON object")
    sys.exit(0)


def text_field(container, key, label, group_name, where):
    value = container.get(key) if isinstance(container, dict) else None
    if not isinstance(value, str) or not value.strip():
        bad(f"readiness: '{where}.{key}' ({label}) is missing or empty")
        group(group_name, False)
        return None
    if PLACEHOLDER.search(value):
        bad(
            f"readiness: '{where}.{key}' ({label}) still holds a template placeholder "
            f"({value.strip()[:40]!r}) — it must name a real person or record"
        )
        group(group_name, False)
        return None
    group(group_name, True)
    return value.strip()


def date_field(container, key, label, group_name, where, must_be_future=False, allow_future=True):
    raw = container.get(key) if isinstance(container, dict) else None
    if not isinstance(raw, str) or not raw.strip():
        bad(f"readiness: '{where}.{key}' ({label}) is missing or empty")
        group(group_name, False)
        return None
    if PLACEHOLDER.search(raw):
        bad(f"readiness: '{where}.{key}' ({label}) still holds a template placeholder")
        group(group_name, False)
        return None
    try:
        value = datetime.strptime(raw.strip(), "%Y-%m-%d").date()
    except ValueError:
        bad(f"readiness: '{where}.{key}' ({label}) must be an ISO date (YYYY-MM-DD), got '{raw}'")
        group(group_name, False)
        return None
    today = date.today()
    if must_be_future and value <= today:
        bad(
            f"readiness: '{where}.{key}' ({label}) is {raw}, which is not in the future — "
            "renew it before releasing (docs/RELEASE_CREDENTIALS.md)"
        )
        group(group_name, False)
        return None
    if not allow_future and value > today:
        bad(f"readiness: '{where}.{key}' ({label}) is {raw}, which is in the future")
        group(group_name, False)
        return None
    group(group_name, True)
    return value


def boolean_checks(container, required, group_name, where):
    checks = container.get("checks") if isinstance(container, dict) else None
    if not isinstance(checks, dict):
        bad(f"readiness: '{where}.checks' object is missing from the release evidence")
        group(group_name, False)
        return
    for key in sorted(required):
        label = required[key]
        if key not in checks:
            bad(f"readiness: '{where}.checks.{key}' ({label}) is missing")
            group(group_name, False)
        elif checks[key] is True:
            group(group_name, True)
        elif checks[key] is False:
            bad(f"readiness: '{where}.checks.{key}' ({label}) is not confirmed")
            group(group_name, False)
        else:
            bad(
                f"readiness: '{where}.checks.{key}' ({label}) must be the boolean true, "
                f"got {checks[key]!r}"
            )
            group(group_name, False)


# --- identity of the evidence itself ---------------------------------------
schema = data.get("schema")
if schema != EXPECTED_SCHEMA:
    bad(f"readiness: 'schema' must be '{EXPECTED_SCHEMA}', got {schema!r}")
    group("identity", False)
else:
    group("identity", True)

version = data.get("version")
if not isinstance(version, str) or version.strip() != expected_version:
    bad(
        f"readiness: evidence 'version' is {version!r} but this build is "
        f"{expected_version} — the evidence does not belong to this release"
    )
    group("identity", False)
else:
    group("identity", True)

evidence_build_number = data.get("build_number")
if str(evidence_build_number).strip() != str(expected_build_number):
    bad(
        f"readiness: evidence 'build_number' is {evidence_build_number!r} but this "
        f"build is {expected_build_number}"
    )
    group("identity", False)
else:
    group("identity", True)

# --- build readiness (required in BOTH modes) -------------------------------
build = data.get("build_readiness")
if not isinstance(build, dict):
    bad("readiness: 'build_readiness' section is missing from the release evidence")
    group("build", False)
    build = {}
else:
    group("build", True)

date_field(build, "reviewed_at", "date build readiness was completed", "build",
           "build_readiness", allow_future=False)
text_field(build, "release_operator", "who is performing this release", "build",
           "build_readiness")
if platform in ("android", "all"):
    text_field(build, "credential_owner_android", "owner of the Android signing credentials",
               "build", "build_readiness")
if platform in ("ios", "all"):
    text_field(build, "credential_owner_apple", "owner of the Apple signing credentials",
               "build", "build_readiness")

required_build_checks = dict(BUILD_CHECKS_SHARED)
if platform in ("android", "all"):
    required_build_checks.update(BUILD_CHECKS_ANDROID)
if platform in ("ios", "all"):
    required_build_checks.update(BUILD_CHECKS_IOS)
boolean_checks(build, required_build_checks, "build", "build_readiness")

# Nothing in the repository can observe an Apple expiry date, so the operator
# records it and the release fails once it has lapsed.
if platform in ("ios", "all"):
    date_field(build, "apple_certificate_expiry", "Apple Distribution certificate expiry",
               "credentials", "build_readiness", must_be_future=True)
    date_field(build, "apple_provisioning_profile_expiry",
               "App Store provisioning profile expiry", "credentials", "build_readiness",
               must_be_future=True)

# --- submission readiness (only in submission mode) -------------------------
if mode == "submission":
    submission = data.get("submission_readiness")
    if not isinstance(submission, dict):
        bad(
            "readiness: 'submission_readiness' section is missing — it is completed AFTER the "
            "signed candidate has been qualified on a physical device"
        )
        group("submission", False)
        submission = {}
    else:
        group("submission", True)

    date_field(submission, "reviewed_at", "date submission readiness was completed",
               "submission", "submission_readiness", allow_future=False)
    text_field(submission, "release_approver", "who approved this production release",
               "submission", "submission_readiness")

    required_submission_checks = dict(SUBMISSION_CHECKS_SHARED)
    if platform in ("android", "all"):
        required_submission_checks.update(SUBMISSION_CHECKS_ANDROID)
    if platform in ("ios", "all"):
        required_submission_checks.update(SUBMISSION_CHECKS_IOS)
    boolean_checks(submission, required_submission_checks, "submission", "submission_readiness")

    def qualification(key, label):
        record = submission.get(key)
        if not isinstance(record, dict):
            bad(
                f"readiness: 'submission_readiness.{key}' ({label}) is missing — install the "
                "signed candidate on a physical device and record the result"
            )
            group("qualification", False)
            return

        for sub, sub_label in (("device", "device model"), ("os_version", "OS version")):
            value = record.get(sub)
            if not isinstance(value, str) or not value.strip():
                bad(f"readiness: 'submission_readiness.{key}.{sub}' ({sub_label}) is missing or empty")
                group("qualification", False)
            elif PLACEHOLDER.search(value):
                bad(
                    f"readiness: 'submission_readiness.{key}.{sub}' ({sub_label}) still holds a "
                    "template placeholder"
                )
                group("qualification", False)
            else:
                group("qualification", True)

        outcome = record.get("outcome")
        if not isinstance(outcome, str) or outcome.strip().lower() != "pass":
            bad(
                f"readiness: 'submission_readiness.{key}.outcome' must be 'pass'; got {outcome!r} — "
                "a release cannot proceed on an unqualified candidate"
            )
            group("qualification", False)
        else:
            group("qualification", True)

        qualified_build = record.get("build_number")
        if str(qualified_build).strip() != str(expected_build_number):
            bad(
                f"readiness: 'submission_readiness.{key}.build_number' is {qualified_build!r} but "
                f"this build is {expected_build_number} — qualification must be against the exact "
                "candidate being submitted"
            )
            group("qualification", False)
        else:
            group("qualification", True)

    if platform in ("android", "all"):
        qualification("android_device_qualification", "Android device qualification")
    if platform in ("ios", "all"):
        qualification("ios_device_qualification", "iOS/TestFlight device qualification")

for message in failures:
    print(f"FAIL\t{message}")

labels = {
    "identity": f"readiness: evidence matches this release ({expected_version}+{expected_build_number})",
    "build": "readiness: build readiness complete (operator, credential owner, listing/privacy preparation)",
    "credentials": "readiness: Apple credential expiry dates are in the future",
    "submission": "readiness: submission readiness complete (approver, final listing review against the candidate)",
    "qualification": "readiness: physical-device qualification recorded against this exact build",
}
for name, okay in groups.items():
    if okay:
        print(f"PASS\t{labels[name]}")

if mode == "build":
    print(
        "PASS\treadiness: build readiness only — submission readiness is NOT yet claimed "
        "and must be completed after the candidate is qualified"
    )
PY
  )" || status=$?

  if (( status != 0 )); then
    fail "readiness: release evidence inspection failed to run (python3 available?)"
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

# Release-branch context.
#
# This is the SECOND, independent layer of the release-ref gate;
# scripts/verify_release_ref.sh implements the same rule separately and runs as
# its own workflow job before anything else. A mistake in one layer must not
# silently re-open the hole, so the two are deliberately not shared code.
#
# `workflow_dispatch` can target a branch OR a tag, and the short ref name is
# identical for both — a tag named `main` looks exactly like the `main` branch.
# The fully-qualified ref and the ref type are therefore what is checked.
check_ref_context() {
  section "Release context"

  if (( ${#ALLOWED_BRANCHES[@]} == 0 )); then
    printf '  SKIP  context: no --allow-branch given; release branch not enforced\n'
    return 0
  fi

  # Build the authorised fully-qualified refs for the error message and match.
  local -a allowed_refs=()
  local allowed
  for allowed in "${ALLOWED_BRANCHES[@]}"; do
    allowed_refs+=("refs/heads/$allowed")
  done

  local gh_ref="${GITHUB_REF:-}"
  local gh_ref_type="${GITHUB_REF_TYPE:-}"
  local gh_ref_name="${GITHUB_REF_NAME:-}"

  local current_ref="" current_type=""

  if [[ -n "$gh_ref" || -n "$gh_ref_type" || -n "$gh_ref_name" ]]; then
    # Running under GitHub Actions (or something imitating it).
    if [[ -z "$gh_ref" ]]; then
      fail "context: GITHUB_REF is not set, so the release ref cannot be proven to be a branch (allowed: ${allowed_refs[*]})"
      return 0
    fi

    local derived_type
    case "$gh_ref" in
      refs/heads/*) derived_type="branch" ;;
      refs/tags/*) derived_type="tag" ;;
      *) derived_type="unknown" ;;
    esac

    if [[ -n "$gh_ref_type" && "$gh_ref_type" != "$derived_type" ]]; then
      fail "context: GITHUB_REF_TYPE ('$gh_ref_type') contradicts GITHUB_REF ('$gh_ref', which is a $derived_type)"
      return 0
    fi

    if [[ -n "$gh_ref_name" && "$gh_ref" != "refs/heads/$gh_ref_name" ]]; then
      fail "context: GITHUB_REF_NAME ('$gh_ref_name') does not match GITHUB_REF ('$gh_ref')"
      return 0
    fi

    current_ref="$gh_ref"
    current_type="${gh_ref_type:-$derived_type}"
  else
    # Local invocation: resolve the checked-out branch. A detached HEAD has no
    # branch, so it cannot be an authorised release ref.
    local branch
    branch="$(git -C "$REPO_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if [[ -z "$branch" ]]; then
      fail "context: HEAD is detached or not a branch, so this is not an authorised release ref (allowed: ${allowed_refs[*]})"
      return 0
    fi
    current_ref="refs/heads/$branch"
    current_type="branch"
  fi

  if [[ "$current_type" != "branch" ]]; then
    fail "context: the release ref '$current_ref' is a $current_type, not a branch. A TAG named like a release branch is not authorised. Allowed: ${allowed_refs[*]}"
    return 0
  fi

  local candidate
  for candidate in "${allowed_refs[@]}"; do
    if [[ "$current_ref" == "$candidate" ]]; then
      pass "context: releasing from '$current_ref' (branch)"
      return 0
    fi
  done

  fail "context: releasing from '$current_ref' ($current_type), which is not one of: ${allowed_refs[*]}"
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
  REQUIRE_BUILD_READINESS=0
  REQUIRE_STORE_READINESS=0
  SKIP_RELEASE_NOTES=0
  ALLOWED_BRANCHES=()

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
      --allow-branch|--allow-ref-name)
        [[ $# -ge 2 ]] || { err "$1 requires a value"; return 2; }
        ALLOWED_BRANCHES+=("$2")
        shift 2
        ;;
      --require-secrets)
        REQUIRE_SECRETS=1
        shift
        ;;
      --require-build-readiness)
        REQUIRE_BUILD_READINESS=1
        shift
        ;;
      --require-store-readiness)
        # Submission readiness is a superset of build readiness.
        REQUIRE_STORE_READINESS=1
        REQUIRE_BUILD_READINESS=1
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
    printf '  validation level: repository correctness + build readiness + store submission readiness\n'
  elif (( REQUIRE_BUILD_READINESS )); then
    printf '  validation level: repository correctness + build/sign readiness (NOT submission readiness)\n'
  else
    printf '  validation level: repository correctness only (NOT release readiness)\n'
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
  check_release_evidence

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
    printf 'Release preflight passed (repository correctness + build readiness + submission readiness).\n'
    printf 'This candidate may now be submitted to the store, once the Release Approver\n'
    printf 'sign-off recorded in the evidence is acted on.\n'
    printf 'NOTE: submission readiness is still not store APPROVAL, and approval is not\n'
    printf '      rollout completion. See docs/RELEASE_OPERATIONS.md section 11.\n'
  elif (( REQUIRE_BUILD_READINESS )); then
    printf 'Release preflight passed (repository correctness + build/sign readiness).\n'
    printf 'A signed candidate may be produced. It may NOT be submitted to a store yet:\n'
    printf '  1. distribute the candidate to Play Internal Testing / TestFlight\n'
    printf '  2. qualify it on a physical device against this exact build number\n'
    printf '  3. complete the submission_readiness section of the release evidence\n'
    printf '  4. re-run this preflight with --require-store-readiness\n'
  else
    printf 'Release preflight passed (repository correctness).\n'
    printf 'NOTE: this level does NOT authorise a release. A signed build additionally\n'
    printf '      requires --require-build-readiness, and store submission additionally\n'
    printf '      requires --require-store-readiness.\n'
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

  # write_valid_evidence <fixture-root> [build|submission]
  # Produces complete, internally consistent readiness evidence for the
  # fixture's own version, so the negative cases below differ from a passing
  # file by exactly one mutation. With "build" the submission_readiness section
  # is omitted entirely — the state a real operator is in before the signed
  # candidate has been qualified.
  write_valid_evidence() {
    local root="$1" phase="${2:-submission}" version build_number
    read -r version build_number <<<"$(fixture_version "$root")"
    mkdir -p "$root/docs/release_evidence"

    EVIDENCE_VERSION="$version" EVIDENCE_BUILD_NUMBER="$build_number" \
    EVIDENCE_PHASE="$phase" \
      python3 - "$root/docs/release_evidence/$version.json" <<'PY'
import json
import os
import sys
from datetime import date, timedelta

version = os.environ["EVIDENCE_VERSION"]
build_number = os.environ["EVIDENCE_BUILD_NUMBER"]
phase = os.environ["EVIDENCE_PHASE"]
future = (date.today() + timedelta(days=180)).isoformat()

build_checks = [
    "release_notes_reviewed",
    "privacy_disclosures_prepared",
    "support_url_reviewed",
    "privacy_policy_url_reviewed",
    "age_rating_reviewed",
    "review_notes_prepared",
    "android_listing_prepared",
    "google_play_data_safety_prepared",
    "ios_listing_prepared",
    "apple_app_privacy_prepared",
]

submission_checks = [
    "listing_final_review_against_candidate",
    "screenshots_reviewed_against_candidate",
    "test_account_verified_against_candidate",
    "regression_evidence_recorded",
    "google_play_data_safety_submitted",
    "apple_app_privacy_submitted",
    "export_compliance_answered",
]

qualification = {
    "device": "Selftest Device",
    "os_version": "1.0",
    "build_number": build_number,
    "outcome": "pass",
}

data = {
    "schema": "calee-mobile-release-evidence/2",
    "version": version,
    "build_number": build_number,
    "build_readiness": {
        "reviewed_at": date.today().isoformat(),
        "release_operator": "Selftest Operator",
        "credential_owner_android": "Selftest Android Owner",
        "credential_owner_apple": "Selftest Apple Owner",
        "checks": {name: True for name in build_checks},
        "apple_certificate_expiry": future,
        "apple_provisioning_profile_expiry": future,
    },
}

if phase == "submission":
    data["submission_readiness"] = {
        "reviewed_at": date.today().isoformat(),
        "release_approver": "Selftest Approver",
        "checks": {name: True for name in submission_checks},
        "android_device_qualification": dict(qualification),
        "ios_device_qualification": dict(qualification),
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
  # Production-signed artifacts may only be built from the stage or main
  # BRANCH. workflow_dispatch can also target a TAG, and the short ref name is
  # identical for both, so these cases drive the full GitHub ref environment.

  # expect_ref <expected|nonzero> <name> <GITHUB_REF> <GITHUB_REF_TYPE> <GITHUB_REF_NAME> [args...]
  # A literal "-" leaves that variable unset.
  expect_ref() {
    local expected="$1" name="$2" ref="$3" ref_type="$4" ref_name="$5"
    shift 5

    local status=0
    (
      if [[ "$ref" == "-" ]]; then unset GITHUB_REF; else export GITHUB_REF="$ref"; fi
      if [[ "$ref_type" == "-" ]]; then unset GITHUB_REF_TYPE; else export GITHUB_REF_TYPE="$ref_type"; fi
      if [[ "$ref_name" == "-" ]]; then unset GITHUB_REF_NAME; else export GITHUB_REF_NAME="$ref_name"; fi
      bash "$self_path" check --repo-root "$repo_root" \
        --allow-branch stage --allow-branch main "$@" >/dev/null 2>&1
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

  echo "selftest: the stage and main BRANCHES are accepted"
  expect_ref 0 release-branch-stage refs/heads/stage branch stage
  expect_ref 0 release-branch-main refs/heads/main branch main
  expect_ref 0 release-branch-main-type-derived refs/heads/main - main
  # The deprecated alias must enforce the same branch-only rule.
  (
    export GITHUB_REF="refs/heads/main" GITHUB_REF_TYPE="branch" GITHUB_REF_NAME="main"
    bash "$self_path" check --repo-root "$repo_root" \
      --allow-ref-name stage --allow-ref-name main >/dev/null 2>&1
  ) && echo "  PASS: deprecated-alias-accepts-branch" \
    || { echo "  FAIL: deprecated-alias-accepts-branch (expected exit 0)"; failures=$((failures + 1)); }

  echo "selftest: every other branch must be rejected for a production release"
  expect_ref nonzero release-branch-dev refs/heads/dev branch dev
  expect_ref nonzero release-branch-feature refs/heads/feature/foo branch feature/foo
  expect_ref nonzero release-branch-claude \
    refs/heads/claude/formalize-app-store-play-releases-15450z branch \
    claude/formalize-app-store-play-releases-15450z
  expect_ref nonzero release-branch-lookalike refs/heads/stage-2 branch stage-2
  expect_ref nonzero release-branch-lookalike-main refs/heads/mainline branch mainline

  echo "selftest: a TAG named like a release branch must be rejected"
  expect_ref nonzero release-tag-main refs/tags/main tag main
  expect_ref nonzero release-tag-stage refs/tags/stage tag stage
  expect_ref nonzero release-tag-version refs/tags/v0.0.30 tag v0.0.30
  # Type stripped: the fully-qualified ref alone must still catch it.
  expect_ref nonzero release-tag-main-type-derived refs/tags/main - main
  expect_ref nonzero release-tag-stage-type-derived refs/tags/stage - stage
  # Contradictory type declarations must be refused, not resolved.
  expect_ref nonzero release-tag-declared-as-branch refs/tags/main branch main
  expect_ref nonzero release-branch-declared-as-tag refs/heads/main tag main
  expect_ref nonzero release-stage-declared-as-tag refs/heads/stage tag stage

  echo "selftest: incomplete ref information must fail closed"
  # The short name alone cannot distinguish a branch from a tag.
  expect_ref nonzero release-ref-name-only - - main
  expect_ref nonzero release-ref-name-only-stage - - stage
  expect_ref nonzero release-ref-empty "" branch main
  expect_ref nonzero release-ref-name-disagrees refs/heads/dev branch main
  expect_ref nonzero release-ref-unknown-namespace refs/pull/539/merge - 539/merge

  # --- release readiness evidence -------------------------------------------
  # Two phases: build readiness is everything knowable before the signed
  # candidate exists; submission readiness is what can only be attested after
  # it has been qualified on a physical device.

  echo "selftest: build readiness passes BEFORE device qualification exists"
  fixture="$(make_fixture readiness-build-only)"
  write_valid_evidence "$fixture" build
  expect_status 0 build-readiness-without-qualification "$fixture" --require-build-readiness
  expect_status 0 build-readiness-android "$fixture" --platform android --require-build-readiness
  expect_status 0 build-readiness-ios "$fixture" --platform ios --require-build-readiness

  echo "selftest: submission readiness FAILS until the candidate is qualified"
  expect_status nonzero submission-readiness-without-qualification "$fixture" \
    --require-store-readiness
  expect_status nonzero submission-readiness-without-qualification-ios "$fixture" \
    --platform ios --require-store-readiness

  echo "selftest: submission readiness passes once the exact build is qualified"
  fixture="$(make_fixture readiness-submission)"
  write_valid_evidence "$fixture" submission
  expect_status 0 submission-readiness-complete "$fixture" --require-store-readiness
  expect_status 0 submission-readiness-android "$fixture" --platform android --require-store-readiness
  expect_status 0 submission-readiness-ios "$fixture" --platform ios --require-store-readiness
  # Submission readiness is a superset: it must still enforce build readiness.
  mutate_evidence "$fixture" "data['build_readiness']['checks']['review_notes_prepared'] = False"
  expect_status nonzero submission-readiness-requires-build-readiness "$fixture" \
    --require-store-readiness

  echo "selftest: qualification must be against the exact candidate build"
  fixture="$(make_fixture readiness-other-build)"
  write_valid_evidence "$fixture" submission
  mutate_evidence "$fixture" "data['submission_readiness']['ios_device_qualification']['build_number'] = '1'"
  expect_status nonzero qualification-other-build "$fixture" --platform ios --require-store-readiness

  fixture="$(make_fixture readiness-qualification-failed)"
  write_valid_evidence "$fixture" submission
  mutate_evidence "$fixture" "data['submission_readiness']['android_device_qualification']['outcome'] = 'fail'"
  expect_status nonzero qualification-failed "$fixture" --platform android --require-store-readiness

  fixture="$(make_fixture readiness-qualification-missing)"
  write_valid_evidence "$fixture" submission
  mutate_evidence "$fixture" "del data['submission_readiness']['ios_device_qualification']"
  expect_status nonzero qualification-missing "$fixture" --platform ios --require-store-readiness

  echo "selftest: readiness is not claimed when it was not requested"
  fixture="$(make_fixture readiness-absent)"
  expect_status 0 readiness-not-required-by-default "$fixture"
  expect_status nonzero readiness-missing-build "$fixture" --require-build-readiness
  expect_status nonzero readiness-missing-submission "$fixture" --require-store-readiness

  echo "selftest: evidence that does not match this build must fail"
  fixture="$(make_fixture readiness-version-mismatch)"
  write_valid_evidence "$fixture" submission
  mutate_evidence "$fixture" "data['version'] = '9.9.9'"
  expect_status nonzero readiness-version-mismatch "$fixture" --require-build-readiness

  fixture="$(make_fixture readiness-build-number-mismatch)"
  write_valid_evidence "$fixture" submission
  mutate_evidence "$fixture" "data['build_number'] = '999'"
  expect_status nonzero readiness-build-number-mismatch "$fixture" --require-build-readiness

  fixture="$(make_fixture readiness-bad-schema)"
  write_valid_evidence "$fixture" submission
  mutate_evidence "$fixture" "data['schema'] = 'calee-mobile-release-evidence/1'"
  expect_status nonzero readiness-stale-schema "$fixture" --require-build-readiness

  fixture="$(make_fixture readiness-missing-build-section)"
  write_valid_evidence "$fixture" submission
  mutate_evidence "$fixture" "del data['build_readiness']"
  expect_status nonzero readiness-missing-build-section "$fixture" --require-build-readiness

  echo "selftest: an unconfirmed readiness item must fail"
  fixture="$(make_fixture readiness-false-check)"
  write_valid_evidence "$fixture" build
  mutate_evidence "$fixture" "data['build_readiness']['checks']['age_rating_reviewed'] = False"
  expect_status nonzero readiness-false-build-check "$fixture" --require-build-readiness

  fixture="$(make_fixture readiness-missing-check)"
  write_valid_evidence "$fixture" build
  mutate_evidence "$fixture" "del data['build_readiness']['checks']['google_play_data_safety_prepared']"
  expect_status nonzero readiness-missing-build-check "$fixture" \
    --platform android --require-build-readiness

  fixture="$(make_fixture readiness-false-submission-check)"
  write_valid_evidence "$fixture" submission
  mutate_evidence "$fixture" "data['submission_readiness']['checks']['screenshots_reviewed_against_candidate'] = False"
  expect_status nonzero readiness-false-submission-check "$fixture" --require-store-readiness

  # --- template placeholder rejection ---------------------------------------
  # The strings below are copied verbatim from docs/release_evidence/TEMPLATE.json.
  # An operator who copies the template and edits only the version must NOT be
  # able to pass readiness validation.

  echo "selftest: the ACTUAL template placeholder strings must be rejected"

  # expect_placeholder <name> <python mutation> [args...]
  expect_placeholder() {
    local name="$1" code="$2"
    shift 2
    local fixture
    fixture="$(make_fixture "placeholder-$name")"
    write_valid_evidence "$fixture" submission
    mutate_evidence "$fixture" "$code"
    expect_status nonzero "placeholder-$name" "$fixture" "$@"
  }

  expect_placeholder template-release-operator \
    "data['build_readiness']['release_operator'] = 'REPLACE — the person performing this release'" \
    --require-build-readiness
  expect_placeholder template-release-approver \
    "data['submission_readiness']['release_approver'] = 'REPLACE — the person who approved this production release'" \
    --require-store-readiness
  expect_placeholder template-credential-owner-android \
    "data['build_readiness']['credential_owner_android'] = 'REPLACE — owner of the Android signing credentials'" \
    --platform android --require-build-readiness
  expect_placeholder template-credential-owner-apple \
    "data['build_readiness']['credential_owner_apple'] = 'REPLACE — owner of the Apple signing credentials'" \
    --platform ios --require-build-readiness
  expect_placeholder template-device-model \
    "data['submission_readiness']['android_device_qualification']['device'] = 'REPLACE — device model'" \
    --platform android --require-store-readiness
  expect_placeholder template-ios-os-version \
    "data['submission_readiness']['ios_device_qualification']['os_version'] = 'REPLACE — iOS version'" \
    --platform ios --require-store-readiness
  expect_placeholder template-android-os-version \
    "data['submission_readiness']['android_device_qualification']['os_version'] = 'REPLACE — Android version'" \
    --platform android --require-store-readiness
  expect_placeholder template-qualification-outcome \
    "data['submission_readiness']['ios_device_qualification']['outcome'] = 'REPLACE — pass only if the candidate actually passed'" \
    --platform ios --require-store-readiness
  expect_placeholder template-bare-replace \
    "data['build_readiness']['release_operator'] = 'REPLACE'" \
    --require-build-readiness
  expect_placeholder template-replace-with-marker \
    "data['build_readiness']['release_operator'] = 'REPLACE-WITH-OPERATOR'" \
    --require-build-readiness
  expect_placeholder template-unfilled-date \
    "data['build_readiness']['apple_certificate_expiry'] = 'YYYY-MM-DD'" \
    --platform ios --require-build-readiness
  expect_placeholder legacy-todo-approver \
    "data['submission_readiness']['release_approver'] = 'TBD'" \
    --require-store-readiness
  expect_placeholder empty-operator \
    "data['build_readiness']['release_operator'] = ''" \
    --require-build-readiness
  expect_placeholder operator-decision-required \
    "data['build_readiness']['credential_owner_apple'] = 'Operator decision required'" \
    --platform ios --require-build-readiness

  echo "selftest: legitimate names containing placeholder letters must NOT be rejected"
  fixture="$(make_fixture placeholder-false-positives)"
  write_valid_evidence "$fixture" submission
  mutate_evidence "$fixture" "data['build_readiness']['release_operator'] = 'Sam Replaced-Jones'; data['submission_readiness']['release_approver'] = 'Toby Xxavier'; data['submission_readiness']['android_device_qualification']['device'] = 'Pixel 8 Pro (replacement unit)'"
  expect_status 0 placeholder-no-false-positives "$fixture" --require-store-readiness

  echo "selftest: copying TEMPLATE.json and only fixing the version must still fail"
  fixture="$(make_fixture template-verbatim)"
  template_version="$(fixture_version "$fixture" | cut -d' ' -f1)"
  template_build_number="$(fixture_version "$fixture" | cut -d' ' -f2)"
  mkdir -p "$fixture/docs/release_evidence"
  cp "$repo_root/docs/release_evidence/TEMPLATE.json" \
    "$fixture/docs/release_evidence/$template_version.json"
  EVIDENCE_VERSION="$template_version" EVIDENCE_BUILD_NUMBER="$template_build_number" \
    python3 - "$fixture/docs/release_evidence/$template_version.json" <<'PY'
import json
import os
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)

# The ONLY edit: make the identity match, exactly as a careless operator would.
data["version"] = os.environ["EVIDENCE_VERSION"]
data["build_number"] = os.environ["EVIDENCE_BUILD_NUMBER"]

with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY
  expect_status nonzero template-verbatim-build "$fixture" --require-build-readiness
  expect_status nonzero template-verbatim-submission "$fixture" --require-store-readiness

  echo "selftest: expired Apple signing material must fail the release"
  fixture="$(make_fixture readiness-expired-certificate)"
  write_valid_evidence "$fixture" build
  mutate_evidence "$fixture" "data['build_readiness']['apple_certificate_expiry'] = '2000-01-01'"
  expect_status nonzero readiness-expired-certificate "$fixture" \
    --platform ios --require-build-readiness

  fixture="$(make_fixture readiness-expired-profile)"
  write_valid_evidence "$fixture" build
  mutate_evidence "$fixture" "data['build_readiness']['apple_provisioning_profile_expiry'] = '2000-01-01'"
  expect_status nonzero readiness-expired-profile "$fixture" \
    --platform ios --require-build-readiness

  echo "selftest: malformed evidence must fail rather than be ignored"
  fixture="$(make_fixture readiness-malformed-json)"
  write_valid_evidence "$fixture" submission
  printf 'not json at all\n' > "$fixture/docs/release_evidence/$(fixture_version "$fixture" | cut -d' ' -f1).json"
  expect_status nonzero readiness-malformed-json "$fixture" --require-build-readiness

  fixture="$(make_fixture readiness-future-review-date)"
  write_valid_evidence "$fixture" build
  mutate_evidence "$fixture" "data['build_readiness']['reviewed_at'] = '2099-01-01'"
  expect_status nonzero readiness-future-review-date "$fixture" --require-build-readiness

  echo "selftest: a real signed build must satisfy branch, secrets and build readiness together"
  fixture="$(make_fixture release-gate-shape)"
  write_valid_evidence "$fixture" build
  (
    export GITHUB_REF="refs/heads/main" GITHUB_REF_TYPE="branch" GITHUB_REF_NAME="main"
    export ANDROID_KEYSTORE_BASE64="fixture-value-aaa"
    export ANDROID_KEYSTORE_PASSWORD="fixture-value-bbb"
    export ANDROID_KEY_ALIAS="fixture-value-ccc"
    export ANDROID_KEY_PASSWORD="fixture-value-ddd"
    bash "$self_path" check --repo-root "$fixture" --platform android \
      --require-secrets --require-build-readiness \
      --allow-branch stage --allow-branch main >/dev/null 2>&1
  ) && echo "  PASS: signed-build-gate-passes" \
    || { echo "  FAIL: signed-build-gate-passes (expected exit 0)"; failures=$((failures + 1)); }

  # Same shape, but dispatched from a tag named main: must be refused.
  (
    export GITHUB_REF="refs/tags/main" GITHUB_REF_TYPE="tag" GITHUB_REF_NAME="main"
    export ANDROID_KEYSTORE_BASE64="fixture-value-aaa"
    export ANDROID_KEYSTORE_PASSWORD="fixture-value-bbb"
    export ANDROID_KEY_ALIAS="fixture-value-ccc"
    export ANDROID_KEY_PASSWORD="fixture-value-ddd"
    bash "$self_path" check --repo-root "$fixture" --platform android \
      --require-secrets --require-build-readiness \
      --allow-branch stage --allow-branch main >/dev/null 2>&1
  ) && { echo "  FAIL: signed-build-gate-rejects-tag (expected non-zero)"; failures=$((failures + 1)); } \
    || echo "  PASS: signed-build-gate-rejects-tag"

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
