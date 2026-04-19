#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBSPEC_FILE="$ROOT_DIR/pubspec.yaml"
IOS_GENERATED_XCCONFIG="$ROOT_DIR/ios/Flutter/Generated.xcconfig"
ANDROID_LOCAL_PROPERTIES="$ROOT_DIR/android/local.properties"

if [[ $# -lt 1 ]]; then
  echo "Usage: bash scripts/set_mobile_version.sh <version>"
  echo "Example: bash scripts/set_mobile_version.sh v0.1.0"
  exit 1
fi

RAW_VERSION="$1"
SEMVER="${RAW_VERSION#v}"

if [[ ! "$SEMVER" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "Version must look like v0.1.0 or 0.1.0"
  exit 1
fi

MAJOR="${BASH_REMATCH[1]}"
MINOR="${BASH_REMATCH[2]}"
PATCH="${BASH_REMATCH[3]}"

if (( MAJOR > 99 )); then
  echo "Major version must be between 0 and 99"
  exit 1
fi

if (( MINOR > 99 )); then
  echo "Minor version must be between 0 and 99"
  exit 1
fi

if (( PATCH > 999 )); then
  echo "Patch version must be between 0 and 999"
  exit 1
fi

PADDED_CODE="$(printf '%02d%02d%03d' "$MAJOR" "$MINOR" "$PATCH")"
BUILD_CODE="$((10#$PADDED_CODE))"
FLUTTER_VERSION="${SEMVER}+${BUILD_CODE}"

awk -v version="$FLUTTER_VERSION" '
  BEGIN { updated = 0 }
  /^version:/ {
    print "version: " version
    updated = 1
    next
  }
  { print }
  END {
    if (updated == 0) {
      exit 1
    }
  }
' "$PUBSPEC_FILE" > "$PUBSPEC_FILE.tmp"

mv "$PUBSPEC_FILE.tmp" "$PUBSPEC_FILE"

if command -v flutter >/dev/null 2>&1; then
  echo "Regenerating Flutter build metadata..."
  (
    cd "$ROOT_DIR"
    flutter pub get
  )
else
  echo "warning: flutter command not found; run 'flutter pub get' manually to refresh generated platform build metadata" >&2
fi

if [[ -f "$IOS_GENERATED_XCCONFIG" ]]; then
  awk -v name="$SEMVER" -v number="$BUILD_CODE" '
    /^FLUTTER_BUILD_NAME=/ {
      print "FLUTTER_BUILD_NAME=" name
      next
    }
    /^FLUTTER_BUILD_NUMBER=/ {
      print "FLUTTER_BUILD_NUMBER=" number
      next
    }
    { print }
  ' "$IOS_GENERATED_XCCONFIG" > "$IOS_GENERATED_XCCONFIG.tmp"
  mv "$IOS_GENERATED_XCCONFIG.tmp" "$IOS_GENERATED_XCCONFIG"
fi

if [[ -f "$ANDROID_LOCAL_PROPERTIES" ]]; then
  awk -v name="$SEMVER" -v number="$BUILD_CODE" '
    /^flutter\.versionName=/ {
      print "flutter.versionName=" name
      next
    }
    /^flutter\.versionCode=/ {
      print "flutter.versionCode=" number
      next
    }
    { print }
  ' "$ANDROID_LOCAL_PROPERTIES" > "$ANDROID_LOCAL_PROPERTIES.tmp"
  mv "$ANDROID_LOCAL_PROPERTIES.tmp" "$ANDROID_LOCAL_PROPERTIES"
fi

echo "Set Flutter version:"
echo "  semantic_version=v$SEMVER"
echo "  zero_padded_release_code=$PADDED_CODE"
echo "  flutter_build_number=$BUILD_CODE"
echo "  pubspec_version=$FLUTTER_VERSION"
