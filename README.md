# CaleeMobile

CaleeMobile is the mobile companion for Calee.

This app is based on the former CaleeSync Flutter project, but CaleeMobile is not a phone-local calendar sync utility.

## Current direction

CaleeMobile should connect to the existing Calee server / Nextcloud backend and provide mobile access to:

- Calendar
- Tasks
- Chores where supported
- Settings
- People/profile information
- Calee display setup and status where supported
- Weather and system messages where supported

## Future to-do

- Add a scan-to-create feature for calendar events, so users can scan supported event details and create Calee calendar events from them.

## Removed from the active app path

The active app startup no longer runs:

- local phone calendar sync
- Android SyncAdapter
- background sync worker startup
- CaleeSync sync repository startup
- device calendar permission flow

Legacy files may still exist temporarily while the app is being migrated, but they should not be part of the active CaleeMobile app flow.

## Run

Run:

    flutter pub get
    flutter run

## Development checks before commit

Before committing Dart changes, run:

    dart format lib test
    flutter analyze --fatal-infos
    flutter test

CI will fail if `dart format --set-exit-if-changed lib test` would modify any files.

## Cross-repository contracts

`contracts/event-occurrence-identity/v1/contract.json` is a **read-only mirror**
of the canonical event occurrence identity fixture authored in
[CaleeAdmin/calee-hub-core#424](https://github.com/CaleeAdmin/calee-hub-core/pull/424)
(SHA-256 `930d09c6760b88bb335c550afa52d100e19b7c888d72f35743653e2b0e1028f3`,
88,754 bytes). CalEmbed mirrors the identical bytes. An Event Link minted by one
Calee client is resolved by another, so all three must name one logical
occurrence the same way; the prose that governs the fixture lives in Hub Core at
`contracts/event-occurrence-identity/v1/README.md`.

Do not edit, reformat or regenerate the file here. A v1 case only ever changes
in Hub Core, and then every mirror is re-copied byte for byte.

`test/features/local_subscriber/event_occurrence_identity_contract_test.dart`
pins the digest and drives the real parser, recurrence engine, reconciler and
canonical helpers over it. Run it directly, including under a hostile device
timezone:

    TZ=Australia/Perth  flutter test test/features/local_subscriber/event_occurrence_identity_contract_test.dart
    TZ=UTC              flutter test test/features/local_subscriber/event_occurrence_identity_contract_test.dart
    TZ=Pacific/Kiritimati flutter test test/features/local_subscriber/event_occurrence_identity_contract_test.dart

Display parsing and canonical share identity are separate layers on purpose:
`local_calendar_ics_service.dart` keeps every legacy display fallback, and
`local_calendar_occurrence_identity.dart` fails closed. They are allowed to
disagree, and the contract requires that they do.

## Releasing

Store releases are documented in the repository, not in chat history:

- [`docs/RELEASE_OPERATIONS.md`](docs/RELEASE_OPERATIONS.md) — app identity,
  version policy, the `dev` → `stage` → `main` path, and the Google Play / App
  Store release, rollout, halt and corrective-release procedures.
- [`docs/RELEASE_CREDENTIALS.md`](docs/RELEASE_CREDENTIALS.md) — required
  credentials, GitHub Secret **names**, ownership, renewal and rotation. No
  secret values, ever.
- [`docs/STORE_RELEASE_CHECKLIST.md`](docs/STORE_RELEASE_CHECKLIST.md) — the
  per-release store metadata and submission checklist.
- [`docs/release_notes/`](docs/release_notes/) — one file per version; required
  by preflight.
- [`docs/release_evidence/`](docs/release_evidence/) — per-release readiness
  attestation, including the exact signed candidate that was device-qualified;
  required by the signed release workflows.

Before cutting a release:

    scripts/release_preflight.sh check                            # repository correctness
    scripts/release_preflight.sh check --require-build-readiness  # + may build a signed candidate
    scripts/release_preflight.sh check --require-store-readiness  # + may submit to a store

Production-signed artifacts can only be built from the `stage` or `main`
**branch**; the signed workflows fail closed on any other branch, and on a tag
of any name.

A successful build is not a release. PR CI success is not release approval, a
signed build is not store readiness (the candidate still has to be qualified on
a physical device), store readiness is not store approval, and publication is not
rollout completion — see section 11 of `docs/RELEASE_OPERATIONS.md`.
