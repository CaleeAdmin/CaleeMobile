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
- [`docs/release_evidence/`](docs/release_evidence/) — per-release store-readiness
  attestation; required by the signed release workflows.

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
