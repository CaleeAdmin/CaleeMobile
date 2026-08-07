# Calee Mobile — Release Credential Inventory

Inventory of the credentials required to build and publish Calee, their GitHub
Secret **names**, ownership, renewal and rotation procedures.

> **This document contains no secret values and must never contain any.**
> Only names, types, owners and procedures belong here. Keystores, `.p12`
> certificates, provisioning profiles, passwords and API keys are never
> committed to this repository — `.gitignore` already excludes `**/*.jks` and
> `**/*.keystore`, and no signing material of any kind may be added.

Related: [`RELEASE_OPERATIONS.md`](RELEASE_OPERATIONS.md),
[`STORE_RELEASE_CHECKLIST.md`](STORE_RELEASE_CHECKLIST.md).

---

## 1. Roles and operator-supplied records

> ### ⚠ OPERATOR CONFIGURATION REQUIRED — NOT YET SUPPLIED
>
> Every row marked **`REQUIRED — NOT SUPPLIED`** below is unresolved. These
> values are not knowable from the repository. Issue #513 must not be closed
> while any of them is unfilled.

| Role | Responsibility | Named holder |
| --- | --- | --- |
| **Credential Owner — Android** | Holds the upload keystore and its passwords; performs rotation | `REQUIRED — NOT SUPPLIED` |
| **Credential Owner — Apple** | Holds the Apple Developer account, distribution certificate and profiles | `REQUIRED — NOT SUPPLIED` |
| **Release Operator** | Runs the signed-build workflows and uploads to the stores | `REQUIRED — NOT SUPPLIED` |
| **Release Approver** | Authorises a production release and any rollout acceleration | `REQUIRED — NOT SUPPLIED` |

| Record | Value | Why it is needed |
| --- | --- | --- |
| Apple Distribution certificate expiry | `REQUIRED — NOT SUPPLIED` | Signing stops working the day it lapses |
| App Store provisioning profile expiry | `REQUIRED — NOT SUPPLIED` | Same, and it lapses with its certificate |
| Apple Developer Program renewal date | `REQUIRED — NOT SUPPLIED` | Membership lapse affects signing *and* the listing |
| Renewal reminder date (30 days before the earliest above) | `REQUIRED — NOT SUPPLIED` | Calendar reminder owned by Credential Owner — Apple |
| Play App Signing enabled? | `REQUIRED — NOT SUPPLIED` | Determines whether a lost upload key is recoverable (section 2) |
| Keystore backup location (vault/password-manager entry name, not the secret) | `REQUIRED — NOT SUPPLIED` | Recovery depends on it existing |

### These records are enforced, not just documented

The per-release evidence file (`docs/release_evidence/<version>.json`, see
[`RELEASE_OPERATIONS.md`](RELEASE_OPERATIONS.md) section 3.1) requires the
operator to name, for the build being released:

- `release_approver`, `release_operator`
- `credential_owner_android` (Android releases), `credential_owner_apple` (iOS)
- `apple_certificate_expiry` and `apple_provisioning_profile_expiry` (iOS),
  which **must still be in the future** or the release fails

Placeholder text such as `TODO`, `TBD`, `UNKNOWN` or `Operator decision
required` in any of those fields fails the release preflight. So a release
cannot be built while the ownership questions above are unanswered — the
answers are recorded per release rather than assumed from this table.

Keep this table current as well: it is the standing answer, the evidence file is
the per-release attestation.

---

## 2. Android signing credentials

| GitHub Secret name | Type | Purpose |
| --- | --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Single-line base64 of a Java keystore (`.jks`) | The upload key used to sign the release APK/AAB |
| `ANDROID_KEYSTORE_PASSWORD` | Password | Opens the keystore |
| `ANDROID_KEY_ALIAS` | Alias name | Selects the signing key inside the keystore |
| `ANDROID_KEY_PASSWORD` | Password | Opens the key |

Consumed by `.github/workflows/build-signed-apk.yml`, which validates presence,
decodes the keystore into `$RUNNER_TEMP`, verifies it with `keytool`, signs, and
deletes it in an `if: always()` step. Locally, the same inputs may come from
`android/key.properties` (git-ignored) or the equivalent
`ANDROID_KEYSTORE_PATH`/`..._PASSWORD`/`..._ALIAS`/`..._KEY_PASSWORD` environment
variables.

