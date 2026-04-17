#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/podman-helpers.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

VERSION="2.0.0"

log_info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
  echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
}

SUFFIX=""
ADMIN_TOKEN=""
DB_PASSWORD=""
DEPLOY_DIR="${HOME}/.local/share/claude-code-hub"
STATE_FILE=""
IMAGE_TAG="latest"
BRANCH_NAME="main"
APP_PORT="23000"
APP_INTERNAL_PORT="${CCH_APP_INTERNAL_PORT}"
CADDY_HTTP_PORT="${CCH_CADDY_HTTP_PORT}"
CADDY_HTTPS_PORT="${CCH_CADDY_HTTPS_PORT}"
UPDATE_MODE=false
FORCE_NEW=false
ENABLE_CADDY=false
NON_INTERACTIVE=false
APP_URL=""

BRANCH_ARG=""
PORT_ARG=""
TOKEN_ARG=""
DIR_ARG=""
DOMAIN_ARG=""
CADDY_HTTP_PORT_ARG=""
CADDY_HTTPS_PORT_ARG=""

POD_NAME=""
POSTGRES_CONTAINER=""
REDIS_CONTAINER=""
APP_CONTAINER=""
CADDY_CONTAINER=""

POSTGRES_IMAGE="postgres:18"
REDIS_IMAGE="redis:7-alpine"
APP_IMAGE=""
CADDY_IMAGE="caddy:2-alpine"

show_help() {
  cat <<EOF
Claude Code Hub - Podman One-Click Deployment Script v${VERSION}

Usage: $0 [OPTIONS]

Options:
  -b, --branch <name>            Branch to deploy: main (default) or dev
  -p, --port <port>              App external port without Caddy (default: 23000)
  -t, --admin-token <token>      Custom admin token (default: auto-generated)
  -d, --deploy-dir <path>        Custom deployment directory
      --domain <domain>          Domain for the optional Caddy proxy
      --enable-caddy             Enable the optional Caddy reverse proxy
      --caddy-http-port <port>   Caddy HTTP port (default: 8080)
      --caddy-https-port <port>  Caddy HTTPS port (default: 8443)
      --force-new                Force fresh installation (ignore existing deployment)
  -y, --yes                      Non-interactive mode (skip prompts, use defaults)
  -h, --help                     Show this help message

Examples:
  $0
  $0 -y
  $0 -b dev -p 24000 -y
  $0 --enable-caddy --caddy-http-port 18080 --caddy-https-port 18443 -y
  $0 --domain hub.example.com --enable-caddy -y

Official support target: Linux rootless Podman.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -b|--branch)
        BRANCH_ARG="${2:-}"
        shift 2
        ;;
      -p|--port)
        PORT_ARG="${2:-}"
        shift 2
        ;;
      -t|--admin-token)
        TOKEN_ARG="${2:-}"
        shift 2
        ;;
      -d|--deploy-dir)
        DIR_ARG="${2:-}"
        shift 2
        ;;
      --domain)
        DOMAIN_ARG="${2:-}"
        ENABLE_CADDY=true
        shift 2
        ;;
      --enable-caddy)
        ENABLE_CADDY=true
        shift
        ;;
      --caddy-http-port)
        CADDY_HTTP_PORT_ARG="${2:-}"
        shift 2
        ;;
      --caddy-https-port)
        CADDY_HTTPS_PORT_ARG="${2:-}"
        shift 2
        ;;
      --force-new)
        FORCE_NEW=true
        shift
        ;;
      -y|--yes)
        NON_INTERACTIVE=true
        shift
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      *)
        log_error "Unknown option: $1"
        show_help
        exit 1
        ;;
    esac
  done
}

validate_port() {
  local value="$1"
  local label="$2"
  if ! [[ "${value}" =~ ^[0-9]+$ ]] || [[ "${value}" -lt 1 ]] || [[ "${value}" -gt 65535 ]]; then
    log_error "Invalid ${label}: ${value}"
    exit 1
  fi
}

