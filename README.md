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
infisical export --domain=https://app.infisical.com --env=prod --path=/joblens/mobile --format=dotenv --output-file=.env
/Users/lcrh/Tools/flutter/bin/flutter pub get
/Users/lcrh/Tools/flutter/bin/flutter run --dart-define-from-file=.env
```

The local `.env` is the runtime source of truth for development. Refresh it from Infisical manually when secrets change.

The app now supports two local-first paths:

- preferred CLI path: `flutter run --dart-define-from-file=.env`
- IDE fallback path: if Dart defines are not passed, the app loads the bundled local `.env` asset at runtime

That means Android Studio and Xcode debug builds can still use the local `.env` copy without contacting Infisical at launch.

The app accepts either:

- `SUPABASE_URL` / `SUPABASE_ANON_KEY`
- `JOBLENS_SUPABASE_URL` / `JOBLENS_SUPABASE_ANON_KEY`

If `API_BASE_URL` is omitted, the app defaults to `${SUPABASE_URL}/functions/v1/api/v1`.

Optional crash reporting values:

- `SENTRY_DSN`
- `SENTRY_ENVIRONMENT`

For the current GlitchTip setup, the DSN host should use the public ingest domain, for example:

```text
SENTRY_DSN=https://<public-key>@crash.joblens.xyz/<project-id>
SENTRY_ENVIRONMENT=production
```

The Flutter app uses `sentry_flutter` only. There are no AndroidManifest or iOS plist crash-reporting overrides required for basic setup.

## Auth Notes

- Joblens app login uses Supabase Auth email/password sessions.
- The mobile app deep link for auth callbacks is `joblens://auth-callback`.
- Email signup confirmation and forgot-password links should redirect to the public backend callback page at `https://api.joblens.xyz/functions/v1/api/v1/auth/callback`, which can hand off to `joblens://auth-callback` on phones and show a fallback page on desktop.
- If email confirmation is enabled in Supabase Auth, add `joblens://auth-callback` to the project's auth redirect allow-list so confirmation links can return the user to the app.
- Forgot-password recovery uses the same deep link. Supabase password reset emails should return to `joblens://auth-callback` so the app can open the reset-password screen directly.
- For real device testing of confirmation/reset emails, use the public `https://api.joblens.xyz` auth environment. Do not rely on a local CLI Supabase stack for those email-link flows because it can generate local `127.0.0.1` verification links.

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
