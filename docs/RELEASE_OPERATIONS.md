# Calee Mobile — Release Operations

This document is the authoritative, repository-controlled procedure for releasing
Calee to the Apple App Store and Google Play. It is written so an authorised
operator who has never seen a prior release conversation can perform a release
using this repository alone.

Companion documents:

- [`RELEASE_CREDENTIALS.md`](RELEASE_CREDENTIALS.md) — credential inventory,
  ownership, renewal and rotation.
- [`STORE_RELEASE_CHECKLIST.md`](STORE_RELEASE_CHECKLIST.md) — per-release store
  metadata and submission checklist.

> **A green build is not a release.** A successful APK/AAB/IPA build proves only
> that the code compiled, signed and passed automated tests. It says nothing
> about store metadata completeness, review requirements, store approval,
> rollout state or production health. See
> [Build success is not store readiness](#11-build-success-is-not-store-readiness).

---

## 1. Canonical app identity

| Property | Value |
| --- | --- |
| App display name | `Calee` |
| Android application ID | `au.com.calee.mobile` |
| Android namespace | `au.com.calee.mobile` |
| iOS bundle identifier | `au.com.calee.mobile` |
| Apple Development Team ID | `WQ3JPT4U3H` |
| App Store Connect Apple ID | `6777055895` |
| App Store SKU | `CALEE-MOBILE-01` |
| App Store primary language | English (Australia) |
| App Store category | Productivity |
| App Store subtitle | Shared calendar and tasks |
| Age rating | 4+ |
| Google Play package | `au.com.calee.mobile` |

These values are asserted by `scripts/release_preflight.sh`; a change to the
app's identity must be made in the app configuration **and** in the script's
`EXPECTED_*` constants, or preflight fails.

### Supported production environment

Calee Mobile talks to the Calee production backend. The production hosts the app
is wired to (deep links and associated domains) are:

- `hub.calee.com.au` — native login and shopping deep links
- `calembed.calee.com.au` — calendar-follow links

There is no separate staging build flavour today: `dev`/`stage` builds and the
production build all target the production backend. Do not assume an app-side
environment switch exists.

### Store ownership

| Surface | Role | Named owner |
| --- | --- | --- |
| App Store Connect (listing, submissions) | Credential Owner — Apple | _Operator decision required_ |
| Apple Developer signing assets | Credential Owner — Apple | _Operator decision required_ |
| Google Play Console (listing, releases) | Credential Owner — Google | _Operator decision required_ |
| Android signing credentials | Credential Owner — Android | _Operator decision required_ |
| Approving a production release | Release Approver | _Operator decision required_ |
| Executing a release | Release Operator | _Operator decision required_ |

The named individuals are not recorded anywhere in this repository and were not
available when this document was written. Fill the table in before the next
production release; the roles themselves are used throughout this document and
do not change.

---

## 2. Version and build-number policy

**`pubspec.yaml` is the single authoritative source of version metadata.**
Nothing else in the repository may define an app version.

```
version: <build_name>+<build_number>      # e.g. 0.0.30+30
```

`scripts/derive_release_version.sh` is the only parser of that line. Every
workflow calls it and passes the result to `flutter build` via `--build-name` /
`--build-number`. The platform values are then derived, never hand-written:

| Platform value | Source |
| --- | --- |
| Android `versionName` | `flutter.versionName` → `--build-name` → pubspec `build_name` |
| Android `versionCode` | `flutter.versionCode` → `--build-number` → pubspec `build_number` |
| iOS `CFBundleShortVersionString` | `$(FLUTTER_BUILD_NAME)` → `--build-name` → pubspec `build_name` |
| iOS `CFBundleVersion` | `$(FLUTTER_BUILD_NUMBER)` → `--build-number` → pubspec `build_number` |
| iOS `CURRENT_PROJECT_VERSION` | `$(FLUTTER_BUILD_NUMBER)` |

### Rules

1. `build_name` is `MAJOR.MINOR.PATCH`, three numeric components only.
2. `build_number` is a positive integer and **strictly increases on every build
   submitted to either store**. Both stores permanently reject a re-used build
   number, so a rejected submission still consumes its number.
3. Android and iOS always ship the same `build_name` and `build_number` for a
   given release. Platform-specific version drift is a preflight failure.
4. Never hardcode `versionName`/`versionCode` in `android/app/build.gradle.kts`,
   and never hardcode `MARKETING_VERSION` or a literal `CURRENT_PROJECT_VERSION`
   on the Runner target — `scripts/release_preflight.sh` fails the build if you
   do.
5. Bump the version in `pubspec.yaml` on the branch that will be promoted, in
   the same change that adds `docs/release_notes/<build_name>.md`.

The current convention keeps `build_number` equal to the patch-series counter
(`0.0.30+30`). That is a convention, not a requirement — the requirement is
strict monotonicity.

---

## 3. Release preflight

`scripts/release_preflight.sh` runs **before** any expensive signing/build job
and fails fast, naming the exact item that is missing or inconsistent.

```bash
# Everything checkable from the repository alone
scripts/release_preflight.sh check

# What CI runs for a platform release
scripts/release_preflight.sh check --platform ios --require-secrets \
  --allow-ref-name stage --allow-ref-name main

# Prove the checks themselves still work (both directions)
scripts/release_preflight.sh selftest
```

It validates:

- pubspec version format, and that a build number was derived
- Android application ID, namespace, display label, and that release signing
  fails closed when signing inputs are absent
- iOS bundle identifier, display name, development team, and that all app build
  configurations take their version/build number from the Flutter build
- required release tooling exists and is executable
- required release documentation exists
- release notes exist for the current `build_name`, with no `TODO`/`TBD`
  placeholder left in them
- the release is being cut from an allowed branch, when `--allow-ref-name` is
  given
- **presence** of the platform's signing secrets, when `--require-secrets` is
  given

Preflight reports only secret **names**. It never reads, prints, exports or logs
a secret value; `selftest` includes an explicit no-leak assertion.

`--skip-release-notes` exists for rehearsal/dry-run builds only. Never use it for
a build that will be uploaded to a store.

---

## 4. Release path: `dev` → `stage` → `main`

```
feature branch ──PR──▶ dev ──PR──▶ stage ──PR──▶ main
                       │            │             │
                    Flutter CI   release        signed release
                    (required)   qualification  build + submission
```

| Branch | Purpose | Gate |
| --- | --- | --- |
| `dev` | Day-to-day integration | Flutter CI required: `Format, Analyze & Test` + `Android debug build` |
| `stage` | Release candidate assembly and qualification | Flutter CI (including the gated release smoke build and permission inspection on push) |
| `main` | Released production state | Flutter CI, plus the signed release builds are cut from here |

Branch protection for all three branches must require both Flutter CI job names
(`Format, Analyze & Test`, `Android debug build`) — see the administrator note at
the top of `.github/workflows/flutter-ci.yml`.

### Required gates before promoting `stage` → `main`

1. **CI** — Flutter CI green on `stage` (format, analyze, tests, Android debug
   build, gated release smoke build, permission inspection).
2. **Automated tests** — `flutter test` green; the signed build workflows re-run
   the suite before they build, so a red suite cannot produce an artifact.
3. **Version bump** — `pubspec.yaml` bumped, `docs/release_notes/<version>.md`
   written.
4. **Preflight** — `scripts/release_preflight.sh check` green locally.
5. **Device qualification** — the release candidate installed and exercised on at
   least one physical Android device and one physical iOS device. Record device
   model, OS version, build number and outcome in the release notes or the
   release issue. `docs/CALENDAR_REMINDER_DEVICE_TEST.md` covers the
   notification/reminder path, which cannot be validated in CI.
6. **Regression evidence** — the outcome of the regression pass
   (`scripts/calee_client_regression.py` and/or the CaleeMobile-Regression
   selector-contract run) recorded against the candidate build number.
7. **Release notes** — customer-facing "What's New" text agreed; this is the same
   text submitted to both stores.
8. **Approval** — the **Release Approver** records explicit approval to release
   the specific `build_name+build_number` on the release issue or PR. No
   approval, no submission.
9. **Signed artifacts** — produced by the workflows in section 5, with the
   release manifest attached.
10. **Store submission** — sections 6 (Android) and 7 (Apple), after
    `STORE_RELEASE_CHECKLIST.md` is complete.

Emergency/corrective releases follow the same path. The path is never bypassed;
only the calendar is compressed.

---

## 5. Producing signed artifacts

Both signed-build workflows are `workflow_dispatch` only — nothing is built or
signed automatically on a push, and neither workflow uploads to a store.

### Android — `.github/workflows/build-signed-apk.yml`

Actions → **Build Signed Android Artifacts** → Run workflow → select `main`
(or `stage` for a qualification build).

The workflow: runs preflight → installs the pinned NDK → runs the test suite →
validates the signing secrets are present → decodes and verifies the keystore →
derives the version → builds an obfuscated signed APK and AAB → verifies both
signatures → **inspects the final artifacts' permissions and fails the release if
a prohibited storage/media permission has merged back in** → generates the
release manifest → uploads artifacts, symbols and manifest → deletes the
keystore (`if: always()`).

Artifacts: signed APK, signed AAB (this is what Play receives), native debug
symbols, Dart obfuscation symbols, release manifest.

### iOS — `.github/workflows/build-signed-ios.yml`

Actions → **Build Signed iOS Artifacts** → Run workflow → select `main`.

The workflow: runs preflight with `--require-secrets` → runs the test suite →
creates a **temporary, job-scoped keychain** → imports the Apple Distribution
`.p12` → installs the provisioning profile → resolves the profile's UUID/name and
the signing identity → writes `ExportOptions.plist` (from
`IOS_EXPORT_OPTIONS_PLIST_BASE64` if supplied, otherwise generated from
repository-controlled non-secret values) → `flutter build ipa` with manual
signing → **verifies the exported IPA is actually signed by the expected team**
→ generates the release manifest → uploads the IPA, archive and manifest →
deletes the keychain, profile and all signing material (`if: always()`).

If the Apple signing secrets are absent, the job fails at preflight in under a
minute with the exact missing secret names, before any macOS build time is spent.

### Uploading to the stores

Upload is deliberately **manual**. Neither workflow holds store-publishing
credentials, so no CI run can publish a build by accident.

- Android: download the AAB artifact → Play Console → Internal testing → upload.
- Apple: download the IPA artifact → Transporter (or `xcrun altool`/Xcode
  Organizer) → App Store Connect → TestFlight.

---

## 6. Google Play release operations

### 6.1 Track structure

| Track | Use |
| --- | --- |
| Internal testing | Every release candidate. Fast, no review wait. |
| Closed testing | Optional; use when a change needs a wider pre-production audience. Not used by default. |
| Open testing | Not used by default. |
| Production | Staged rollout only — never a first-stop track. |

### 6.2 Standard production release

1. Upload the signed AAB to **Internal testing**; confirm the version code and
   name shown by Play match the release manifest.
2. Install from the internal track on a physical device and complete device
   qualification (section 4, gate 5).
3. Complete `STORE_RELEASE_CHECKLIST.md` (Google column).
4. Promote to **Production** with a staged rollout, starting at **10%**.
5. Monitor (section 6.3) for at least 24 hours at 10%.
6. Increase to **50%**; monitor for at least 24 hours.
7. Increase to **100%**.

Faster progression is a **Release Approver** decision, recorded on the release
issue.

### 6.3 Monitoring during rollout

Watch, in Play Console:

- Android vitals: crash rate and ANR rate versus the previous release
- Pre-launch report findings
- Reviews and ratings trend for the new version
- Policy/compliance messages ("changes in review", warnings)

Halt criteria: a crash or ANR rate materially above the previous release, a
functional regression reported against the new version, or any data-safety /
policy warning raised against the release.

### 6.4 Halting a rollout

Play Console → Production → the in-progress release → **Halt rollout**. This
stops further distribution immediately. Users who already received the build keep
it — **there is no un-install and no true rollback on Google Play.**

### 6.5 Replacement / emergency corrective release

Because a released build cannot be withdrawn from users who already have it, the
only real remedy is a fix-forward release:

1. Halt the rollout (6.4).
2. Fix on a branch off `main`; get it through `dev` → `stage` → `main`.
3. Bump `pubspec.yaml` to a new, higher `build_number` (the broken number is
   permanently consumed).
4. Cut a new signed AAB, qualify it on a device, and release it to Production at
   a staged rollout again, starting at 10% unless the Release Approver directs a
   faster ramp for a severe defect.
5. Record on the release issue what shipped, what broke, and what the corrective
   build changed.

Halting alone is not a fix; a corrective release is always required.

---

## 7. Apple App Store release operations

### 7.1 Standard release

1. Produce a signed IPA (section 5).
2. Upload to App Store Connect; wait for processing to complete.
3. Distribute the build to **TestFlight** internal testers.
4. Install from TestFlight on a physical iOS device and complete device
   qualification (section 4, gate 5).
5. Complete `STORE_RELEASE_CHECKLIST.md` (Apple column), including App Privacy,
   export-compliance and review notes.
6. Attach the build to the App Store version and **Submit for Review**.
7. On approval, release using **phased release** (7 days, automatic daily
   increments) rather than immediate full release.

### 7.2 App Review

Typical turnaround is hours to a couple of days. If rejected, read the Resolution
Center message, fix or reply, and resubmit — a new binary needs a new
`build_number`, a metadata-only fix does not.

### 7.3 Phased release control

App Store Connect → the released version → Phased Release:

- **Pause phased release** — stops further automatic expansion; already-updated
  users keep the build.
- **Resume** — continues the schedule.
- **Release to all users** — ends the phasing early.

Pause criteria mirror Android's halt criteria: crash-rate regression in Xcode
Organizer, a functional regression reported against the new version, or a
data/privacy issue.

### 7.4 Removing a release / emergency corrective release

Apple's "Remove from sale" removes the app from the store for **new** downloads;
it does not remove the app from devices that already updated. As on Android, the
remedy is fix-forward:

1. Pause the phased release (7.3).
2. Fix on a branch off `main`; promote through `dev` → `stage` → `main`.
3. Bump `pubspec.yaml` to a new, higher `build_number`.
4. Cut a new signed IPA, qualify via TestFlight on a device, and submit. For a
   severe user-facing defect, request an **expedited review** in App Store
   Connect and state the user impact.
5. Record the incident and the corrective build on the release issue.

---

## 8. Artifact traceability

`scripts/generate_release_manifest.sh` writes a JSON manifest that is uploaded
alongside every signed build:

```json
{
  "schema": "calee-mobile-release-manifest/1",
  "app": { "display_name": "Calee", "android_application_id": "au.com.calee.mobile", "ios_bundle_id": "au.com.calee.mobile" },
  "platform": "android",
  "version": { "build_name": "0.0.30", "build_number": "30" },
  "source": { "repository": "CaleeAdmin/CaleeMobile", "git_sha": "...", "git_ref": "main" },
  "ci": { "workflow": "...", "run_id": "...", "run_attempt": "1", "run_url": "https://github.com/..." },
  "artifacts": [ { "name": "calee-mobile-0.0.30.aab", "size_bytes": 0, "sha256": "..." } ],
  "signing_identity": "non-secret identity summary"
}
```

To trace a store build back to source: take the version/build number shown in the
store, find the release manifest with that version, and read its `git_sha` and
`run_url`. The `sha256` of each artifact lets you prove that the file you hold is
the file CI produced.

`signing_identity` carries **non-secret** identity information only — a
certificate common name, a certificate fingerprint, a provisioning profile name.
Never place a password, private key or credential file content in it.

---

## 9. Release evidence to retain

For every production release, the release issue/PR should end up carrying:

- the `build_name+build_number` released
- the Git SHA on `main`
- the GitHub Actions run URL for each signed build
- the release manifest (or its checksums)
- device qualification results (model, OS version, outcome)
- regression evidence
- the completed store checklist
- the Release Approver's explicit approval
- Play rollout percentages/dates, and the App Store phased-release start date

---

## 10. Out of scope for this document

The following are real, known items that are **not** part of release operations
and must be tracked as their own product work, not folded into a release:

- Google Play's requirement to raise the Android target API level by
  **31 August 2026** (the app currently sets `targetSdk = 35`).
- Google Play's report that two deep links may fail because the associated web
  domains are not correctly associated with the app
  (`hub.calee.com.au`, `calembed.calee.com.au` — Digital Asset Links /
  Associated Domains configuration).

Both are hosting/product changes with their own testing needs. Raise or use a
dedicated issue for each; do not attempt them as part of a release cut.

---

## 11. Build success is not store readiness

A green signed-build workflow means exactly this: the code compiled, was signed
with the configured identity, passed the automated test suite, and passed the
Android permission gate.

It does **not** mean:

- store metadata (descriptions, screenshots, privacy disclosures) is complete or
  current
- review requirements (App Privacy, Data Safety, export compliance, review notes,
  test accounts) are satisfied
- the store has approved anything
- any rollout has started
- the release is healthy in production

Store readiness is established only by completing
`STORE_RELEASE_CHECKLIST.md`, obtaining Release Approver sign-off, and observing
the monitoring windows in sections 6 and 7.
