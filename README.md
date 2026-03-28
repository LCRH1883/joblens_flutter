# Joblens Flutter

Joblens is a cross-platform Flutter app (iOS + Android) for job photo capture and organization.

## Architecture

- The user signs into Joblens with Supabase Auth.
- The user then connects a cloud storage account they already own:
  - Google Drive
  - OneDrive
  - Dropbox
  - Box
  - Nextcloud
- Provider storage is the canonical home for synced Joblens content.
- Supabase stores app auth, provider connection state, sync metadata, asset indexes, and coordination data between devices.
- The mobile app keeps a local private cache in app storage and syncs through the Joblens backend.
- See `SUPABASE_SETUP.md` for automation-safe app setup instructions using backend Supabase values.

## Current App Scope

- In-app camera capture (photo-only)
- Import photos from device gallery
- Private app storage for local originals and thumbnails
- Gallery timeline grouped by date
- Projects with create, rename, delete, notes, and detail views
- Backend-orchestrated sync queue with provider connection management
- Remote asset merge and backend-proxied media URLs for cloud-only items

## Provider Connection Flow

- Google Drive, OneDrive, Dropbox, and Box connect through backend-managed OAuth in the browser.
- Nextcloud connects by sending server URL, username, and app password to the backend.
- The Flutter app does not keep provider OAuth tokens as its source of truth.
- The backend stores provider connection secrets and refresh state.

## Run

```bash
/Users/lcrh/Tools/flutter/bin/flutter pub get
/Users/lcrh/Tools/flutter/bin/flutter run \
  --dart-define=JOBLENS_SUPABASE_URL=... \
  --dart-define=JOBLENS_SUPABASE_ANON_KEY=... \
  --dart-define=API_BASE_URL=https://api.joblens.xyz/functions/v1/api/v1
```

If `API_BASE_URL` is omitted, the app defaults to `${JOBLENS_SUPABASE_URL}/functions/v1/api/v1`.

## Auth Notes

- Joblens app login uses Supabase Auth email/password sessions.
- The mobile app deep link for auth callbacks is `joblens://auth-callback`.
- If email confirmation is enabled in Supabase Auth, add `joblens://auth-callback` to the project's auth redirect allow-list so confirmation links can return the user to the app.
- Forgot-password recovery uses the same deep link. Supabase password reset emails should return to `joblens://auth-callback` so the app can open the reset-password screen directly.

## Validate

```bash
/Users/lcrh/Tools/flutter/bin/flutter analyze
/Users/lcrh/Tools/flutter/bin/flutter test
```
