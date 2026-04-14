#!/bin/sh
set -eu

APP_ROOT="${SOURCE_ROOT}/.."
DART_TOOL_DIR="${APP_ROOT}/.dart_tool"

if [ ! -d "${DART_TOOL_DIR}" ]; then
  exit 0
fi

echo "Cleaning shared Dart native-asset cache for iOS build"

rm -rf \
  "${DART_TOOL_DIR}/hooks_runner/shared/objective_c" \
  "${DART_TOOL_DIR}/hooks_runner/shared/sqlite3"

if [ -d "${DART_TOOL_DIR}/flutter_build" ]; then
  find "${DART_TOOL_DIR}/flutter_build" -name native_assets.json -delete
fi
