# Joblens Flutter Supabase Setup

This file describes the local-first Flutter setup for Joblens.

The app should run from a local `.env` copy. Infisical is used to sync and refresh that file, not as a runtime dependency on every launch.

Use this after the backend setup in:

- `/Volumes/ExData/Projects/Joblens/joblens_backend/SUPABASE_SETUP.md`

## Local-first model

The intended workflow is:

- keep the canonical mobile-safe secrets in Infisical at `/joblens/mobile`
- export them into a local `.env` file in the Flutter repo
- run Flutter with `--dart-define-from-file=.env`

The app also bundles the local `.env` as a runtime fallback for local development, so IDE-launched Android/iOS debug builds can still read the same mobile-safe values even if the launch configuration does not pass Dart defines explicitly.

This means the app still runs from the local `.env` copy even if Infisical is temporarily unavailable.

## Required values

The Flutter app needs these runtime values in `.env`:

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `API_BASE_URL`

For the standard Joblens setup:

- `SUPABASE_URL` should match backend `SUPABASE_URL`
- `SUPABASE_ANON_KEY` should match backend `SUPABASE_ANON_KEY`
- `API_BASE_URL` should usually be `${SUPABASE_URL}/functions/v1/api/v1`

Example:

```text
SUPABASE_URL=https://api.joblens.xyz
SUPABASE_ANON_KEY=...
API_BASE_URL=https://api.joblens.xyz/functions/v1/api/v1
```

## Secrets that must not be in Flutter

The Flutter `.env` must not contain backend-only secrets such as:

- `SUPABASE_SERVICE_ROLE_KEY`
- `DATABASE_URL`
- `MAILGUN_SMTP_PASSWORD`
- `PROVIDER_SECRET_ENCRYPTION_KEY`
- `ENCRYPTION_MASTER_KEY`

Only mobile-safe values should exist in `/joblens/mobile`.

## Important auth callback requirement

The app expects this deep link:

- `joblens://auth-callback`

The live Supabase Auth configuration must allow that callback for:

- sign up email confirmation
- forgot-password recovery

If the live server auth settings do not allow that deep link, sign-in-related email links will not return to the app correctly.

For email-link auth flows, Joblens should use the public backend callback page:

- `https://api.joblens.xyz/functions/v1/api/v1/auth/callback`

That page can:

- hand off to `joblens://auth-callback` on phones
- show a fallback confirmation page on desktop browsers

## Important testing split for auth emails

Use the public `https://api.joblens.xyz` auth environment when testing:

- sign-up confirmation emails
- forgot-password emails
- any auth flow where you tap an email link on a real phone

Do not treat the local CLI Supabase stack as the source of truth for those flows. In local development, confirmation/recovery links may resolve through a local `127.0.0.1` auth host, which will not work correctly on a device.

For normal app development, keep using the local exported `.env`. For email-link auth verification, point the app at the public environment and use the real `api.joblens.xyz` flow.

## Export local `.env` from Infisical

Run from `/Volumes/ExData/Projects/Joblens/joblens_flutter`.

```bash
infisical export --domain=https://app.infisical.com --env=prod --path=/joblens/mobile --format=dotenv --output-file=.env
```

Re-run that command any time you change the mobile secrets in Infisical and want to refresh your local copy.

## Normal local development

Run from `/Volumes/ExData/Projects/Joblens/joblens_flutter`.

```bash
/Users/lcrh/Tools/flutter/bin/flutter pub get
/Users/lcrh/Tools/flutter/bin/flutter run --dart-define-from-file=.env
```

This uses the local exported `.env` file and does not require contacting Infisical on app launch.

If you launch from Android Studio or Xcode without explicit Dart defines, the app falls back to the bundled local `.env` asset.

## iOS build notes

For auth and sync testing, prefer Flutter CLI builds using the local `.env` copy.

Example:

```bash
/Users/lcrh/Tools/flutter/bin/flutter build ios --simulator --dart-define-from-file=.env
```

If you build directly from Xcode, the same values must be injected into the iOS build configuration. Codex should not assume Xcode already has them.

## Android build notes

Use the same local `.env` copy with:

```bash
/Users/lcrh/Tools/flutter/bin/flutter run --dart-define-from-file=.env
```

## What should work after setup

With a valid local `.env` in place, the app should be able to:

- open the shell normally
- sign in with Supabase Auth
- create a Joblens account
- handle email confirmation links
- handle forgot-password recovery links
- connect cloud providers through the backend

## Validation

Run these in `/Volumes/ExData/Projects/Joblens/joblens_flutter`:

```bash
/Users/lcrh/Tools/flutter/bin/flutter analyze
/Users/lcrh/Tools/flutter/bin/flutter test
```

Optional iOS compile check:

```bash
/Users/lcrh/Tools/flutter/bin/flutter build ios --simulator --dart-define-from-file=.env
```

## Codex automation notes

Codex can safely:

- export the mobile-safe secrets from Infisical into `.env`
- verify `.env` contains only `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `API_BASE_URL`
- run Flutter with `--dart-define-from-file=.env`
- verify analyze, tests, and simulator builds

Codex should not:

- invent missing secrets
- copy backend-only secrets into Flutter
- assume Xcode schemes already carry the correct Dart defines
- change the app deep link without matching backend auth config changes