validate_inputs() {
  if [[ -n "${PORT_ARG}" ]]; then
    validate_port "${PORT_ARG}" "port"
    APP_PORT="${PORT_ARG}"
  fi

  if [[ -n "${CADDY_HTTP_PORT_ARG}" ]]; then
    validate_port "${CADDY_HTTP_PORT_ARG}" "Caddy HTTP port"
    CADDY_HTTP_PORT="${CADDY_HTTP_PORT_ARG}"
  fi

  if [[ -n "${CADDY_HTTPS_PORT_ARG}" ]]; then
    validate_port "${CADDY_HTTPS_PORT_ARG}" "Caddy HTTPS port"
    CADDY_HTTPS_PORT="${CADDY_HTTPS_PORT_ARG}"
  fi

  if [[ -n "${TOKEN_ARG}" ]]; then
    if [[ ${#TOKEN_ARG} -lt 16 ]]; then
      log_error "Admin token too short: minimum 16 characters required"
      exit 1
    fi
    ADMIN_TOKEN="${TOKEN_ARG}"
  fi

  if [[ -n "${DIR_ARG}" ]]; then
    DEPLOY_DIR="${DIR_ARG}"
  fi

  if [[ -n "${BRANCH_ARG}" ]]; then
    case "${BRANCH_ARG}" in
      main)
        IMAGE_TAG="latest"
        BRANCH_NAME="main"
        ;;
      dev)
        IMAGE_TAG="dev"
        BRANCH_NAME="dev"
        ;;
      *)
        log_error "Invalid branch: ${BRANCH_ARG}"
        exit 1
        ;;
    esac
  fi

  if [[ -n "${DOMAIN_ARG}" ]]; then
    if ! [[ "${DOMAIN_ARG}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
      log_error "Invalid domain format: ${DOMAIN_ARG}"
      exit 1
    fi
  fi
}

print_header() {
  echo -e "${BLUE}"
  echo "+=================================================================+"
  echo "|                                                                 |"
  echo "|         Claude Code Hub - Podman Deployment Script             |"
  echo "|                      Version ${VERSION}                             |"
  echo "|                                                                 |"
  echo "+=================================================================+"
  echo -e "${NC}"
}

check_environment() {
  cch_require_linux
  cch_require_podman

  if ! "${PODMAN_BIN}" info --format '{{.Host.Security.Rootless}}' 2>/dev/null | grep -q '^true$'; then
    log_error "This script only supports rootless Podman."
    exit 1
  fi
}

select_branch() {
  if [[ -n "${BRANCH_ARG}" ]]; then
    return
  fi

  if [[ "${NON_INTERACTIVE}" == true ]]; then
    return
  fi

  echo ""
  echo -e "${BLUE}Please select the branch to deploy:${NC}"
  echo -e "  ${GREEN}1)${NC} main   (Stable release - recommended for production)"
  echo -e "  ${YELLOW}2)${NC} dev    (Latest features - for testing)"
  echo ""

  local choice
  while true; do
    read -r -p "Enter your choice [1]: " choice
    choice="${choice:-1}"
    case "${choice}" in
      1)
        IMAGE_TAG="latest"
        BRANCH_NAME="main"
        return
        ;;
      2)
        IMAGE_TAG="dev"
        BRANCH_NAME="dev"
        return
        ;;
      *)
        log_error "Invalid choice. Please enter 1 or 2."
        ;;
    esac
  done
}

generate_random_suffix() {
  SUFFIX="$(tr -dc 'a-z0-9' < /dev/urandom | head -c 4)"
}

generate_admin_token() {
  if [[ -n "${ADMIN_TOKEN}" ]]; then
    return
  fi
  if command -v openssl >/dev/null 2>&1; then
    ADMIN_TOKEN="$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)"
  else
    ADMIN_TOKEN="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)"
  fi
}

generate_db_password() {
  if [[ -n "${DB_PASSWORD}" ]]; then
    return
  fi
  if command -v openssl >/dev/null 2>&1; then
    DB_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
  else
    DB_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)"
  fi
}

set_runtime_names() {
  POD_NAME="claude-code-hub-${SUFFIX}"
  POSTGRES_CONTAINER="claude-code-hub-db-${SUFFIX}"
  REDIS_CONTAINER="claude-code-hub-redis-${SUFFIX}"
  APP_CONTAINER="claude-code-hub-app-${SUFFIX}"
  CADDY_CONTAINER="claude-code-hub-caddy-${SUFFIX}"
  APP_IMAGE="ghcr.io/ding113/claude-code-hub:${IMAGE_TAG}"
  STATE_FILE="${DEPLOY_DIR}/.podman-state"
}