**Expiry.** Android upload/signing keys are long-lived (typically 25+ years).
Record the certificate's validity window when the key is created; check it at
each annual credential review.

**Recovery.** This is the highest-consequence credential in the project.

- If **Play App Signing** is enabled (the Play Console shows an app signing key
  managed by Google), a lost *upload* key can be replaced: request an upload key
  reset in Play Console, register the new key, and update the four secrets above.
  Existing users are unaffected.
- If Play App Signing is **not** enabled, losing the signing key means the
  existing listing can never be updated again. Confirm which of these applies and
  record it here:
  **Play App Signing status: `REQUIRED — NOT SUPPLIED` (confirm in Play Console and record it here).**

**Backup.** The Credential Owner — Android keeps an offline, encrypted backup of
the keystore and its passwords in the organisation's password manager or secure
vault, not on a developer laptop alone and never in this repository.

**Rotation.** Rotating the upload key (routinely, or immediately on suspected
exposure):

1. Generate a new keystore offline (`keytool -genkeypair -keyalg RSA -keysize
   4096 -validity 10000 ...`). Never generate it on a CI runner.
2. Register the new upload key with Google Play (Play App Signing → request
   upload key reset). Wait for Google to confirm the change is effective.
3. Base64-encode the keystore as a **single line**
   (`base64 -w0 keystore.jks` on Linux, `base64 -i keystore.jks | tr -d '\n'` on
   macOS) and update `ANDROID_KEYSTORE_BASE64` plus the three related secrets in
   GitHub → Settings → Secrets and variables → Actions.
4. Run **Build Signed Android Artifacts** on `main` and confirm the keystore
   verification and signature verification steps pass.
5. Destroy the old keystore copies once the new key is confirmed working.

The workflow rejects a multi-line or truncated `ANDROID_KEYSTORE_BASE64` with an
explicit message, so a bad paste fails loudly rather than producing an unsigned
or mis-signed build.

---

## 3. Apple signing credentials

| GitHub Secret name | Type | Purpose | Required |
| --- | --- | --- | --- |
| `IOS_CERTIFICATE_BASE64` | Base64 of an Apple Distribution certificate + private key exported as `.p12` | Signs the release build | Yes |
| `IOS_CERTIFICATE_PASSWORD` | Password | Opens the `.p12` | Yes |
| `IOS_PROVISIONING_PROFILE_BASE64` | Base64 of an App Store `.mobileprovision` for `au.com.calee.mobile` | Authorises the signing identity for the bundle id | Yes |
| `IOS_EXPORT_OPTIONS_PLIST_BASE64` | Base64 of an `ExportOptions.plist` | Overrides the generated export options | No — generated from non-secret repository values when absent |

Consumed by `.github/workflows/build-signed-ios.yml`, which imports them into a
temporary job-scoped keychain, signs, verifies the exported IPA's signing team,
and deletes every piece of signing material in an `if: always()` step.

### Creating the assets (Credential Owner — Apple)

1. **Certificate** — Apple Developer → Certificates → create an **Apple
   Distribution** certificate (or export the existing one from Keychain Access
   with its private key). Export as `.p12` with a strong password.
   Encode: `base64 -i dist.p12 | tr -d '\n'` → `IOS_CERTIFICATE_BASE64`;
   the export password → `IOS_CERTIFICATE_PASSWORD`.
2. **Provisioning profile** — Apple Developer → Profiles → create an **App
   Store** distribution profile for `au.com.calee.mobile`, tied to the
   distribution certificate above. Download the `.mobileprovision`.
   Encode: `base64 -i Calee_AppStore.mobileprovision | tr -d '\n'` →
   `IOS_PROVISIONING_PROFILE_BASE64`.
3. Add all three (four, with the optional plist) in GitHub → Settings → Secrets
   and variables → Actions → **New repository secret**, using exactly the names
   in the table.
4. Run **Build Signed iOS Artifacts** on `main` and confirm the signing
   verification step reports team `WQ3JPT4U3H`.

Do the base64 encoding on a trusted machine. Do not paste certificate or
password material into an issue, PR, chat or CI log.

### Expiry — the one that will bite

| Asset | Typical lifetime | Effect of expiry |
| --- | --- | --- |
| Apple Distribution certificate | 1 year | Signing fails; already-shipped App Store builds keep working |
| App Store provisioning profile | 1 year (and invalid immediately if its certificate is revoked/expires) | Signing fails |
| Apple Developer Program membership | 1 year | Certificates, profiles and store listing availability are all affected |

