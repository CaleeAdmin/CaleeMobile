# Calee Mobile — Store Release Checklist

Reusable per-release checklist. Copy this file's checklists into the release
issue for each release and tick items there — do not tick them in this file,
which is the template.

Release being checked:

- Version (`build_name+build_number`): ______________
- Git SHA on `main`: ______________
- Android signed-build run URL: ______________
- iOS signed-build run URL: ______________
- Release Operator: ______________
- Release Approver: ______________

> Completing this checklist is what establishes **store readiness**. A green
> build workflow does not. See section 11 of
> [`RELEASE_OPERATIONS.md`](RELEASE_OPERATIONS.md).
>
> **Record the outcome in `docs/release_evidence/<version>.json`.** This
> checklist is the instructions; that file is the machine-checkable attestation
> that a named operator completed them for this specific build. Copy
> `docs/release_evidence/TEMPLATE.json` to start.
>
> It is completed in **two passes**, matching the sections below:
>
> ```bash
> # Pass 1 — before dispatching a signed build (sections 1a, 2, 3, 4)
> scripts/release_preflight.sh check --require-build-readiness
>
> # Pass 2 — after the candidate is qualified on a device (sections 1b, 5)
> scripts/release_preflight.sh check --platform ios --require-store-readiness
> ```
>
> The signed workflows refuse to build without pass 1, and the documented
> process forbids submitting without pass 2.

---

## 1a. Before the signed build (build readiness)

Nothing here depends on the candidate existing.

- [ ] `pubspec.yaml` version bumped; `build_number` is higher than every number
      previously submitted to either store
- [ ] `docs/release_notes/<build_name>.md` written, no `TODO`/`TBD` left
- [ ] `scripts/release_preflight.sh check` passes
- [ ] Flutter CI green on the branch being released
- [ ] Sections 2, 3 and 4 below worked through (listing text, privacy
      disclosures, age rating, review notes prepared)
- [ ] `docs/release_evidence/<version>.json` created from the template, with the
      **`build_readiness`** section completed and committed — Release Operator
      and Credential Owner named, Apple expiry dates recorded
- [ ] `scripts/release_preflight.sh check --require-build-readiness` passes

## 1b. After the signed candidate exists (submission readiness)

Every item here is about the specific candidate that was built.

- [ ] Signed Android build workflow green from `stage`/`main`; AAB, APK, symbols
      and release manifest downloaded
- [ ] Signed iOS build workflow green from `stage`/`main`; IPA and release
      manifest downloaded
- [ ] Release manifest `git_sha` matches the SHA being released
- [ ] Candidate uploaded to Google Play **Internal testing**
- [ ] Candidate uploaded and processed in App Store Connect, distributed to
      **TestFlight**
- [ ] Candidate installed from the internal track and qualified on a physical
      Android device (model/OS/build number/outcome recorded)
- [ ] Candidate installed from TestFlight and qualified on a physical iOS device
      (model/OS/build number/outcome recorded)
- [ ] Screenshots and listing text re-checked **against this candidate**
- [ ] Reviewer test account verified **on this candidate**
- [ ] Regression evidence recorded against this build number
- [ ] Release Approver has explicitly approved this `build_name+build_number`
- [ ] **`submission_readiness`** section of the evidence completed and committed
- [ ] `scripts/release_preflight.sh check --platform <android|ios> --require-store-readiness`
      passes

---

## 2. Store listing content (both stores)

Review every item against **current product behaviour**, not against what the
listing said last release.

- [ ] **App name** — `Calee`
- [ ] **Subtitle / short description** — Apple subtitle (30 chars) and Play short
      description (80 chars) still accurate
- [ ] **Full description** — describes features that actually exist in this
      build; nothing described that was removed or not yet shipped
- [ ] **Screenshots** — regenerated if the UI changed; required device sizes
      present for each store; no placeholder or debug content; no real personal
      data visible
- [ ] **App icon** — current, correct at all required sizes
- [ ] **Feature graphic** (Play) — present and current
- [ ] **Keywords** (Apple) — reviewed
- [ ] **Category** — Productivity
- [ ] **Support URL** — reachable, and a real support route
- [ ] **Marketing URL** (optional) — reachable if set
- [ ] **Privacy policy URL** — reachable, current, and describes what this
      version actually collects
