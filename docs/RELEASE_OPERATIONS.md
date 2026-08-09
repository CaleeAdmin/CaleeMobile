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
| App Store Connect (listing, submissions) | Credential Owner — Apple | `REQUIRED — NOT SUPPLIED` |
| Apple Developer signing assets | Credential Owner — Apple | `REQUIRED — NOT SUPPLIED` |
| Google Play Console (listing, releases) | Credential Owner — Google | `REQUIRED — NOT SUPPLIED` |
| Android signing credentials | Credential Owner — Android | `REQUIRED — NOT SUPPLIED` |
| Approving a production release | Release Approver | `REQUIRED — NOT SUPPLIED` |
| Executing a release | Release Operator | `REQUIRED — NOT SUPPLIED` |

The named individuals are not recorded anywhere in this repository and were not
available when this document was written. Fill the table in before the next
production release; the roles themselves are used throughout this document and
do not change.

This is not merely an unfilled table. The per-release evidence file (section
3.1) requires the Release Operator to name the approver, the operator and the
relevant credential owner for the specific build being released, and rejects
placeholder text — so a production-signed build cannot be produced while these
are unanswered. See `docs/RELEASE_CREDENTIALS.md` section 1.

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

It has **three deliberately separate levels**, because "the repository is
consistent", "a signed candidate may be built" and "this candidate may be
submitted to a store" are different claims made at different times:

| Level | Invocation | Who runs it | What it proves |
| --- | --- | --- | --- |
| Repository correctness | `check` | Flutter CI, every PR | The repository is internally consistent: identity, version wiring, tooling, docs, release notes. **Not** release approval. |
| Build/sign readiness | `check --require-secrets --require-build-readiness --allow-branch stage --allow-branch main` | The signed release workflows | Additionally: an authorised release **branch**, signing secrets configured, and the `build_readiness` evidence completed by a named operator. Everything knowable *before* the candidate exists. |
| Store submission readiness | `check --require-store-readiness` | The Release Operator, after qualifying the candidate | Everything above **plus** `submission_readiness`: physical-device qualification of this exact build, final listing/screenshot review against the candidate, Release Approver sign-off. |

Build readiness deliberately does **not** require device qualification. The
artifact to be qualified is the one the signed workflow is about to produce, so
requiring it earlier would be circular. Qualification is not dropped — it is
moved to the phase where it can honestly be performed.

