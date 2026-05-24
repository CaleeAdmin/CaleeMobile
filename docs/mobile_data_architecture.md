# CaleeMobile Data Architecture

CaleeMobile should use the Calee Hub API as its backend boundary.

## Direction

CaleeMobile should be a lightweight Flutter client:

CaleeMobile -> Calee Hub API -> Nextcloud / CalDAV / Tasks / Chores

The mobile app should not reimplement the old Android/CaleeSync local calendar sync engine.

## Source of truth

The Calee server remains the source of truth.

CaleeMobile may later add local caching for speed and offline viewing, but the first implementation should use foreground server refresh only.

## Refresh model

Initial version:

- Fetch on app open
- Pull to refresh
- Refresh after create/edit/delete
- Refresh on app resume if data is stale

Avoid background sync until the foreground app is stable.

## Feature areas

CaleeMobile should rebuild these features intentionally:

- Calendar
- Tasks
- Chores
- Settings
- Account/profile
- Family/member data where needed

## Not included in mobile app

Do not rebuild:

- Phone local calendar sync
- Android SyncAdapter behavior
- Native calendar bridge
- Background CalDAV workers
- Local dirty-event sync engine
- Direct Google/iCloud/Outlook credential handling

External calendar integrations should be handled by server-side Calee Hub integrations.
