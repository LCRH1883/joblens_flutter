#!/bin/sh
set -eu

APP_ROOT="${SOURCE_ROOT}/.."
DART_TOOL_DIR="${APP_ROOT}/.dart_tool"

if [ ! -d "${DART_TOOL_DIR}" ]; then
  exit 0
fi

echo "Cleaning shared Dart native-asset cache for iOS build"

rm -rf \
  "${DART_TOOL_DIR}/hooks_runner/objective_c" \
  "${DART_TOOL_DIR}/hooks_runner/sqlite3" \
  "${DART_TOOL_DIR}/hooks_runner/shared/objective_c" \
  "${DART_TOOL_DIR}/hooks_runner/shared/sqlite3"

if [ -d "${DART_TOOL_DIR}/flutter_build" ]; then
  find "${DART_TOOL_DIR}/flutter_build" -type f \
    \( \
      -name native_assets.json -o \
      -name dart_build_result.json -o \
      -name dart_build.d -o \
      -name dart_build.stamp -o \
      -name install_code_assets.d -o \
      -name install_code_assets.stamp \
    \) -delete
fi
