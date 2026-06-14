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