```bash
# Repository correctness — safe anywhere, needs no secrets
scripts/release_preflight.sh check

# Exactly what the signed Android workflow runs before building
scripts/release_preflight.sh check --platform android \
  --require-secrets --require-build-readiness \
  --allow-branch stage --allow-branch main

# What the operator runs AFTER qualifying the candidate, before uploading
scripts/release_preflight.sh check --platform ios --require-store-readiness

# Prove the checks themselves still work (both directions)
scripts/release_preflight.sh selftest            # 119 cases
scripts/generate_release_manifest.sh selftest    # 17 cases
scripts/verify_release_ref.sh selftest           # 24 cases
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
- that the run is on an authorised release **branch** (never a tag), when
  `--allow-branch` is given
- **presence** of the platform's signing secrets, when `--require-secrets` is
  given
- the readiness evidence for the phase being checked (section 3.1)

Preflight reports only secret **names**. It never reads, prints, exports or logs
a secret value; `selftest` includes an explicit no-leak assertion.

`--skip-release-notes` exists for rehearsal/dry-run builds only. Never use it for
a build that will be uploaded to a store.

### 3.1 Release readiness evidence

`STORE_RELEASE_CHECKLIST.md` says what to do. **`docs/release_evidence/<version>.json`
is where the Release Operator records that it was actually done**, for one
specific build, in a form the release tooling verifies. A checklist file existing
in the repository proves nothing; this file is the attestation.

It has two sections, completed at two different times:

| Section | Completed | Required by |
| --- | --- | --- |
| `build_readiness` | Before dispatching a signed release workflow | `--require-build-readiness` — the signed workflows |
| `submission_readiness` | After the candidate is on Internal Testing / TestFlight and has been qualified on a physical device | `--require-store-readiness` — the operator, before uploading for review |

```bash
cp docs/release_evidence/TEMPLATE.json docs/release_evidence/0.0.31.json
# fill in build_readiness, then:
scripts/release_preflight.sh check --require-build-readiness
# ... signed workflow ... qualify the candidate on a device ...
# fill in submission_readiness, then:
scripts/release_preflight.sh check --platform ios --require-store-readiness
```

A release **fails** if the file is missing, if its `version`/`build_number` do
not match the build (so last release's file cannot be reused), if any required
item is `false`, missing or placeholder text, if the operator / credential-owner
/ approver fields are empty or still hold a template `REPLACE …` marker, if
device qualification is missing, failed, or was recorded against a different
build number, if the tested candidate is not identified exactly (section 3.2),
or if the recorded Apple certificate/profile expiry has lapsed.

Copying `TEMPLATE.json` and editing only the version cannot pass — every
`REPLACE …` marker is rejected, and that is an explicit test case.

### 3.2 "Same build number" is not "same signed candidate"

The build number lives in `pubspec.yaml`, so **two signed workflow runs built
from two different commits can carry the same build number.** Recording device
qualification against a build number alone would therefore permit testing one
candidate and submitting another, with nothing to detect it.

`submission_readiness` records the **exact candidate** each platform tested:

```json
"android_candidate": {
  "git_sha": "<40-char commit the workflow built>",
  "workflow_run_id": "<GitHub Actions run id>",
  "workflow_run_attempt": "<run attempt>",
  "release_manifest_sha256": "<SHA-256 of that run's release manifest>",
  "device_qualification": { "device": "...", "os_version": "...", "build_number": "...", "outcome": "pass" }
}
```

The qualification is **nested inside** the candidate, so it cannot be detached
from the artifact it describes. Android and iOS are separate blocks — they come
from different workflows and different runs — and preflight requires them to
share a commit while refusing a shared run id or manifest digest (which would
mean one was copied from the other).

**Where the values come from.** The signed workflow prints them in its
*"Print candidate identity for release evidence"* step, and the same block can be
regenerated at any time from the downloaded manifest:

```bash
scripts/generate_release_manifest.sh checksum <release-manifest.json>
```

To prove the recorded identity really describes the manifest you hold:

```bash
scripts/release_preflight.sh check --platform android --require-store-readiness \
  --candidate-manifest android=<release-manifest.json>
```

This compares the digest and the manifest's commit, run id, version and build
number against the evidence. It is entirely local — preflight never downloads a
GitHub artifact.

Full field reference: [`docs/release_evidence/README.md`](release_evidence/README.md).

Commit the evidence on the branch being released so it reaches `stage`/`main`
with the code it describes.

> There is intentionally **no** evidence file for the current version in the
> repository today. Nobody has performed those reviews, so a signed release
> attempt fails closed — which is the correct state, not a gap.

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

### Only `stage` and `main` may produce production-signed artifacts

Both signed-build workflows are manually dispatchable, so the branch restriction
is **enforced in the workflow, not merely documented**, in two independent
places:

1. A `Verify release ref` job runs first and fails the whole run unless the
   **fully-qualified** ref is `refs/heads/stage` or `refs/heads/main` *and* the
   ref type is `branch`. It runs `scripts/verify_release_ref.sh`, which has its
   own 24-case selftest.
2. The preflight job independently applies the same rule through a separate
   implementation (`--allow-branch stage --allow-branch main`), so removing or
   misconfiguring the guard job does not silently re-open the hole.

**A tag is never an authorised release ref.** `workflow_dispatch` can target a
branch *or* a tag, and `GITHUB_REF_NAME` is the short name for both — so a tag
named `main` would otherwise be indistinguishable from the `main` branch. Both
layers check `GITHUB_REF` and `GITHUB_REF_TYPE`, reject a ref/type
contradiction rather than resolving it, and fail closed when `GITHUB_REF` is
absent. The error names the supplied ref, its type, and the allowed refs:

```
Reason      : the release ref is a tag, not a branch
Current ref : refs/tags/main
Ref type    : tag

