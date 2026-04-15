#!/bin/sh
set -eu

APP_FRAMEWORKS_DIR="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
ARCH_LIST="${ARCHS:-}"
DEBUG_INFO_FORMAT="${DEBUG_INFORMATION_FORMAT:-}"
DWARF_OUTPUT_DIR="${DWARF_DSYM_FOLDER_PATH:-}"

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

generate_framework_dsym() {
  framework_name="$1"
  binary_name="$2"
  binary_path="${APP_FRAMEWORKS_DIR}/${framework_name}.framework/${binary_name}"

  if [ "${DEBUG_INFO_FORMAT}" != "dwarf-with-dsym" ] || [ -z "${DWARF_OUTPUT_DIR}" ] || [ ! -f "${binary_path}" ]; then
    return 0
  fi

  dsym_path="${DWARF_OUTPUT_DIR}/${framework_name}.framework.dSYM"
  log_file="$(mktemp)"

  rm -rf "${dsym_path}"
  if ! dsymutil "${binary_path}" -o "${dsym_path}" 2>"${log_file}"; then
    cat "${log_file}" >&2
    rm -rf "${dsym_path}"
    rm -f "${log_file}"
    return 1
  fi

  rm -f "${log_file}"
}

process_framework() {
  framework_name="$1"
  binary_name="$2"
  thin_framework_binary "${APP_FRAMEWORKS_DIR}/${framework_name}.framework/${binary_name}"
  generate_framework_dsym "${framework_name}" "${binary_name}"
}

process_framework "objective_c" "objective_c"
process_framework "sqlite3" "sqlite3"
