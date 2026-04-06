#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_BIN="${FLUTTER_BIN:-/Users/lcrh/Tools/flutter/bin/flutter}"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"
EXPORT_OPTIONS_PLIST="${EXPORT_OPTIONS_PLIST:-$ROOT_DIR/ios/ExportOptions.plist}"
VERSION_HELPER="$ROOT_DIR/scripts/set_mobile_version.sh"

if [[ $# -lt 1 ]]; then
  echo "Usage: bash scripts/build_ios_release.sh <version>"
  echo "Example: bash scripts/build_ios_release.sh v0.1.0"
  exit 1
fi

RELEASE_VERSION="$1"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE"
  exit 1
fi

if [[ ! -f "$EXPORT_OPTIONS_PLIST" ]]; then
  echo "Missing ExportOptions.plist: $EXPORT_OPTIONS_PLIST"
  echo "Copy ios/ExportOptions.plist.example to ios/ExportOptions.plist and configure it."
  exit 1
fi

if [[ ! -x "$VERSION_HELPER" ]]; then
  echo "Missing executable version helper: $VERSION_HELPER"
  exit 1
fi

cd "$ROOT_DIR"
bash "$VERSION_HELPER" "$RELEASE_VERSION"

VERSION="$(awk '/^version:/ {print $2; exit}' "$ROOT_DIR/pubspec.yaml")"
TIMESTAMP="$(date +"%Y%m%d-%H%M%S")"
OUTPUT_DIR="$ROOT_DIR/release/ios/${VERSION}_${TIMESTAMP}"

mkdir -p "$OUTPUT_DIR"

"$FLUTTER_BIN" pub get
"$FLUTTER_BIN" build ipa \
  --release \
  --export-options-plist="$EXPORT_OPTIONS_PLIST" \
  --dart-define-from-file="$ENV_FILE"

find "$ROOT_DIR/build/ios/ipa" -name "*.ipa" -maxdepth 1 -print0 | while IFS= read -r -d '' file; do
  cp "$file" "$OUTPUT_DIR/$(basename "$file")"
done

if [[ -d "$ROOT_DIR/build/ios/archive/Runner.xcarchive" ]]; then
  ditto -c -k --sequesterRsrc --keepParent \
    "$ROOT_DIR/build/ios/archive/Runner.xcarchive" \
    "$OUTPUT_DIR/Runner.xcarchive.zip"
fi

cat > "$OUTPUT_DIR/release-info.txt" <<EOF
platform=ios
release_version=$RELEASE_VERSION
version=$VERSION
built_at=$TIMESTAMP
env_file=$ENV_FILE
export_options_plist=$EXPORT_OPTIONS_PLIST
git_commit=$(git -C "$ROOT_DIR" rev-parse --short HEAD)
EOF

echo "iOS release artifacts copied to:"
echo "$OUTPUT_DIR"
