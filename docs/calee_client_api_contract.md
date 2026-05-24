# Calee Client API Contract

CaleeMobile should use the Calee Client API as its backend boundary.

This API is intended for Calee client apps, not only CaleeMobile. Future versions of the Calee tablet app should be able to use the same API.

## Final architecture

Calee client apps:

- CaleeMobile
- Calee tablet app
- Future Calee web/client apps

should use:

Calee client apps -> Calee Client API -> Calee Hub -> Nextcloud / CalDAV / Tasks / Chores / external calendar integrations

## Decision

CaleeMobile is a final product and should not implement direct CalDAV/WebDAV sync.

CaleeMobile should not directly talk to:

- Nextcloud CalDAV
- Google Calendar
- iCloud Calendar
- Outlook Calendar
- phone local calendars

Those integrations belong behind Calee Hub.

## Why

Direct CalDAV in the mobile app would make CaleeMobile responsible for:

- PROPFIND
- REPORT
- MKCALENDAR
- PROPPATCH
- PUT/DELETE of ICS files
- ETags
- CTags
- sync tokens
- ICS parsing/serialization
- recurrence edge cases
- conflict handling
- retry/rate-limit behavior
- provider-specific calendar differences

For a final product, this complexity should live server-side.

## API version

Use:

/client/v1

Do not use:

/mobile

because this API should be shared by CaleeMobile and future Calee clients.

## Authentication

CaleeMobile should authenticate with Calee Hub and receive a Calee client session token.

The mobile app should store only:

- Calee client session token
- non-sensitive user/session metadata
- optional cached API responses later

The mobile app should not store:

- Nextcloud app password
- Google credential
- Apple/iCloud credential
- Outlook credential

## Common headers

Requests:

Authorization: Bearer <calee_client_session_token>
Accept: application/json
Content-Type: application/json

## Common success response

Object response:

{
  "data": {},
  "meta": {
    "serverTime": "2026-05-24T00:00:00Z",
    "apiVersion": "client/v1"
  }
}

List response:

{
  "data": [],
  "meta": {
    "serverTime": "2026-05-24T00:00:00Z",
    "apiVersion": "client/v1",
    "cursor": null
  }
}

## Common error response

{
  "error": {
    "code": "UNAUTHORIZED",
    "message": "User is not authenticated"
  },
  "meta": {
    "serverTime": "2026-05-24T00:00:00Z",
    "apiVersion": "client/v1"
  }
}

## Error codes

Recommended initial error codes:

- UNAUTHORIZED
- FORBIDDEN
- NOT_FOUND
- VALIDATION_ERROR
- CONFLICT
- RATE_LIMITED
- SERVER_UNAVAILABLE
- UPSTREAM_CALENDAR_ERROR
- UNKNOWN_ERROR

## Endpoints

### POST /client/v1/auth/login

Authenticates a Calee user and creates a client session.

Request:

{
  "email": "user@example.com",
  "password": "password",
  "deviceName": "Yiwen's iPhone"
}

Response:

{
  "data": {
    "sessionToken": "token",
    "user": {
      "id": "user_123",
      "displayName": "Yiwen",
      "email": "user@example.com"
    }
  },
  "meta": {
    "serverTime": "2026-05-24T00:00:00Z",
    "apiVersion": "client/v1"
  }
}

### POST /client/v1/auth/logout

Invalidates the current client session.

### GET /client/v1/bootstrap

Returns initial data needed after login.

Response should include:

- current user
- family/account context
- capabilities
- summary counts
- default date/time settings

### GET /client/v1/calendars

Returns calendars visible to the user.

Calendar fields:

- id
- name
- color
- readOnly
- visible
- sourceType
- updatedAt

sourceType examples:

- calee
- nextcloud
- google
- icloud
- outlook
- subscribed

The mobile app should treat sourceType as display metadata only. It should not implement provider-specific sync behavior.

### GET /client/v1/events

Returns events for a date range.

Query parameters:

- start
- end
- calendarIds optional
- cursor optional

Event fields:

- id
- calendarId
- title
- description
- location
- startsAt
- endsAt
- allDay
- recurrence
- attendees
- updatedAt
- deletedAt optional

### POST /client/v1/events

Creates an event.

### PATCH /client/v1/events/{eventId}

Updates an event.

### DELETE /client/v1/events/{eventId}

Deletes an event.

### GET /client/v1/tasks

Returns task lists and tasks visible to the user.

Task fields:

- id
- listId
- title
- notes
- dueAt
- completed
- updatedAt
- deletedAt optional

### POST /client/v1/tasks

Creates a task.

### PATCH /client/v1/tasks/{taskId}

Updates a task.

### DELETE /client/v1/tasks/{taskId}

Deletes a task.

### GET /client/v1/chores

Returns chores visible to the user.

Chore fields:

- id
- title
- notes
- assignedTo
- dueAt
- completed
- recurrence
- updatedAt
- deletedAt optional

### POST /client/v1/chores

Creates a chore.

### PATCH /client/v1/chores/{choreId}

Updates a chore.

### DELETE /client/v1/chores/{choreId}

Deletes a chore.

### GET /client/v1/profile

Returns the current user profile.

### PATCH /client/v1/profile

Updates supported profile fields.

## Refresh model

Initial production mobile behavior:

- Fetch bootstrap after login
- Fetch screen data on screen open
- Pull to refresh on feature screens
- Refresh affected screen after create/edit/delete
- Refresh on app resume if data is stale

Avoid mobile-side background CalDAV sync.

## Incremental refresh

The first version can use date ranges and full screen refreshes.

Later, the API can support:

- cursor
- syncVersion
- updatedSince
- deletedAt tombstones

These are Calee Client API concepts. They should not expose raw CalDAV sync tokens or ETags to the mobile app unless absolutely necessary.

## Conflict handling

The server should detect conflicts and return:

{
  "error": {
    "code": "CONFLICT",
    "message": "This item changed on another device. Please refresh and try again."
  },
  "meta": {
    "serverTime": "2026-05-24T00:00:00Z",
    "apiVersion": "client/v1"
  }
}

The mobile app should show the message and refresh the affected screen.

## Offline cache

Offline cache can be added later.

When added, it should cache Calee Client API responses, not phone local calendar data and not raw CalDAV state.

Potential cached data:

- calendars
- visible event range
- tasks
- chores
- profile

## Backend responsibilities

Calee Hub should handle:

- Nextcloud/CalDAV communication
- ICS parsing/serialization
- ETags/CTags/sync tokens
- conflict detection
- provider credentials
- Google/iCloud/Outlook integrations
- rate limiting
- audit logs
- server-side permissions
- family/member access rules

## Mobile responsibilities

CaleeMobile should handle:

- UI
- client session token
- API calls
- loading/error/empty states
- foreground refresh
- optional API response cache later
- user-friendly conflict/error messages

## Out of scope for CaleeMobile

CaleeMobile should not implement:

- Android SyncAdapter
- iOS background CalDAV engine
- phone local calendar sync
- native calendar bridge
- CalDAV REPORT/PROPFIND/MKCALENDAR/PROPPATCH directly
- raw ICS parsing/serialization
- Google/iCloud/Outlook credential storage
- third-party calendar sync logic

