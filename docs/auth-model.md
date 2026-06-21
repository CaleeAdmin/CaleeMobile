# CaleeMobile Auth Model

CaleeMobile signs in to Calee Hub using Calee account email/password or registration.

The app stores Hub access/refresh tokens in FlutterSecureStorage.

Authenticated `/client/v1` calls use:

```text
Authorization: Bearer <accessToken>
```

On HTTP 401, the app refreshes the access token using the refresh token and retries once.

CalDAV account credentials returned by Hub are service credentials for external calendar setup. They are not the app login password and must not be used as the mobile app session auth.