**Renewal procedure.** Roughly 30 days before the certificate or profile expiry
date, the Credential Owner — Apple creates the replacement certificate and
profile, re-encodes them, and updates `IOS_CERTIFICATE_BASE64`,
`IOS_CERTIFICATE_PASSWORD` and `IOS_PROVISIONING_PROFILE_BASE64`, then runs the
signed iOS workflow on `main` to confirm. Record the new expiry dates below.

| Asset | Expiry date | Reviewed on |
| --- | --- | --- |
| Apple Distribution certificate | `REQUIRED — NOT SUPPLIED` | `REQUIRED — NOT SUPPLIED` |
| App Store provisioning profile | `REQUIRED — NOT SUPPLIED` | `REQUIRED — NOT SUPPLIED` |
| Apple Developer Program membership | `REQUIRED — NOT SUPPLIED` | `REQUIRED — NOT SUPPLIED` |

Set a calendar reminder for each date, owned by the Credential Owner — Apple.
Nothing in this repository can observe an Apple expiry date, so an unmaintained
table here is the failure mode to guard against.

Two automated backstops exist for exactly that failure mode, and neither
replaces the calendar reminder:

- The signed iOS workflow reads the expiry out of the provisioning profile it
  was given, fails the build if it has already lapsed, and emits a warning when
  fewer than 30 days remain.
- The per-release evidence file must carry `apple_certificate_expiry` and
  `apple_provisioning_profile_expiry`, and preflight fails the release if either
  date is not in the future.

**Rotation / compromise.** On suspected exposure of the `.p12` or its password:
revoke the certificate in the Apple Developer portal (this invalidates dependent
profiles), issue a new certificate and profile, update the secrets, and re-run
the workflow. Revoking a distribution certificate does not affect builds already
released on the App Store.

**Recovery.** An Apple certificate cannot be recovered — it is re-created. The
Apple Developer **account** access (Account Holder credentials and its
two-factor device/recovery key) is the asset that genuinely cannot be replaced by
the team; ensure at least two trusted people can reach it, or that account
recovery is documented with the organisation.

---

## 4. Store publishing credentials

None are stored in this repository, and no workflow publishes to a store.
Uploads to Play Console and App Store Connect are performed manually by the
Release Operator using their own authenticated console access, so no CI run can
publish a build by accident.

If automated upload is adopted later, the credentials required would be:

| Purpose | Credential type | Suggested secret names |
| --- | --- | --- |
| Google Play upload automation | Google Cloud service-account JSON with the Play Developer API enabled and access granted in Play Console | `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` |
| App Store Connect upload automation | App Store Connect API key (issuer id, key id, `.p8` private key) | `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_PRIVATE_KEY` |

Adopting either is a deliberate decision that widens the blast radius of a CI
compromise from "can build" to "can publish". It should be its own change, with
its own review.

---

## 5. Credential handling rules

- Secrets exist only as GitHub Actions secrets and in the owners' password
  manager / secure vault.
- Never `echo`, `cat` or otherwise print a secret in a workflow step; never write
  one to a file that could be uploaded as an artifact.
- Every workflow that materialises signing material deletes it in an
  `if: always()` step, so a failed build does not leave a keystore or keychain on
  the runner.
- Release signing must never fall back to debug signing or to an ad-hoc key. The
  Gradle configuration fails a release build outright when signing inputs are
  missing, and CI's temporary keystores are used only for non-publishable smoke
  builds that are never uploaded.
- `scripts/release_preflight.sh --require-secrets` checks only whether a named
  variable is non-empty, and reports only names.
- On any suspected exposure: rotate first, investigate second.

---

## 6. Annual credential review

Once a year (and after any personnel change), the Credential Owners jointly:

1. Confirm the named holders in section 1 are current.
2. Confirm Play App Signing status and the keystore backup is retrievable.
3. Confirm the Apple certificate/profile/membership expiry dates in section 3 and
   refresh the calendar reminders.
4. Confirm the GitHub repository secret list matches sections 2–3 exactly, with
   no stale or unexplained entries.
5. Run both signed-build workflows on `main` to prove the credentials still work
   before they are needed under time pressure.
