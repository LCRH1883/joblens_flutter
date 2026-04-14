#!/bin/sh
set -eu

APP_FRAMEWORKS_DIR="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
ARCH_LIST="${ARCHS:-}"

if [ -z "${ARCH_LIST}" ] || [ ! -d "${APP_FRAMEWORKS_DIR}" ]; then
  exit 0
fi

thin_framework_binary() {
  binary_path="$1"
  if [ ! -f "${binary_path}" ]; then
    return 0
  fi

  info="$(lipo -info "${binary_path}" 2>/dev/null || true)"
  if [ -z "${info}" ]; then
    return 0
  fi

  temp_dir="$(mktemp -d)"
  trap 'rm -rf "${temp_dir}"' EXIT HUP INT TERM

  extracted=0
  for arch in ${ARCH_LIST}; do
    if lipo -info "${binary_path}" | grep -qw "${arch}"; then
      lipo "${binary_path}" -extract "${arch}" -output "${temp_dir}/${arch}"
      extracted=$((extracted + 1))
    fi
  done

  if [ "${extracted}" -eq 0 ]; then
    rm -rf "${temp_dir}"
    trap - EXIT HUP INT TERM
    return 0
  fi

  if [ "${extracted}" -eq 1 ]; then
    cp "${temp_dir}"/* "${binary_path}"
  else
    lipo -create "${temp_dir}"/* -output "${binary_path}"
  fi

  rm -rf "${temp_dir}"
  trap - EXIT HUP INT TERM
}

thin_framework_binary "${APP_FRAMEWORKS_DIR}/objective_c.framework/objective_c"
thin_framework_binary "${APP_FRAMEWORKS_DIR}/sqlite3.framework/sqlite3"
