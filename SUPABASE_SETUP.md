# Joblens Flutter Supabase Setup

This file describes how the Flutter app should be pointed at the Joblens backend/Supabase environment.

Use this after the backend setup in:

- `/Volumes/ExData/Projects/Joblens/joblens_backend/SUPABASE_SETUP.md`

## Required values

The Flutter app needs these runtime values:

- `JOBLENS_SUPABASE_URL`
- `JOBLENS_SUPABASE_ANON_KEY`
- `API_BASE_URL`

For the standard Joblens self-hosted setup:

- `JOBLENS_SUPABASE_URL` should match backend `.env` `SUPABASE_URL`
- `JOBLENS_SUPABASE_ANON_KEY` should match backend `.env` `SUPABASE_ANON_KEY`
- `API_BASE_URL` should usually be `${JOBLENS_SUPABASE_URL}/functions/v1/api/v1`

Example:

```text
JOBLENS_SUPABASE_URL=https://api.joblens.xyz
JOBLENS_SUPABASE_ANON_KEY=...
API_BASE_URL=https://api.joblens.xyz/functions/v1/api/v1
```

## Important auth callback requirement

The app expects this deep link:

- `joblens://auth-callback`

The live Supabase Auth configuration must allow that callback for:

- sign up email confirmation
- forgot-password recovery

If the live server auth settings do not allow that deep link, sign-in-related email links will not return to the app correctly.

## Automation-safe local run command

Run from `/Volumes/ExData/Projects/Joblens/joblens_flutter`.

```bash
/Users/lcrh/Tools/flutter/bin/flutter run \
  --dart-define=JOBLENS_SUPABASE_URL=https://api.joblens.xyz \
  --dart-define=JOBLENS_SUPABASE_ANON_KEY=YOUR_ANON_KEY \
  --dart-define=API_BASE_URL=https://api.joblens.xyz/functions/v1/api/v1
```

## iOS build notes

For auth and sync testing, prefer Flutter CLI builds with `--dart-define` values.

Example:

```bash
/Users/lcrh/Tools/flutter/bin/flutter build ios --simulator \
  --dart-define=JOBLENS_SUPABASE_URL=https://api.joblens.xyz \
  --dart-define=JOBLENS_SUPABASE_ANON_KEY=YOUR_ANON_KEY \
  --dart-define=API_BASE_URL=https://api.joblens.xyz/functions/v1/api/v1
```

If you build directly from Xcode, the same values must be injected into the iOS build configuration. Codex should not assume Xcode already has them.

## Android build notes

Use the same `--dart-define` values with `flutter run` or `flutter build`.

## What should work after setup

With valid values in place, the app should be able to:

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
/Users/lcrh/Tools/flutter/bin/flutter build ios --simulator \
  --dart-define=JOBLENS_SUPABASE_URL=https://api.joblens.xyz \
  --dart-define=JOBLENS_SUPABASE_ANON_KEY=YOUR_ANON_KEY \
  --dart-define=API_BASE_URL=https://api.joblens.xyz/functions/v1/api/v1
```

## Codex automation notes

Codex can safely:

- read backend `.env` to get `SUPABASE_URL` and `SUPABASE_ANON_KEY`
- derive `API_BASE_URL`
- run Flutter commands with `--dart-define`
- verify analyze, tests, and simulator builds

Codex should not:

- invent missing anon keys
- assume Xcode schemes already carry the correct Dart defines
- change the app deep link without matching backend auth config changes
