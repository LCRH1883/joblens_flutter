#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAGMENTS_DIR="$ROOT_DIR/release/fragments"

if [[ $# -lt 3 ]]; then
  echo "Usage: bash scripts/new_release_fragment.sh <platforms> <type> <slug>"
  echo "Example: bash scripts/new_release_fragment.sh both feature auth-password-reset"
  exit 1
fi

PLATFORMS="$1"
TYPE="$2"
SLUG="$3"
TIMESTAMP="$(date +"%Y%m%d-%H%M%S")"
FILE_PATH="$FRAGMENTS_DIR/${TIMESTAMP}-${SLUG}.md"

case "$PLATFORMS" in
  android|ios|both) ;;
  *)
    echo "platforms must be one of: android, ios, both"
    exit 1
    ;;
esac

mkdir -p "$FRAGMENTS_DIR"

cat > "$FILE_PATH" <<EOF
platforms=$PLATFORMS
type=$TYPE
summary=
details=
EOF

echo "Created fragment:"
echo "$FILE_PATH"
