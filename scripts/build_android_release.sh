#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_BIN="${FLUTTER_BIN:-/Users/lcrh/Tools/flutter/bin/flutter}"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE"
  exit 1
fi

VERSION="$(awk '/^version:/ {print $2; exit}' "$ROOT_DIR/pubspec.yaml")"
TIMESTAMP="$(date +"%Y%m%d-%H%M%S")"
OUTPUT_DIR="$ROOT_DIR/release/android/${VERSION}_${TIMESTAMP}"

mkdir -p "$OUTPUT_DIR"

cd "$ROOT_DIR"
"$FLUTTER_BIN" pub get
"$FLUTTER_BIN" build apk --release --dart-define-from-file="$ENV_FILE"
"$FLUTTER_BIN" build appbundle --release --dart-define-from-file="$ENV_FILE"

cp "$ROOT_DIR/build/app/outputs/flutter-apk/app-release.apk" \
  "$OUTPUT_DIR/joblens-${VERSION}-release.apk"
cp "$ROOT_DIR/build/app/outputs/bundle/release/app-release.aab" \
  "$OUTPUT_DIR/joblens-${VERSION}-release.aab"

cat > "$OUTPUT_DIR/release-info.txt" <<EOF
platform=android
version=$VERSION
built_at=$TIMESTAMP
env_file=$ENV_FILE
git_commit=$(git -C "$ROOT_DIR" rev-parse --short HEAD)
EOF

echo "Android release artifacts copied to:"
echo "$OUTPUT_DIR"
