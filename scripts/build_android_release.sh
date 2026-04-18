#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_BIN="${FLUTTER_BIN:-/Users/lcrh/Tools/flutter/bin/flutter}"
VERSION_HELPER="$ROOT_DIR/scripts/set_mobile_version.sh"
BUILD_ENV_HELPER="$ROOT_DIR/scripts/mobile_build_environment.sh"

if [[ $# -lt 2 ]]; then
  echo "Usage: bash scripts/build_android_release.sh <dev|prod> <version>"
  echo "Example: bash scripts/build_android_release.sh prod v0.1.0"
  exit 1
fi

BUILD_ENV="$1"
RELEASE_VERSION="$2"

if [[ ! -f "$BUILD_ENV_HELPER" ]]; then
  echo "Missing build environment helper: $BUILD_ENV_HELPER"
  exit 1
fi

# shellcheck disable=SC1090
source "$BUILD_ENV_HELPER"
load_mobile_build_environment "$ROOT_DIR" "$BUILD_ENV" "${ENV_FILE:-}"

if [[ ! -x "$VERSION_HELPER" ]]; then
  echo "Missing executable version helper: $VERSION_HELPER"
  exit 1
fi

cd "$ROOT_DIR"
bash "$VERSION_HELPER" "$RELEASE_VERSION"

VERSION="$(awk '/^version:/ {print $2; exit}' "$ROOT_DIR/pubspec.yaml")"
TIMESTAMP="$(date +"%Y%m%d-%H%M%S")"
OUTPUT_DIR="$ROOT_DIR/release/android/$BUILD_ENV/${VERSION}_${TIMESTAMP}"

mkdir -p "$OUTPUT_DIR"

"$FLUTTER_BIN" pub get
"$FLUTTER_BIN" build apk --release --dart-define-from-file="$JOBLENS_ENV_FILE"
"$FLUTTER_BIN" build appbundle --release --dart-define-from-file="$JOBLENS_ENV_FILE"

cp "$ROOT_DIR/build/app/outputs/flutter-apk/app-release.apk" \
  "$OUTPUT_DIR/joblens-$BUILD_ENV-${VERSION}-release.apk"
cp "$ROOT_DIR/build/app/outputs/bundle/release/app-release.aab" \
  "$OUTPUT_DIR/joblens-$BUILD_ENV-${VERSION}-release.aab"

cat > "$OUTPUT_DIR/release-info.txt" <<EOF
platform=android
build_env=$BUILD_ENV
release_version=$RELEASE_VERSION
version=$VERSION
built_at=$TIMESTAMP
env_file=$JOBLENS_ENV_FILE
supabase_url=$JOBLENS_EXPECTED_SUPABASE_URL
api_base_url=$JOBLENS_EXPECTED_API_BASE_URL
git_commit=$(git -C "$ROOT_DIR" rev-parse --short HEAD)
EOF

echo "Android release artifacts copied to:"
echo "$OUTPUT_DIR"