Production-signed artifacts may only be built from:
  refs/heads/stage  (branch)
  refs/heads/main   (branch)
```

Dispatching either signed workflow from `dev`, a feature branch or a `claude/*`
branch therefore fails in seconds, before any signing material is decoded. There
is no override. If you need a signed build of work in progress, promote it to
`stage` first — that is what `stage` is for.

What each level actually gates:

| Level | What passing it means | What it does **not** mean |
| --- | --- | --- |
| PR CI green on `dev` | The change is internally consistent and testable | Not release approval; nothing has been qualified on a device |
| Promotion to `stage` | The change is in a release candidate | Not approved for production |
| Build readiness complete | A named operator attests listing/privacy/review preparation is done and credentials are valid | Not permission to submit; the candidate does not exist yet |
| Signed build green on `stage`/`main` | Artifacts compiled, signed, verified, traceable | **Not** store readiness — the candidate has not been run on a device |
| Submission readiness complete | The same operator attests this exact candidate was qualified on a physical device, the listing/screenshots were re-checked against it, and the Release Approver signed off | **Not** store approval — neither store has seen it |
| Submitted and approved | The store accepted the build | **Not** rollout completion — users do not have it yet |
| Rollout at 100% / phased release complete | Distribution finished | Not "healthy" — monitoring continues (sections 6.3, 7.3) |

### Required gates before promoting `stage` → `main`

1. **CI** — Flutter CI green on `stage` (format, analyze, tests, Android debug
   build, gated release smoke build, permission inspection).
2. **Automated tests** — `flutter test` green; the signed build workflows re-run
   the suite before they build, so a red suite cannot produce an artifact.
3. **Version bump** — `pubspec.yaml` bumped, `docs/release_notes/<version>.md`
   written.
4. **Preflight** — `scripts/release_preflight.sh check` green locally.
5. **Release notes** — customer-facing "What's New" text agreed; this is the same
   text submitted to both stores.
6. **Build readiness evidence** — the `build_readiness` section of
   `docs/release_evidence/<version>.json` completed and committed (section 3.1),
   naming the Release Operator and Credential Owner. The signed workflows refuse
   to build without it, so this is a hard gate, not a reminder.
7. **Signed candidate** — produced by the workflows in section 5, with the
   release manifest attached. These may only be built from the `stage` or `main`
   **branch**.
8. **Candidate distribution** — the signed candidate uploaded to Google Play
   Internal Testing and/or TestFlight. This is the first point at which the
   build can be installed.
9. **Device qualification** — the candidate installed *from that track* and
   exercised on at least one physical Android device and one physical iOS
   device. Record device model, OS version, build number and outcome **inside
   the candidate block** that identifies the exact artifact tested (section
   3.2).
   `docs/CALENDAR_REMINDER_DEVICE_TEST.md` covers the notification/reminder
   path, which cannot be validated in CI.
10. **Regression evidence** — the outcome of the regression pass
    (`scripts/calee_client_regression.py` and/or the CaleeMobile-Regression
    selector-contract run) recorded against the candidate build number.
11. **Approval** — the **Release Approver** records explicit approval to release
    the specific `build_name+build_number`. No approval, no submission.
12. **Submission readiness evidence** — the `submission_readiness` section
    completed, then verified with
    `scripts/release_preflight.sh check --platform <platform> --require-store-readiness`.
13. **Store submission** — sections 6 (Android) and 7 (Apple), after
    `STORE_RELEASE_CHECKLIST.md` is complete.

Emergency/corrective releases follow the same path. The path is never bypassed;
only the calendar is compressed.

---

## 5. Producing signed artifacts

Both signed-build workflows are `workflow_dispatch` only — nothing is built or
signed automatically on a push, and neither workflow uploads to a store. Both
refuse to run from any ref other than `stage` or `main` (section 4).

Every signed run performs the same ordered sequence:

1. prove the run is on an authorised release **branch** (never a tag)
2. run the release-tooling selftests
3. run repository-correctness preflight
4. require the platform's signing secrets to be configured
5. require completed **build readiness** evidence for this exact version
6. derive the version from `pubspec.yaml` and run the test suite
7. build and sign the candidate
8. cryptographically verify the candidate
9. generate the complete release manifest
10. upload the candidate, its artifacts and the manifest
11. destroy all signing material, even when an earlier step failed
12. print the exact remaining sequence — distribute, qualify on a device,
    complete submission readiness — before any store upload

The workflow does **not** validate submission readiness, because the candidate
it is about to build is the thing that must be qualified. A green run therefore
states plainly: *signed candidate produced; store submission is still blocked
until submission-readiness validation passes.*

### Android — `.github/workflows/build-signed-apk.yml`

Actions → **Build Signed Android Artifacts** → Run workflow → select `main`
(or `stage` for a qualification build).

The workflow: verifies the release ref → runs preflight (selftests, repository
correctness, secret presence, store-readiness evidence) → installs the pinned NDK
→ runs the test suite →
validates the signing secrets are present → decodes and verifies the keystore →
derives the version → builds an obfuscated signed APK and AAB → verifies both
signatures → **inspects the final artifacts' permissions and fails the release if
a prohibited storage/media permission has merged back in** → generates the
release manifest → uploads artifacts, symbols and manifest → deletes the
keystore (`if: always()`).

Artifacts: signed APK, signed AAB (this is what Play receives), native debug
symbols, Dart obfuscation symbols, release manifest. **All four artifacts are
recorded in the manifest**, not just the store binary.

### iOS — `.github/workflows/build-signed-ios.yml`

Actions → **Build Signed iOS Artifacts** → Run workflow → select `main`.

The workflow: verifies the release ref → runs preflight with `--require-secrets`
and `--require-store-readiness` → runs the test suite →
creates a **temporary, job-scoped keychain** → imports the Apple Distribution
`.p12` → installs the provisioning profile → resolves the profile's UUID/name and
the signing identity → writes `ExportOptions.plist` (from
`IOS_EXPORT_OPTIONS_PLIST_BASE64` if supplied, otherwise generated from
repository-controlled non-secret values) → `flutter build ipa` with manual
signing → **verifies the exported IPA is actually signed by the expected team**
→ generates the release manifest covering both the IPA and the xcarchive (which
carries the dSYMs) → uploads the IPA, archive and manifest → deletes the
keychain, profile and all signing material (`if: always()`).

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

The full Android sequence, in order. Do not reorder it — each step produces what
the next one needs.

```
signed AAB (stage/main) + release manifest
  → record the EXACT candidate identity (commit, run id/attempt, manifest digest)
    → Play Internal Testing
      → install THAT candidate on a physical device
        → device qualification, recorded inside the candidate block
          → submission_readiness evidence completed
            → --require-store-readiness passes
              → Production 10% → 50% → 100%
                → monitoring
```

1. **Build readiness** — complete `build_readiness` in
   `docs/release_evidence/<version>.json` and verify it:
   `scripts/release_preflight.sh check --platform android --require-build-readiness`
2. **Signed candidate** — dispatch **Build Signed Android Artifacts** from the
   `stage` or `main` branch. Download the AAB, APK, symbols and release
   manifest.
2a. **Record the candidate identity** — copy the block printed by the run's
   *"Print candidate identity for release evidence"* step, or regenerate it with
   `scripts/generate_release_manifest.sh checksum <release-manifest.json>`. This
   is what ties everything below to *this* candidate; the build number cannot
   (section 3.2).
3. **Internal testing** — upload the signed AAB to **Internal testing**; confirm
   the version code and name Play shows match the release manifest.
4. **Install the candidate** — install it *from the internal track* on a
   physical Android device. This is the first point at which the build can be
   exercised.
5. **Device qualification** — work through the app's real paths, including the
   notification/reminder path in `docs/CALENDAR_REMINDER_DEVICE_TEST.md`. Record
   device, OS version, build number and outcome.
6. **Submission readiness** — complete the `submission_readiness` section: paste
   the `android_candidate` identity from step 2a, nest the qualification record
   inside it, and record the final listing/screenshot review against this
   candidate, the reviewer test account verified on it, and the Release
   Approver. Work the Google column of `STORE_RELEASE_CHECKLIST.md`. Verify:
   `scripts/release_preflight.sh check --platform android --require-store-readiness`
   (add `--candidate-manifest android=<release-manifest.json>` to also prove the
   evidence describes the manifest you downloaded).
7. **Production, staged** — only once step 6 passes, promote to **Production**
   with a staged rollout starting at **10%**.
8. Monitor (section 6.3) for at least 24 hours at 10%.
9. Increase to **50%**; monitor for at least 24 hours.
10. Increase to **100%**.

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

The full Apple sequence, in order. TestFlight is what makes the candidate
installable, so qualification necessarily comes after it — never before.

```
signed IPA (stage/main) + release manifest
  → record the EXACT candidate identity (commit, run id/attempt, manifest digest)
    → upload to App Store Connect → processing
      → TestFlight
        → install THAT candidate on a physical device
          → device qualification, recorded inside the candidate block
            → submission_readiness evidence completed
              → --require-store-readiness passes
                → Submit for Review
                  → App Review
                    → phased release
                      → monitoring
```

1. **Build readiness** — complete `build_readiness` in
   `docs/release_evidence/<version>.json`, including the Apple certificate and
   provisioning-profile expiry dates, and verify it:
   `scripts/release_preflight.sh check --platform ios --require-build-readiness`
2. **Signed candidate** — dispatch **Build Signed iOS Artifacts** from the
   `stage` or `main` branch. Download the IPA and the release manifest.
2a. **Record the candidate identity** — copy the block printed by the run's
   *"Print candidate identity for release evidence"* step, or regenerate it with
   `scripts/generate_release_manifest.sh checksum <release-manifest.json>`. This
   is what ties everything below to *this* candidate; the build number cannot
   (section 3.2).
3. **Upload** — upload the IPA to App Store Connect (Transporter, Xcode
   Organizer or `xcrun altool`); wait for processing to complete.
4. **TestFlight** — distribute the processed build to TestFlight internal
   testers.
5. **Install the candidate** — install it *from TestFlight* on a physical iOS
   device. This is the first point at which the build can be exercised.
6. **Device qualification** — work through the app's real paths, including the
   notification/reminder path in `docs/CALENDAR_REMINDER_DEVICE_TEST.md`. Record
   device, OS version, build number and outcome.
7. **Submission readiness** — complete the `submission_readiness` section: paste
   the `ios_candidate` identity from step 2a, nest the qualification record
   inside it, and record the final listing/screenshot review against this
   candidate, the reviewer test account verified on it, export compliance and
   the Release Approver. Work the Apple column of
   `STORE_RELEASE_CHECKLIST.md`. Verify:
   `scripts/release_preflight.sh check --platform ios --require-store-readiness`
   (add `--candidate-manifest ios=<release-manifest.json>` to also prove the
   evidence describes the manifest you downloaded).
8. **Submit** — only once step 7 passes, attach the build to the App Store
   version and **Submit for Review**.
9. **Phased release** — on approval, release using **phased release** (7 days,
   automatic daily increments) rather than immediate full release.

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
  "schema": "calee-mobile-release-manifest/2",
  "app": { "display_name": "Calee", "android_application_id": "au.com.calee.mobile", "ios_bundle_id": "au.com.calee.mobile" },
  "platform": "android",
  "version": { "build_name": "0.0.30", "build_number": "30" },
  "source": { "repository": "CaleeAdmin/CaleeMobile", "git_sha": "...", "git_ref": "main" },
  "ci": { "workflow": "...", "run_id": "...", "run_attempt": "1", "run_url": "https://github.com/..." },
  "artifacts": [
    { "name": "calee-mobile-0.0.30.aab", "kind": "file", "role": "app_bundle", "size_bytes": 0, "sha256": "..." },
    { "name": "calee-mobile-0.0.30.apk", "kind": "file", "role": "apk", "size_bytes": 0, "sha256": "..." },
    { "name": "native-debug-symbols.zip", "kind": "file", "role": "native_debug_symbols", "size_bytes": 0, "sha256": "..." },
    { "name": "symbols", "kind": "directory", "role": "dart_debug_symbols", "file_count": 0, "total_size_bytes": 0, "tree_sha256": "..." }
  ],
  "signing_identity": "non-secret identity summary"
}
```

**Every artifact the workflow uploads is recorded**, not only the store binary:

| Platform | Recorded artifacts |
| --- | --- |
| Android | signed AAB, signed APK, native debug symbols zip, Dart obfuscation symbols directory |
| iOS | signed IPA, xcarchive (contains the dSYMs) |

Directory artifacts (the Dart symbols directory, the xcarchive) are recorded with
a file count, a total size, and a `tree_sha256` — a digest over every contained
file's relative path and SHA-256 — so a directory is as verifiable as a single
file. The generator **fails closed**: if any artifact passed to it is missing, or
is not the kind declared, no manifest is produced and the release run fails.


To trace a store build back to source: take the version/build number shown in the
store, find the release manifest with that version, and read its `git_sha` and
`run_url`. The `sha256` of each artifact lets you prove that the file you hold is
the file CI produced.

The link runs the other way too. `submission_readiness` in
`docs/release_evidence/<version>.json` records the SHA-256 of the manifest for
the candidate that was actually installed and qualified, so device evidence,
CI run, source commit and uploaded artifacts form one chain that a build number
alone could not (section 3.2).

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

- Google Play's Android target API level requirement. This was addressed
  separately in #538, which raised the app to `targetSdk = 36` (Android 16); the
  deadline was 31 August 2026. Nothing further is needed here, but a future
  deadline will again be its own product change, not a release-process change.
- Google Play's report that two deep links may fail because the associated web
  domains are not correctly associated with the app
  (`hub.calee.com.au`, `calembed.calee.com.au` — Digital Asset Links /
  Associated Domains configuration).

Both are hosting/product changes with their own testing needs. Raise or use a
dedicated issue for each; do not attempt them as part of a release cut.

---

## 11. Build success is not store readiness

There are four distinct milestones, and each one is routinely mistaken for the
next. They are not the same thing and never happen at the same time:

```
  PR CI green ─▶ build readiness ─▶ signed candidate ─▶ qualified on a device
   (code is       (prep done,        (artifacts exist,   (it actually works
    consistent)    operator named)    signed, traceable)   on real hardware)
                                                             │
                        ┌────────────────────────────────────┘
                        ▼
  submission readiness ─▶ store approval ─▶ rollout complete
   (approver signed off,   (Apple/Google      (users actually
    listing re-checked)     accepted it)       have it)
```

**1. PR CI success is not release approval.** Flutter CI proves the code formats,
analyses, tests and builds. It runs the release preflight at the *repository
correctness* level only — no secrets, no store-readiness evidence. It says
nothing about whether this change should be released.

**2. A successful signed build is not store readiness.** A green signed-build
workflow means exactly this: the code compiled, was signed with the configured
identity, passed the automated test suite, passed the Android permission gate,
and produced traceable artifacts — with **build readiness** validated
beforehand. It does **not** mean anyone has run the build on a device, that
screenshots match it, or that the reviewer test account works on it. Those
claims cannot honestly be made before the candidate exists, which is precisely
why they live in the submission phase.

**3. Store readiness is not store approval.** Submission readiness is
established by distributing the candidate to Internal Testing / TestFlight,
qualifying it on physical hardware, completing
`STORE_RELEASE_CHECKLIST.md`, and recording all of it in the
`submission_readiness` section of `docs/release_evidence/<version>.json` with
Release Approver sign-off. That is an internal statement. Neither Apple nor
Google has seen the build at that point, and either can still reject it.

**4. Publication is not rollout completion, and rollout completion is not
health.** An approved App Store version still has to go through phased release; a
Play production release still has to climb 10% → 50% → 100%. Until then most
users do not have the build. Even at 100%, the release is not "done" until the
monitoring windows in sections 6.3 and 7.3 have passed without triggering a halt.

The tooling enforces the boundary between 1 and 2 (separate preflight levels
plus the `build_readiness` evidence the signed workflows require), and between 2
and 3 (the `submission_readiness` evidence, which requires device qualification
against the exact candidate build number). Steps 3→4 and 4→completion are human
and store-side; no repository check can assert them.
