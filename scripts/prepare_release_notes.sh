#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAGMENTS_DIR="$ROOT_DIR/release/fragments"
ANDROID_CHANGELOG="$ROOT_DIR/release/android/CHANGELOG.md"
IOS_CHANGELOG="$ROOT_DIR/release/ios/CHANGELOG.md"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if [[ $# -lt 1 ]]; then
  echo "Usage: bash scripts/prepare_release_notes.sh <version>"
  echo "Example: bash scripts/prepare_release_notes.sh v0.1.1"
  exit 1
fi

VERSION="$1"

if [[ ! -d "$FRAGMENTS_DIR" ]]; then
  echo "Missing fragments directory: $FRAGMENTS_DIR"
  exit 1
fi

ANDROID_BODY="$TMP_DIR/android-body.md"
IOS_BODY="$TMP_DIR/ios-body.md"
: > "$ANDROID_BODY"
: > "$IOS_BODY"

append_fragment() {
  local target_file="$1"
  local type="$2"
  local summary="$3"
  local details="$4"

  if [[ -z "$summary" ]]; then
    return
  fi

  printf -- "- %s" "$summary" >> "$target_file"
  printf '\n' >> "$target_file"

  if [[ -n "$details" ]]; then
    while IFS= read -r detail_line; do
      [[ -z "$detail_line" ]] && continue
      printf -- "  %s\n" "$detail_line" >> "$target_file"
    done <<< "$details"
  fi
}

while IFS= read -r fragment; do
  [[ -f "$fragment" ]] || continue

  platforms="$(sed -n 's/^platforms=//p' "$fragment" | head -n1 | tr -d '\r')"
  type="$(sed -n 's/^type=//p' "$fragment" | head -n1 | tr -d '\r')"
  summary="$(sed -n 's/^summary=//p' "$fragment" | head -n1 | tr -d '\r')"
  details="$(sed -n 's/^details=//p' "$fragment" | head -n1 | tr -d '\r' | sed 's/\\n/\n/g')"

  case "$platforms" in
    both)
      append_fragment "$ANDROID_BODY" "$type" "$summary" "$details"
      append_fragment "$IOS_BODY" "$type" "$summary" "$details"
      ;;
    android)
      append_fragment "$ANDROID_BODY" "$type" "$summary" "$details"
      ;;
    ios)
      append_fragment "$IOS_BODY" "$type" "$summary" "$details"
      ;;
    *)
      echo "Skipping invalid fragment platforms in $fragment"
      ;;
  esac
done < <(find "$FRAGMENTS_DIR" -maxdepth 1 -type f -name '*.md' ! -name 'README.md' | sort)

prepend_section() {
  local changelog_file="$1"
  local body_file="$2"
  local temp_output="$TMP_DIR/$(basename "$changelog_file").out"

  awk -v version="$VERSION" -v body_file="$body_file" '
    BEGIN {
      inserted = 0
      while ((getline line < body_file) > 0) {
        body = body line "\n"
      }
      close(body_file)
    }
    /^## / && inserted == 0 {
      printf "\n## %s\n\n", version
      if (length(body) > 0) {
        printf "%s", body
      } else {
        printf "- No platform-specific release notes were recorded for this version.\n"
      }
      printf "\n"
      inserted = 1
    }
    {
      print
    }
    END {
      if (inserted == 0) {
        printf "\n## %s\n\n", version
        if (length(body) > 0) {
          printf "%s", body
        } else {
          printf "- No platform-specific release notes were recorded for this version.\n"
        }
        printf "\n"
      }
    }
  ' "$changelog_file" > "$temp_output"

  mv "$temp_output" "$changelog_file"
}

prepend_section "$ANDROID_CHANGELOG" "$ANDROID_BODY"
prepend_section "$IOS_CHANGELOG" "$IOS_BODY"

echo "Prepared release notes for $VERSION"
echo "Updated:"
echo "$ANDROID_CHANGELOG"
echo "$IOS_CHANGELOG"
echo
echo "Review the generated changelog entries, then archive or remove used fragments from:"
echo "$FRAGMENTS_DIR"
