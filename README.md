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

## Environment Files

Use separate local env files for explicit mobile builds:

- `.env.dev`
- `.env.prod`

Start from the checked-in examples:

```bash
cp .env.dev.example .env.dev
cp .env.prod.example .env.prod
```

Each file must contain:

- `JOBLENS_ENV=dev` or `JOBLENS_ENV=prod`
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `API_BASE_URL`

The supported backend contract is fixed:

- dev: `SUPABASE_URL=https://dev.joblens.xyz`
- dev: `API_BASE_URL=https://dev.joblens.xyz/functions/v1/api/v1`
- prod: `SUPABASE_URL=https://api.joblens.xyz`
- prod: `API_BASE_URL=https://api.joblens.xyz/functions/v1/api/v1`

The release scripts validate that the selected env file matches that contract before they build, so a prod build cannot silently point at dev and a dev build cannot silently point at prod.

`.env` is now only an optional dev-only fallback asset for IDE launches that do not pass Dart defines. Keep `.env` on the dev backend if you use that fallback. Do not use `.env` for prod verification or release builds.

## Run

Install dependencies once:

```bash
/Users/lcrh/Tools/flutter/bin/flutter pub get
```

Local dev build against the dev backend:

```bash
/Users/lcrh/Tools/flutter/bin/flutter run --dart-define-from-file=.env.dev
```

Local prod verification build:

```bash
/Users/lcrh/Tools/flutter/bin/flutter run --dart-define-from-file=.env.prod
```

## Auth Notes

- Joblens app login uses Supabase Auth email/password sessions.
- The mobile app deep link for auth callbacks is `joblens://auth-callback`.
- Email signup confirmation and forgot-password links are generated from the selected backend environment:
  - dev: `https://dev.joblens.xyz/functions/v1/api/v1/auth/callback`
  - prod: `https://api.joblens.xyz/functions/v1/api/v1/auth/callback`
- If email confirmation is enabled in Supabase Auth, add `joblens://auth-callback` to the project's auth redirect allow-list so confirmation links can return the user to the app.
- Forgot-password recovery uses the same deep link after the backend callback page hands off to the app.
- Provider OAuth starts and callback URLs are resolved from the selected backend API base URL, and provider completion now returns to `joblens://auth-callback` instead of a fixed production web host.
- For real device testing of confirmation/reset emails, use the environment you are validating and make sure that environment's Supabase Auth redirect allow-list includes `joblens://auth-callback`.

## Release Builds

iOS/TestFlight build for dev:

```bash
bash scripts/build_ios_release.sh dev v0.1.0
```

iOS/TestFlight build for prod:

```bash
bash scripts/build_ios_release.sh prod v0.1.0
```

Android/Play testing build for dev:

```bash
bash scripts/build_android_release.sh dev v0.1.0
```

Android/Play testing build for prod:

```bash
bash scripts/build_android_release.sh prod v0.1.0
```

Both release scripts default to `.env.dev` or `.env.prod`, reject mismatched URLs, and write the selected environment into the artifact folder and `release-info.txt`.

## Validate

```bash
/Users/lcrh/Tools/flutter/bin/flutter analyze
/Users/lcrh/Tools/flutter/bin/flutter test
```


## Versioning

See [`VERSIONING.md`](/Volumes/ExData/Projects/Joblens/joblens_flutter/VERSIONING.md) for the shared Android/iOS release versioning rules.

Set the shared mobile version with:

```bash
cd /Volumes/ExData/Projects/Joblens/joblens_flutter
bash scripts/set_mobile_version.sh v0.1.0
```

## Release Notes

Use the per-platform changelogs to track every user-facing release:

- [`release/android/CHANGELOG.md`](/Volumes/ExData/Projects/Joblens/joblens_flutter/release/android/CHANGELOG.md)
- [`release/ios/CHANGELOG.md`](/Volumes/ExData/Projects/Joblens/joblens_flutter/release/ios/CHANGELOG.md)

To make this maintainable, Joblens also uses release fragments:

- add a fragment when a feature, major change, or major bug fix lands
- generate the next version entry with `bash scripts/prepare_release_notes.sh v0.1.1`

Create a new fragment with:

```bash
bash scripts/new_release_fragment.sh both feature some-change-slug
```
