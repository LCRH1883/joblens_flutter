# Release Builds

This repo now has a repeatable release output flow for both Android and iOS.

Artifacts are copied into:

- `release/android/`
- `release/ios/`

Each build creates a versioned timestamped folder so artifacts do not overwrite each other.

## Prerequisites

### Shared

- local `.env` exists in the repo root
- Flutter is installed

### Android

For real Play Store releases, create:

- `android/key.properties`

Use:

- `android/key.properties.example`

If `android/key.properties` is missing, Android release builds will still compile using the debug signing config, but those artifacts are not suitable for store upload.

### iOS

For real App Store/TestFlight releases, create:

- `ios/ExportOptions.plist`

Use:

- `ios/ExportOptions.plist.example`

You also need working Apple signing in Xcode for the `Runner` target.

## Build Android Release

```bash
cd /Volumes/ExData/Projects/Joblens/joblens_flutter
bash scripts/build_android_release.sh v0.1.0
```

Outputs:

- release APK
- release AAB
- `release-info.txt`
- auto-updates `pubspec.yaml` to the matching Flutter version/build number before building

## Build iOS Release

```bash
cd /Volumes/ExData/Projects/Joblens/joblens_flutter
bash scripts/build_ios_release.sh v0.1.0
```

Outputs:

- `.ipa`
- zipped `.xcarchive` when available
- `release-info.txt`
- auto-updates `pubspec.yaml` to the matching Flutter version/build number before building

## Notes

- Android release upload normally uses the `.aab`
- iOS upload normally uses the `.ipa`
- `release/` artifacts are ignored by git, but the folder structure is kept in the repo
- both scripts use `scripts/set_mobile_version.sh` so Android and iOS stay in sync on the same release version
