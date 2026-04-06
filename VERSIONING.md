# Joblens Mobile Versioning

This file is the source of truth for Joblens mobile app versioning across Flutter, Android, and iOS.

## Current release

- first shared Android/iOS release: `v0.1.0`
- Flutter version string: `0.1.0+1000`
- numeric release code: `1000`
- zero-padded release code representation: `0001000`

## Format

Use this public version format:

- `vxx.xx.xxx`

Meaning:

- `major`: 2 digits
- `minor`: 2 digits
- `patch`: 3 digits

Examples:

- `v00.01.000` -> `0001000`
- `v01.03.001` -> `0103001`
- `v00.03.012` -> `0003012`

When writing human-facing release notes, you can omit leading zeroes:

- `v0.1.0` means `v00.01.000`
- `v1.3.1` means `v01.03.001`
- `v0.3.12` means `v00.03.012`

## Flutter source of truth

Flutter drives both platform versions from `pubspec.yaml`:

```yaml
version: 0.1.0+1000
```

Rules:

- `0.1.0` is the user-facing app version
- `1000` is the numeric build/release code
- update `pubspec.yaml` first for every release

Use the helper script to do that automatically:

```bash
cd /Volumes/ExData/Projects/Joblens/joblens_flutter
bash scripts/set_mobile_version.sh v0.1.0
```

## Mapping to Android

Android uses:

- `versionName = flutter.versionName`
- `versionCode = flutter.versionCode`

That means:

- `versionName` becomes `0.1.0`
- `versionCode` becomes `1000`

Android requirement:

- `versionCode` must always increase for every Play Store release

## Mapping to iOS

iOS uses:

- `CFBundleShortVersionString = $(FLUTTER_BUILD_NAME)`
- `CFBundleVersion = $(FLUTTER_BUILD_NUMBER)`

That means:

- `CFBundleShortVersionString` becomes `0.1.0`
- `CFBundleVersion` becomes `1000`

iOS requirement:

- `CFBundleVersion` must increase for every App Store/TestFlight build for a given app

## Release rules

Use one shared main release version across Android and iOS whenever possible.

If one platform needs a platform-specific follow-up build:

- keep the main semantic version aligned unless the user-facing release changed
- always increment the numeric build code

Examples:

- shared release `v0.1.0` -> `0.1.0+1000`
- Android-only rebuild for the same release -> `0.1.0+1001`
- iOS-only rebuild for the same release -> `0.1.0+1002`
- next user-facing patch release `v0.1.1` -> `0.1.1+1001` is not allowed if `1001` was already used
- next user-facing patch release should use a higher code, for example `0.1.1+1003`

Rule:

- the build code is global and monotonically increasing across both platforms

## How to derive the numeric release code

Pad the semantic version to:

- major: 2 digits
- minor: 2 digits
- patch: 3 digits

Then concatenate them:

- `major=00`
- `minor=01`
- `patch=000`
- result: `0001000`

Because Flutter/Android build codes are integers, the stored numeric build code for `0001000` is:

- `1000`

More examples:

- `v1.3.1` -> padded `01.03.001` -> code `0103001` -> stored as `103001`
- `v0.3.12` -> padded `00.03.012` -> code `0003012` -> stored as `3012`

For docs and release planning, keep the zero-padded representation.
For `pubspec.yaml`, use the integer form after `+`.

## Release checklist

1. Decide the next semantic version.
2. Update `pubspec.yaml` with:

```bash
bash scripts/set_mobile_version.sh v0.1.0
```

3. Run:

```bash
/Users/lcrh/Tools/flutter/bin/flutter pub get
/Users/lcrh/Tools/flutter/bin/flutter analyze
/Users/lcrh/Tools/flutter/bin/flutter test
```

4. Build Android and iOS from the same `pubspec.yaml` version.
5. Verify:
   - Android versionName/versionCode
   - iOS CFBundleShortVersionString/CFBundleVersion
6. Generate release notes:

```bash
bash scripts/prepare_release_notes.sh v0.1.0
```

7. Review:
   - `release/android/CHANGELOG.md`
   - `release/ios/CHANGELOG.md`

## Important note

Do not edit platform version values separately unless there is a deliberate exception. The normal workflow is:

- update `pubspec.yaml`
- let Flutter propagate the version to Android and iOS