detect_existing_deployment() {
  if [[ "${FORCE_NEW}" == true ]]; then
    return 1
  fi

  if [[ -f "${DEPLOY_DIR}/.env" && -f "${DEPLOY_DIR}/.podman-state" ]]; then
    UPDATE_MODE=true
    return 0
  fi

  return 1
}

load_state_file() {
  source "${DEPLOY_DIR}/.podman-state"
}

load_existing_config() {
  load_state_file
  SUFFIX="${SUFFIX:-${STATE_SUFFIX:-}}"
  POD_NAME="${POD_NAME:-claude-code-hub-${SUFFIX}}"
  POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-claude-code-hub-db-${SUFFIX}}"
  REDIS_CONTAINER="${REDIS_CONTAINER:-claude-code-hub-redis-${SUFFIX}}"
  APP_CONTAINER="${APP_CONTAINER:-claude-code-hub-app-${SUFFIX}}"
  CADDY_CONTAINER="${CADDY_CONTAINER:-claude-code-hub-caddy-${SUFFIX}}"

  if [[ -f "${DEPLOY_DIR}/.env" ]]; then
    local existing_db_pw existing_token existing_app_port existing_http_port existing_https_port
    existing_db_pw="$(grep '^DB_PASSWORD=' "${DEPLOY_DIR}/.env" | head -1 | cut -d'=' -f2-)"
    existing_token="$(grep '^ADMIN_TOKEN=' "${DEPLOY_DIR}/.env" | head -1 | cut -d'=' -f2-)"
    existing_app_port="$(grep '^APP_PORT=' "${DEPLOY_DIR}/.env" | head -1 | cut -d'=' -f2-)"
    existing_http_port="$(grep '^CADDY_HTTP_PORT=' "${DEPLOY_DIR}/.env" | head -1 | cut -d'=' -f2-)"
    existing_https_port="$(grep '^CADDY_HTTPS_PORT=' "${DEPLOY_DIR}/.env" | head -1 | cut -d'=' -f2-)"
    DB_PASSWORD="${DB_PASSWORD:-${existing_db_pw}}"
    ADMIN_TOKEN="${ADMIN_TOKEN:-${existing_token}}"
    APP_PORT="${PORT_ARG:-${existing_app_port:-${APP_PORT}}}"
    CADDY_HTTP_PORT="${CADDY_HTTP_PORT_ARG:-${existing_http_port:-${CADDY_HTTP_PORT}}}"
    CADDY_HTTPS_PORT="${CADDY_HTTPS_PORT_ARG:-${existing_https_port:-${CADDY_HTTPS_PORT}}}"
  fi
}

create_deployment_dir() {
  mkdir -p "${DEPLOY_DIR}/data/postgres" "${DEPLOY_DIR}/data/redis"
  if [[ "${ENABLE_CADDY}" == true ]]; then
    mkdir -p "${DEPLOY_DIR}/data/caddy-data" "${DEPLOY_DIR}/data/caddy-config"
  fi
}

prepare_bind_mount_ownership() {
  cch_namespace_chown "${DEPLOY_DIR}/data/postgres" 999 999

  local redis_ids
  redis_ids="$(cch_resolve_image_uid_gid "${REDIS_IMAGE}" 999 999)"
  cch_namespace_chown "${DEPLOY_DIR}/data/redis" "${redis_ids%%:*}" "${redis_ids##*:}"

  if [[ "${ENABLE_CADDY}" == true ]]; then
    local caddy_ids
    caddy_ids="$(cch_resolve_image_uid_gid "${CADDY_IMAGE}" 1000 1000)"
    cch_namespace_chown "${DEPLOY_DIR}/data/caddy-data" "${caddy_ids%%:*}" "${caddy_ids##*:}"
    cch_namespace_chown "${DEPLOY_DIR}/data/caddy-config" "${caddy_ids%%:*}" "${caddy_ids##*:}"
  fi
}

