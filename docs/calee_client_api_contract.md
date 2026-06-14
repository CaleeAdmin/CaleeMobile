# Calee Client API Contract

CaleeMobile should use the Calee Client API as its backend boundary.

This API is intended for Calee client apps, not only CaleeMobile. Future versions of the Calee display app should be able to use the same API.

## Final architecture

Calee client apps:

- CaleeMobile
- Calee display app
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
      "id": "user_123"
    }
  }
}
