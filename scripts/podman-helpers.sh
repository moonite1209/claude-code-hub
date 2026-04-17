#!/usr/bin/env bash

set -euo pipefail

PODMAN_BIN="${PODMAN_BIN:-podman}"
CCH_POSTGRES_RETRIES="${CCH_POSTGRES_RETRIES:-30}"
CCH_POSTGRES_INTERVAL="${CCH_POSTGRES_INTERVAL:-2}"
CCH_REDIS_RETRIES="${CCH_REDIS_RETRIES:-30}"
CCH_REDIS_INTERVAL="${CCH_REDIS_INTERVAL:-2}"
CCH_APP_RETRIES="${CCH_APP_RETRIES:-45}"
CCH_APP_INTERVAL="${CCH_APP_INTERVAL:-2}"
CCH_APP_INTERNAL_PORT="${CCH_APP_INTERNAL_PORT:-3000}"
CCH_CADDY_HTTP_PORT="${CCH_CADDY_HTTP_PORT:-8080}"
CCH_CADDY_HTTPS_PORT="${CCH_CADDY_HTTPS_PORT:-8443}"

cch_log_info() {
  printf '[INFO] %s\n' "$*"
}

cch_log_warn() {
  printf '[WARN] %s\n' "$*" >&2
}

cch_log_error() {
  printf '[ERROR] %s\n' "$*" >&2
}

cch_require_linux() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    cch_log_error "Official Podman workflow only supports Linux."
    return 1
  fi
}

cch_require_podman() {
  if ! command -v "${PODMAN_BIN}" >/dev/null 2>&1; then
    cch_log_error "Podman is required but was not found on PATH."
    return 1
  fi
}

cch_selinux_suffix() {
  local mode="${1:-private}"
  if command -v getenforce >/dev/null 2>&1; then
    local status
    status="$(getenforce 2>/dev/null || true)"
    if [[ "${status}" != "" && "${status}" != "Disabled" ]]; then
      if [[ "${mode}" == "shared" ]]; then
        printf ':z'
      else
        printf ':Z'
      fi
    fi
  fi
}

cch_bind_mount_arg() {
  local host_path="$1"
  local container_path="$2"
  local mode="${3:-private}"
  printf '%s:%s%s' "${host_path}" "${container_path}" "$(cch_selinux_suffix "${mode}")"
}

cch_emit_pod_ports() {
  local mode="$1"
  shift || true

  case "${mode}" in
    dev)
      local postgres_port="$1"
      local redis_port="$2"
      printf '%s\n' \
        "-p" "${postgres_port}:5432" \
        "-p" "${redis_port}:6379"
      ;;
    app)
      local app_port="$1"
      local enable_caddy="$2"
      local caddy_http_port="$3"
      local caddy_https_port="$4"
      if [[ "${enable_caddy}" == "true" ]]; then
        printf '%s\n' \
          "-p" "${caddy_http_port}:${caddy_http_port}" \
          "-p" "${caddy_https_port}:${caddy_https_port}"
      else
        printf '%s\n' "-p" "${app_port}:${CCH_APP_INTERNAL_PORT}"
      fi
      ;;
    *)
      cch_log_error "Unknown pod port mode: ${mode}"
      return 1
      ;;
  esac
}

cch_container_exists() {
  local name="$1"
  "${PODMAN_BIN}" container exists "${name}"
}

cch_pod_exists() {
  local name="$1"
  "${PODMAN_BIN}" pod exists "${name}"
}

cch_dump_logs() {
  local target="$1"
  "${PODMAN_BIN}" logs --tail 20 "${target}" 2>/dev/null || true
}

cch_wait_for_postgres() {
  local container="$1"
  local user="$2"
  local database="$3"
  local retries="${4:-${CCH_POSTGRES_RETRIES}}"
  local interval="${5:-${CCH_POSTGRES_INTERVAL}}"
  local attempt=1

  while [[ "${attempt}" -le "${retries}" ]]; do
    if "${PODMAN_BIN}" exec "${container}" pg_isready -U "${user}" -d "${database}" >/dev/null 2>&1; then
      return 0
    fi
    sleep "${interval}"
    attempt=$((attempt + 1))
  done

  cch_log_error "PostgreSQL did not become healthy within $((retries * interval)) seconds."
  cch_dump_logs "${container}"
  return 1
}

cch_wait_for_redis() {
  local container="$1"
  local retries="${2:-${CCH_REDIS_RETRIES}}"
  local interval="${3:-${CCH_REDIS_INTERVAL}}"
  local attempt=1

  while [[ "${attempt}" -le "${retries}" ]]; do
    if "${PODMAN_BIN}" exec "${container}" redis-cli ping >/dev/null 2>&1; then
      return 0
    fi
    sleep "${interval}"
    attempt=$((attempt + 1))
  done

  cch_log_error "Redis did not become healthy within $((retries * interval)) seconds."
  cch_dump_logs "${container}"
  return 1
}

cch_wait_for_host_http() {
  local url="$1"
  local label="$2"
  local log_target="$3"
  local retries="${4:-${CCH_APP_RETRIES}}"
  local interval="${5:-${CCH_APP_INTERVAL}}"
  local attempt=1

  while [[ "${attempt}" -le "${retries}" ]]; do
    if curl -fsS "${url}" >/dev/null 2>&1; then
      return 0
    fi
    sleep "${interval}"
    attempt=$((attempt + 1))
  done

  cch_log_error "${label} did not become healthy within $((retries * interval)) seconds."
  cch_dump_logs "${log_target}"
  return 1
}

cch_wait_for_container_http() {
  local container="$1"
  local url="$2"
  local label="$3"
  local retries="${4:-${CCH_APP_RETRIES}}"
  local interval="${5:-${CCH_APP_INTERVAL}}"
  local attempt=1

  while [[ "${attempt}" -le "${retries}" ]]; do
    if "${PODMAN_BIN}" exec "${container}" node -e "fetch(process.argv[1]).then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" "${url}" >/dev/null 2>&1; then
      return 0
    fi
    sleep "${interval}"
    attempt=$((attempt + 1))
  done

  cch_log_error "${label} did not become healthy within $((retries * interval)) seconds."
  cch_dump_logs "${container}"
  return 1
}

cch_namespace_chown() {
  local path="$1"
  local uid="$2"
  local gid="$3"
  mkdir -p "${path}"
  "${PODMAN_BIN}" unshare chown -R "${uid}:${gid}" "${path}"
}

cch_resolve_image_uid_gid() {
  local image="$1"
  local fallback_uid="$2"
  local fallback_gid="$3"
  local output

  if output="$("${PODMAN_BIN}" run --rm --entrypoint sh "${image}" -c 'id -u && id -g' 2>/dev/null)"; then
    local uid gid
    uid="$(printf '%s\n' "${output}" | sed -n '1p')"
    gid="$(printf '%s\n' "${output}" | sed -n '2p')"
    if [[ "${uid}" =~ ^[0-9]+$ && "${gid}" =~ ^[0-9]+$ ]]; then
      printf '%s:%s\n' "${uid}" "${gid}"
      return 0
    fi
  fi

  printf '%s:%s\n' "${fallback_uid}" "${fallback_gid}"
}