write_env_file() {
  local secure_cookies="true"
  if [[ "${ENABLE_CADDY}" == true ]]; then
    if [[ -n "${DOMAIN_ARG}" ]]; then
      APP_URL="https://${DOMAIN_ARG}:${CADDY_HTTPS_PORT}"
    fi
  elif [[ -z "${APP_URL}" ]]; then
    APP_URL="http://127.0.0.1:${APP_PORT}"
  fi

  cat > "${DEPLOY_DIR}/.env" <<EOF
ADMIN_TOKEN=${ADMIN_TOKEN}
DB_USER=postgres
DB_PASSWORD=${DB_PASSWORD}
DB_NAME=claude_code_hub
APP_PORT=${APP_PORT}
APP_URL=${APP_URL}
AUTO_MIGRATE=true
ENABLE_RATE_LIMIT=true
SESSION_TTL=300
STORE_SESSION_MESSAGES=false
STORE_SESSION_RESPONSE_BODY=true
ENABLE_SECURE_COOKIES=${secure_cookies}
ENABLE_CIRCUIT_BREAKER_ON_NETWORK_ERRORS=false
ENABLE_ENDPOINT_CIRCUIT_BREAKER=false
NODE_ENV=production
TZ=Asia/Shanghai
LOG_LEVEL=info
CADDY_HTTP_PORT=${CADDY_HTTP_PORT}
CADDY_HTTPS_PORT=${CADDY_HTTPS_PORT}
EOF

  chmod 600 "${DEPLOY_DIR}/.env"
}

write_state_file() {
  cat > "${DEPLOY_DIR}/.podman-state" <<EOF
DEPLOY_DIR=${DEPLOY_DIR}
SUFFIX=${SUFFIX}
STATE_SUFFIX=${SUFFIX}
POD_NAME=${POD_NAME}
POSTGRES_CONTAINER=${POSTGRES_CONTAINER}
REDIS_CONTAINER=${REDIS_CONTAINER}
APP_CONTAINER=${APP_CONTAINER}
CADDY_CONTAINER=${CADDY_CONTAINER}
IMAGE_TAG=${IMAGE_TAG}
BRANCH_NAME=${BRANCH_NAME}
APP_PORT=${APP_PORT}
CADDY_HTTP_PORT=${CADDY_HTTP_PORT}
CADDY_HTTPS_PORT=${CADDY_HTTPS_PORT}
ENABLE_CADDY=${ENABLE_CADDY}
DOMAIN_ARG=${DOMAIN_ARG}
EOF
}

write_caddyfile() {
  if [[ "${ENABLE_CADDY}" != true ]]; then
    return
  fi

  local http_host=":${CADDY_HTTP_PORT}"
  local https_host=":${CADDY_HTTPS_PORT}"
  if [[ -n "${DOMAIN_ARG}" ]]; then
    http_host="${DOMAIN_ARG}:${CADDY_HTTP_PORT}"
    https_host="${DOMAIN_ARG}:${CADDY_HTTPS_PORT}"
  fi

  cat > "${DEPLOY_DIR}/Caddyfile" <<EOF
${http_host} {
    reverse_proxy 127.0.0.1:${APP_INTERNAL_PORT}
    encode gzip
}

${https_host} {
    tls internal
    reverse_proxy 127.0.0.1:${APP_INTERNAL_PORT}
    encode gzip
}
EOF
}

remove_existing_pod() {
  if cch_pod_exists "${POD_NAME}"; then
    "${PODMAN_BIN}" pod rm -f "${POD_NAME}" >/dev/null 2>&1 || true
  fi
}

create_pod() {
  remove_existing_pod
  mapfile -t pod_port_args < <(cch_emit_pod_ports app "${APP_PORT}" "${ENABLE_CADDY}" "${CADDY_HTTP_PORT}" "${CADDY_HTTPS_PORT}")
  "${PODMAN_BIN}" pod create --name "${POD_NAME}" "${pod_port_args[@]}" >/dev/null
}

create_postgres_container() {
  "${PODMAN_BIN}" run -d \
    --name "${POSTGRES_CONTAINER}" \
    --pod "${POD_NAME}" \
    --env-file "${DEPLOY_DIR}/.env" \
    -e "POSTGRES_USER=postgres" \
    -e "POSTGRES_PASSWORD=${DB_PASSWORD}" \
    -e "POSTGRES_DB=claude_code_hub" \
    -e "PGDATA=/data/pgdata" \
    -e "TZ=Asia/Shanghai" \
    -e "PGTZ=Asia/Shanghai" \
    -v "$(cch_bind_mount_arg "${DEPLOY_DIR}/data/postgres" "/data" private)" \
    "${POSTGRES_IMAGE}" >/dev/null
}

create_redis_container() {
  "${PODMAN_BIN}" run -d \
    --name "${REDIS_CONTAINER}" \
    --pod "${POD_NAME}" \
    -v "$(cch_bind_mount_arg "${DEPLOY_DIR}/data/redis" "/data" private)" \
    "${REDIS_IMAGE}" \
    redis-server --appendonly yes >/dev/null
}

