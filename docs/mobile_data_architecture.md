# CaleeMobile Data Architecture

CaleeMobile should use the Calee Client API as its backend boundary.

## Final direction

CaleeMobile should be a lightweight Flutter client:

CaleeMobile -> Calee Client API -> Calee Hub -> Nextcloud / CalDAV / Tasks / Chores / external calendar integrations

The mobile app should not reimplement the old Android/CaleeSync local calendar sync engine.

## Source of truth

The Calee server remains the source of truth.

CaleeMobile may later add local caching for speed and offline viewing, but the first implementation should use foreground server refresh only.

## Refresh model

Initial version:

- Fetch bootstrap after login
- Fetch screen data on screen open
- Pull to refresh
- Refresh after create/edit/delete
- Refresh on app resume if data is stale

Avoid background CalDAV sync in the mobile app.

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
- Direct Nextcloud CalDAV protocol handling

External calendar integrations should be handled by server-side Calee Hub integrations.

See `docs/calee_client_api_contract.md` for the shared Client API contract.
