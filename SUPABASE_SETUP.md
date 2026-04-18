# Joblens Flutter Supabase Setup

This file describes the local-first Flutter setup for Joblens.

The app should run from a local `.env` copy. Infisical is used to sync and refresh that file, not as a runtime dependency on every launch.

Use this after the backend setup in:

- `/Volumes/ExData/Projects/Joblens/joblens_backend/SUPABASE_SETUP.md`

## Local-first model

The intended workflow is:

- keep separate mobile-safe values for the dev and prod backends
- store them in local `.env.dev` and `.env.prod` files in the Flutter repo
- run Flutter with `--dart-define-from-file=.env.dev` or `--dart-define-from-file=.env.prod`

The app still bundles `.env` as a runtime fallback for local development, but that file is now dev-only convenience. Explicit CLI and release builds should always use `.env.dev` or `.env.prod`.

This means Android Studio and Xcode debug launches can still work locally without Dart defines, but production verification and release builds no longer depend on a generic `.env`.

## Required values

The Flutter app needs these runtime values in `.env.dev` and `.env.prod`:

- `JOBLENS_ENV`
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `API_BASE_URL`

The supported environment contract is:

- dev:
  - `JOBLENS_ENV=dev`
  - `SUPABASE_URL=https://dev.joblens.xyz`
  - `API_BASE_URL=https://dev.joblens.xyz/functions/v1/api/v1`
- prod:
  - `JOBLENS_ENV=prod`
  - `SUPABASE_URL=https://api.joblens.xyz`
  - `API_BASE_URL=https://api.joblens.xyz/functions/v1/api/v1`

The app validates those URLs when `JOBLENS_ENV` is set, and the release scripts refuse to build if the selected env file does not match the requested environment.

Examples:

```text
JOBLENS_ENV=dev
SUPABASE_URL=https://dev.joblens.xyz
SUPABASE_ANON_KEY=...
API_BASE_URL=https://dev.joblens.xyz/functions/v1/api/v1
```

```text
JOBLENS_ENV=prod
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

Each environment's Supabase Auth configuration must allow that callback for:

- sign up email confirmation
- forgot-password recovery

If the selected environment does not allow that deep link, sign-in-related email links will not return to the app correctly.

For email-link auth flows, Joblens now uses the selected backend callback page:

- dev: `https://dev.joblens.xyz/functions/v1/api/v1/auth/callback`
- prod: `https://api.joblens.xyz/functions/v1/api/v1/auth/callback`

That page can:

- hand off to `joblens://auth-callback` on phones
- show a fallback confirmation page on desktop browsers

Provider OAuth start and callback URLs also resolve from the selected backend API base URL, and completion now redirects directly back to `joblens://auth-callback` instead of using a fixed production web return page.

## Important testing split for auth emails

Use the environment you are actively validating when testing:

- sign-up confirmation emails
- forgot-password emails
- any auth flow where you tap an email link on a real phone

Do not treat a local CLI Supabase stack as the source of truth for those flows. In local development, confirmation/recovery links may resolve through a local `127.0.0.1` auth host, which will not work correctly on a device.

For normal app development, use `.env.dev`. For production verification, use `.env.prod`.

## Create local env files

Run from `/Volumes/ExData/Projects/Joblens/joblens_flutter`.

```bash
cp .env.dev.example .env.dev
cp .env.prod.example .env.prod
```

Then fill in the correct anon key for each environment from your secret manager. Keep `.env.dev` and `.env.prod` out of source control.

If you still want IDE launches without Dart defines, copy `.env.dev` to `.env` locally and keep `.env` on the dev backend only.

## Normal local development

Run from `/Volumes/ExData/Projects/Joblens/joblens_flutter`.

```bash
/Users/lcrh/Tools/flutter/bin/flutter pub get
/Users/lcrh/Tools/flutter/bin/flutter run --dart-define-from-file=.env.dev
```

This uses the explicit dev env file and does not require contacting a secret manager on app launch.

To verify the production backend locally:

```bash
/Users/lcrh/Tools/flutter/bin/flutter run --dart-define-from-file=.env.prod
```

If you launch from Android Studio or Xcode without explicit Dart defines, the app falls back to the bundled local `.env` asset when present.

## iOS build notes

For auth and sync testing, prefer Flutter CLI builds using `.env.dev` or `.env.prod`.

TestFlight/dev build:

```bash
bash scripts/build_ios_release.sh dev v0.1.0
```

TestFlight/prod build:

```bash
bash scripts/build_ios_release.sh prod v0.1.0
```

The script validates the env file before building and writes the selected environment into the output folder metadata.

## Android build notes

Use the same explicit env files with:

```bash
bash scripts/build_android_release.sh dev v0.1.0
```

```bash
bash scripts/build_android_release.sh prod v0.1.0
```

## What should work after setup

With valid `.env.dev` and `.env.prod` files in place, the app should be able to:

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

- verify `.env.dev` and `.env.prod` contain `JOBLENS_ENV`, `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `API_BASE_URL`
- run Flutter with `--dart-define-from-file=.env.dev` or `--dart-define-from-file=.env.prod`
- verify analyze, tests, and simulator builds

Codex should not:

- invent missing secrets
- copy backend-only secrets into Flutter
- assume Xcode schemes or Android Studio launchers already carry the correct Dart defines
- change the app deep link without matching backend auth config changes