create_app_container() {
  "${PODMAN_BIN}" run -d \
    --name "${APP_CONTAINER}" \
    --pod "${POD_NAME}" \
    --env-file "${DEPLOY_DIR}/.env" \
    -e NODE_ENV=production \
    -e PORT="${APP_INTERNAL_PORT}" \
    -e DSN="postgresql://postgres:${DB_PASSWORD}@127.0.0.1:5432/claude_code_hub" \
    -e REDIS_URL="redis://127.0.0.1:6379" \
    -e TZ=Asia/Shanghai \
    "${APP_IMAGE}" >/dev/null
}

create_caddy_container() {
  if [[ "${ENABLE_CADDY}" != true ]]; then
    return
  fi

  "${PODMAN_BIN}" run -d \
    --name "${CADDY_CONTAINER}" \
    --pod "${POD_NAME}" \
    -v "$(cch_bind_mount_arg "${DEPLOY_DIR}/Caddyfile" "/etc/caddy/Caddyfile" private)" \
    -v "$(cch_bind_mount_arg "${DEPLOY_DIR}/data/caddy-data" "/data" private)" \
    -v "$(cch_bind_mount_arg "${DEPLOY_DIR}/data/caddy-config" "/config" private)" \
    "${CADDY_IMAGE}" >/dev/null
}

wait_for_health() {
  cch_wait_for_postgres "${POSTGRES_CONTAINER}" "postgres" "claude_code_hub"
  cch_wait_for_redis "${REDIS_CONTAINER}"
  cch_wait_for_container_http "${APP_CONTAINER}" "http://127.0.0.1:${APP_INTERNAL_PORT}/api/actions/health" "App"
  if [[ "${ENABLE_CADDY}" == true ]]; then
    cch_wait_for_host_http "http://127.0.0.1:${CADDY_HTTP_PORT}/api/actions/health" "Caddy proxy" "${CADDY_CONTAINER}"
  else
    cch_wait_for_host_http "http://127.0.0.1:${APP_PORT}/api/actions/health" "App" "${APP_CONTAINER}"
  fi
}

start_services() {
  log_info "Creating Podman pod and containers..."
  create_pod
  create_postgres_container
  create_redis_container
  create_app_container
  create_caddy_container
  wait_for_health
  log_success "Deployment completed successfully"
}

print_summary() {
  echo ""
  log_success "Claude Code Hub is ready"
  if [[ "${ENABLE_CADDY}" == true ]]; then
    echo -e "  HTTP:  ${GREEN}http://127.0.0.1:${CADDY_HTTP_PORT}${NC}"
    echo -e "  HTTPS: ${GREEN}https://127.0.0.1:${CADDY_HTTPS_PORT}${NC}"
    if [[ -n "${DOMAIN_ARG}" ]]; then
      echo -e "  Domain: ${GREEN}${DOMAIN_ARG}${NC}"
      log_warning "Rootless high-port Caddy uses high ports only; HTTP-01 ACME is not available."
    fi
  else
    echo -e "  App: ${GREEN}http://127.0.0.1:${APP_PORT}${NC}"
  fi
  echo -e "  Admin Token: ${YELLOW}${ADMIN_TOKEN}${NC}"
  echo ""
  echo "Useful commands:"
  echo -e "  Logs:    ${YELLOW}podman pod logs -f ${POD_NAME}${NC}"
  echo -e "  Stop:    ${YELLOW}podman pod stop ${POD_NAME}${NC}"
  echo -e "  Start:   ${YELLOW}podman pod start ${POD_NAME}${NC}"
  echo -e "  Restart: ${YELLOW}podman pod restart ${POD_NAME}${NC}"
  echo -e "  Remove:  ${YELLOW}podman pod rm -f ${POD_NAME}${NC}"
  echo ""
}

main() {
  print_header
  parse_args "$@"
  validate_inputs
  check_environment
  select_branch

  if detect_existing_deployment; then
    log_info "Existing Podman deployment detected in ${DEPLOY_DIR}"
    load_existing_config
  else
    generate_random_suffix
  fi

  generate_admin_token
  generate_db_password
  set_runtime_names
  create_deployment_dir
  prepare_bind_mount_ownership
  write_env_file
  write_state_file
  write_caddyfile
  start_services
  print_summary
}

main "$@"
