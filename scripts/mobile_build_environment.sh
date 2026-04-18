#!/usr/bin/env bash

set -euo pipefail

resolve_mobile_build_contract() {
  local requested_env="$1"

  case "$requested_env" in
    dev)
      JOBLENS_EXPECTED_SUPABASE_URL="https://dev.joblens.xyz"
      JOBLENS_EXPECTED_API_BASE_URL="https://dev.joblens.xyz/functions/v1/api/v1"
      ;;
    prod)
      JOBLENS_EXPECTED_SUPABASE_URL="https://api.joblens.xyz"
      JOBLENS_EXPECTED_API_BASE_URL="https://api.joblens.xyz/functions/v1/api/v1"
      ;;
    *)
      echo "Unsupported build environment: $requested_env" >&2
      echo "Expected one of: dev, prod" >&2
      return 1
      ;;
  esac
}

load_mobile_build_environment() {
  local root_dir="$1"
  local requested_env="$2"
  local requested_env_file="${3:-}"

  resolve_mobile_build_contract "$requested_env"

  JOBLENS_BUILD_ENV="$requested_env"
  JOBLENS_ENV_FILE="${requested_env_file:-$root_dir/.env.$requested_env}"

  if [[ ! -f "$JOBLENS_ENV_FILE" ]]; then
    echo "Missing env file: $JOBLENS_ENV_FILE" >&2
    echo "Create $root_dir/.env.$requested_env from $root_dir/.env.$requested_env.example and add the real anon key." >&2
    return 1
  fi

  unset JOBLENS_ENV JOBLENS_APP_ENV SUPABASE_URL JOBLENS_SUPABASE_URL
  unset API_BASE_URL SUPABASE_ANON_KEY JOBLENS_SUPABASE_ANON_KEY

  set -a
  # shellcheck disable=SC1090
  source "$JOBLENS_ENV_FILE"
  set +a

  local resolved_env="${JOBLENS_ENV:-${JOBLENS_APP_ENV:-}}"
  local resolved_supabase_url="${SUPABASE_URL:-${JOBLENS_SUPABASE_URL:-}}"
  local resolved_api_base_url="${API_BASE_URL:-}"
  local resolved_anon_key="${SUPABASE_ANON_KEY:-${JOBLENS_SUPABASE_ANON_KEY:-}}"

  if [[ "$resolved_env" != "$requested_env" ]]; then
    echo "$JOBLENS_ENV_FILE must set JOBLENS_ENV=$requested_env" >&2
    return 1
  fi

  if [[ "$resolved_supabase_url" != "$JOBLENS_EXPECTED_SUPABASE_URL" ]]; then
    echo "$JOBLENS_ENV_FILE must set SUPABASE_URL=$JOBLENS_EXPECTED_SUPABASE_URL" >&2
    return 1
  fi

  if [[ "$resolved_api_base_url" != "$JOBLENS_EXPECTED_API_BASE_URL" ]]; then
    echo "$JOBLENS_ENV_FILE must set API_BASE_URL=$JOBLENS_EXPECTED_API_BASE_URL" >&2
    return 1
  fi

  if [[ -z "$resolved_anon_key" ]]; then
    echo "$JOBLENS_ENV_FILE must set SUPABASE_ANON_KEY (or JOBLENS_SUPABASE_ANON_KEY)" >&2
    return 1
  fi
}
