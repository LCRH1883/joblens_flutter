# Joblens Flutter

Joblens is a cross-platform Flutter app (iOS + Android) for job photo capture and organization.

## Implemented MVP Foundation

- In-app camera capture (photo-only)
- Import photos from device gallery
- Private app storage for all Joblens photos (`joblens_media/originals` + `joblens_media/thumbnails`)
- Gallery timeline grouped by date (Immich-inspired interaction style)
- Projects (album-equivalent) with create, rename, delete, and detail views
- Queue-based sync engine with provider toggles for:
  - Google Drive
  - OneDrive
  - Nextcloud
  - Box
- Sync queue states: `queued`, `uploading`, `done`, `failed`, `paused`

## Cloud Sync Status

API-backed cloud adapters are implemented for all four providers:

- Google Drive (`Drive v3 API`)
- OneDrive (`Microsoft Graph Drive API`)
- Box (`Box Content API`)
- Nextcloud (`WebDAV`)

Credentials are stored in secure storage and configured from the **Sync** screen:

- Google Drive / OneDrive / Box: in-app OAuth (PKCE)
- Nextcloud: server URL + username + app password
- OAuth providers automatically refresh access tokens when they are near expiry.

OAuth client IDs are provided at runtime via `--dart-define`:

```bash
--dart-define=JOBLENS_GOOGLE_CLIENT_ID=...
--dart-define=JOBLENS_ONEDRIVE_CLIENT_ID=...
--dart-define=JOBLENS_BOX_CLIENT_ID=...
```

Register this redirect URI in each OAuth app configuration:

- `joblens:/oauth2redirect`

## Run

```bash
/Users/lcrh/Tools/flutter/bin/flutter pub get
/Users/lcrh/Tools/flutter/bin/flutter run \
  --dart-define=JOBLENS_GOOGLE_CLIENT_ID=... \
  --dart-define=JOBLENS_ONEDRIVE_CLIENT_ID=... \
  --dart-define=JOBLENS_BOX_CLIENT_ID=...
```

## Validate

```bash
/Users/lcrh/Tools/flutter/bin/flutter analyze
/Users/lcrh/Tools/flutter/bin/flutter test
```