- [ ] **Contact information** — support email/phone monitored by someone
- [ ] **Localisation** — English (Australia) primary; any additional locales
      complete, not partially translated
- [ ] **Release notes / What's New** — customer-facing text agreed, identical in
      intent across both stores

---

## 3. Privacy and data disclosures

Both stores require these to match the app's real behaviour. Calee handles
calendar, task, people/profile, photo and document-attachment data, and uses the
camera for QR/event scanning.

### Apple — App Privacy

- [ ] Data collection answers reviewed against this build's actual behaviour
- [ ] Every data type collected declared, with purpose and linkage/tracking
      answers
- [ ] Third-party SDK data behaviour accounted for
- [ ] Privacy policy URL matches the one in the listing

### Google Play — Data Safety

- [ ] Data collected / shared answers reviewed against this build
- [ ] Encryption-in-transit and deletion-request answers current
- [ ] Declaration matches the Apple App Privacy answers (they describe the same
      app)

### Permissions

- [ ] Every requested Android permission still justified
      (`INTERNET`, `CAMERA`, `POST_NOTIFICATIONS`, `RECEIVE_BOOT_COMPLETED`)
- [ ] No broad storage/media permission has merged back in — the signed-build
      permission gate passed on the final AAB
- [ ] iOS usage strings (`NSCameraUsageDescription`,
      `NSPhotoLibraryUsageDescription`) accurately describe how this build uses
      the camera and photo library

---

## 4. Ratings, compliance and review information

- [ ] **Age / content rating** — Apple 4+; Play content rating questionnaire
      re-answered if functionality changed
- [ ] **Export compliance (Apple)** — the encryption question answered for this
      build. Calee uses HTTPS and platform-provided cryptography; confirm the
      current answer is still correct and that any required exemption
      declaration is in place
- [ ] **Review notes** — explain anything a reviewer cannot discover alone
      (account model, how to reach the calendar/tasks features, deep-link
      behaviour)
- [ ] **Demo / test account** — Calee requires an account, so a working test
      account **must** be supplied to Apple App Review and to Play if requested.
      Verify the credentials work on the submitted build before submitting
- [ ] **Deep links** — if the listing or review notes reference
      `hub.calee.com.au` / `calembed.calee.com.au` links, confirm they resolve
- [ ] **Sign-in / account deletion** — Play requires an in-app or documented
      account-deletion route where accounts exist; confirm the declared route
      is accurate
- [ ] **Advertising ID** (Play) — declared correctly (Calee does not use one
      unless a dependency introduces it)

---

## 5. Submission

### Google Play

- [ ] AAB uploaded to **Internal testing**; version code/name match the manifest
- [ ] Installed from the internal track and smoke-tested
- [ ] Release notes entered
- [ ] Promoted to **Production** at **10%** staged rollout
- [ ] Rollout percentage, date and time recorded on the release issue

### Apple App Store

- [ ] IPA uploaded; processing completed in App Store Connect
- [ ] Build distributed to **TestFlight** and smoke-tested from TestFlight
- [ ] Build attached to the App Store version
- [ ] "What's New" entered
- [ ] Export compliance answered
- [ ] **Phased release** selected (not immediate full release)
- [ ] Submitted for review; submission date recorded on the release issue

---

## 6. Post-submission monitoring

- [ ] Play: Android vitals (crash/ANR) watched at 10% for at least 24h before
      increasing to 50%
- [ ] Play: watched at 50% for at least 24h before increasing to 100%
- [ ] Apple: App Review outcome recorded; on approval, phased release started
- [ ] Apple: crash rate in Xcode Organizer watched during phased release
- [ ] Reviews/ratings watched for regression reports on both stores
- [ ] Halt/pause criteria from `RELEASE_OPERATIONS.md` sections 6.3 and 7.3
      understood by whoever is on watch

---

## 7. Release closure

- [ ] Rollout reached 100% (Play) and full release (Apple)
- [ ] Release evidence attached to the release issue (see
      `RELEASE_OPERATIONS.md` section 9)
- [ ] Any incident, halt or corrective release documented
- [ ] Credential expiry dates in `RELEASE_CREDENTIALS.md` still in the future;
      renewal reminders set if within 30 days
- [ ] `docs/release_evidence/<version>.json` reflects what actually happened
      (amend it if the release deviated from plan)
