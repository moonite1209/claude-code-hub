#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/podman-helpers.sh"

PROJECT_NAME="${PROJECT_NAME:-cch-dev}"
DB_USER="${DB_USER:-postgres}"
DB_PASSWORD="${DB_PASSWORD:-postgres}"
DB_NAME="${DB_NAME:-claude_code_hub}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
REDIS_PORT="${REDIS_PORT:-6379}"
APP_PORT="${APP_PORT:-23000}"
ADMIN_TOKEN="${ADMIN_TOKEN:-cch-dev-admin}"
APP_VERSION="${APP_VERSION:-dev}"
ENABLE_RATE_LIMIT="${ENABLE_RATE_LIMIT:-true}"
POSTGRES_HOST="${POSTGRES_HOST:-127.0.0.1}"
REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
POD_NAME="${POD_NAME:-${PROJECT_NAME}}"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-${PROJECT_NAME}-postgres}"
REDIS_CONTAINER="${REDIS_CONTAINER:-${PROJECT_NAME}-redis}"
APP_CONTAINER="${APP_CONTAINER:-${PROJECT_NAME}-app}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:18}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:7-alpine}"
APP_IMAGE="${APP_IMAGE:-claude-code-hub-local:${APP_VERSION}}"
POSTGRES_DATA_DIR="${POSTGRES_DATA_DIR:-${REPO_ROOT}/data/postgres-dev}"
REDIS_DATA_DIR="${REDIS_DATA_DIR:-${REPO_ROOT}/data/redis-dev}"
ENABLE_CADDY="false"
LOCAL_DSN="${LOCAL_DSN:-postgres://${DB_USER}:${DB_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${DB_NAME}}"
LOCAL_REDIS_URL="${LOCAL_REDIS_URL:-redis://${REDIS_HOST}:${REDIS_PORT}}"

prepare_data_dirs() {
  mkdir -p "${POSTGRES_DATA_DIR}" "${REDIS_DATA_DIR}"
  cch_namespace_chown "${POSTGRES_DATA_DIR}" 999 999

  local redis_ids
  redis_ids="$(cch_resolve_image_uid_gid "${REDIS_IMAGE}" 999 999)"
  cch_namespace_chown "${REDIS_DATA_DIR}" "${redis_ids%%:*}" "${redis_ids##*:}"
}

ensure_db_pod() {
  if ! cch_pod_exists "${POD_NAME}"; then
    mapfile -t pod_port_args < <(cch_emit_pod_ports dev "${POSTGRES_PORT}" "${REDIS_PORT}")
    "${PODMAN_BIN}" pod create --name "${POD_NAME}" "${pod_port_args[@]}" >/dev/null
  fi
}

ensure_postgres_container() {
  if ! cch_container_exists "${POSTGRES_CONTAINER}"; then
    "${PODMAN_BIN}" run -d \
      --name "${POSTGRES_CONTAINER}" \
      --pod "${POD_NAME}" \
      -e "POSTGRES_USER=${DB_USER}" \
      -e "POSTGRES_PASSWORD=${DB_PASSWORD}" \
      -e "POSTGRES_DB=${DB_NAME}" \
      -e "PGDATA=/data/pgdata" \
      -e "TZ=Asia/Shanghai" \
      -e "PGTZ=Asia/Shanghai" \
      -v "$(cch_bind_mount_arg "${POSTGRES_DATA_DIR}" "/data" private)" \
      "${POSTGRES_IMAGE}" >/dev/null
  else
    "${PODMAN_BIN}" start "${POSTGRES_CONTAINER}" >/dev/null 2>&1 || true
  fi
}

ensure_redis_container() {
  if ! cch_container_exists "${REDIS_CONTAINER}"; then
    "${PODMAN_BIN}" run -d \
      --name "${REDIS_CONTAINER}" \
      --pod "${POD_NAME}" \
      -v "$(cch_bind_mount_arg "${REDIS_DATA_DIR}" "/data" private)" \
      "${REDIS_IMAGE}" \
      redis-server --appendonly yes >/dev/null
  else
    "${PODMAN_BIN}" start "${REDIS_CONTAINER}" >/dev/null 2>&1 || true
  fi
}

wait_for_db_services() {
  cch_wait_for_postgres "${POSTGRES_CONTAINER}" "${DB_USER}" "${DB_NAME}"
  cch_wait_for_redis "${REDIS_CONTAINER}"
}

remove_app_container() {
  if cch_container_exists "${APP_CONTAINER}"; then
    "${PODMAN_BIN}" rm -f "${APP_CONTAINER}" >/dev/null 2>&1 || true
  fi
}

create_app_container() {
  remove_app_container
  "${PODMAN_BIN}" run -d \
    --name "${APP_CONTAINER}" \
    --pod "${POD_NAME}" \
    -e NODE_ENV=production \
    -e PORT="${CCH_APP_INTERNAL_PORT}" \
    -e DSN="postgresql://${DB_USER}:${DB_PASSWORD}@127.0.0.1:5432/${DB_NAME}" \
    -e REDIS_URL="redis://127.0.0.1:6379" \
    -e AUTO_MIGRATE=true \
    -e ENABLE_RATE_LIMIT="${ENABLE_RATE_LIMIT}" \
    -e SESSION_TTL=300 \
    -e ADMIN_TOKEN="${ADMIN_TOKEN}" \
    -e TZ=Asia/Shanghai \
    "${APP_IMAGE}" >/dev/null
}

ensure_dev_stack() {
  cch_require_linux
  cch_require_podman
  prepare_data_dirs
  ensure_db_pod
  ensure_postgres_container
  ensure_redis_container
  wait_for_db_services
}

build_image() {
  cch_require_linux
  cch_require_podman
  "${PODMAN_BIN}" build \
    -f "${REPO_ROOT}/deploy/Dockerfile" \
    --build-arg "APP_VERSION=${APP_VERSION}" \
    -t "${APP_IMAGE}" \
    "${REPO_ROOT}"
}

build_image_no_cache() {
  cch_require_linux
  cch_require_podman
  "${PODMAN_BIN}" build \
    --no-cache \
    -f "${REPO_ROOT}/deploy/Dockerfile" \
    --build-arg "APP_VERSION=${APP_VERSION}" \
    -t "${APP_IMAGE}" \
    "${REPO_ROOT}"
}

cmd_help() {
  cat <<EOF

Claude Code Hub - Podman dev 工具链

常用命令:
  make db          启动 PostgreSQL + Redis（Podman）
  make dev         启动 db/redis 后运行 bun dev（连接 Podman db/redis）
  make app         本地构建并启动 app 容器 + db + redis
  make build       仅本地构建 app 镜像
  make app-rebuild 强制重建并重建 app 容器
  make app-nocache 无缓存重建 app 镜像并重建容器
  make prune-images 清理悬空镜像
  make rm-app-image 删除本地 app 镜像标签（claude-code-hub-local:*）
  make logs        查看 pod 日志
  make status      查看 pod 和容器状态
  make clean       停止并删除 pod（保留数据）
  make reset       停止并删除 pod 与数据（危险操作）

可覆盖环境变量:
  PROJECT_NAME=${PROJECT_NAME}
  DB_USER=${DB_USER} DB_PASSWORD=${DB_PASSWORD} DB_NAME=${DB_NAME}
  POSTGRES_PORT=${POSTGRES_PORT} REDIS_PORT=${REDIS_PORT} APP_PORT=${APP_PORT}
  ADMIN_TOKEN=${ADMIN_TOKEN} APP_VERSION=${APP_VERSION} ENABLE_RATE_LIMIT=${ENABLE_RATE_LIMIT}

本机 dev 默认连接串:
  DSN=${LOCAL_DSN}
  REDIS_URL=${LOCAL_REDIS_URL}

EOF
}

cmd_db() {
  ensure_dev_stack
  cmd_status
}

cmd_dev() {
  ensure_dev_stack
  echo ""
  echo "Running bun dev with:"
  echo "  DSN=${LOCAL_DSN}"
  echo "  REDIS_URL=${LOCAL_REDIS_URL}"
  echo ""
  cd "${REPO_ROOT}"
  DSN="${LOCAL_DSN}" \
    REDIS_URL="${LOCAL_REDIS_URL}" \
    ENABLE_RATE_LIMIT="${ENABLE_RATE_LIMIT}" \
    ADMIN_TOKEN="${ADMIN_TOKEN}" \
    PG_CONTAINER_EXEC="${PODMAN_BIN} exec ${POSTGRES_CONTAINER}" \
    bun run dev
}

cmd_build() {
  build_image
}

cmd_build_nocache() {
  build_image_no_cache
}

cmd_app() {
  ensure_dev_stack
  build_image
  create_app_container
  cch_wait_for_host_http "http://127.0.0.1:${APP_PORT}/api/actions/health" "App" "${APP_CONTAINER}"
  cmd_status
  echo ""
  echo "App is starting. Visit: http://localhost:${APP_PORT}"
  echo ""
}

cmd_app_rebuild() {
  ensure_dev_stack
  build_image
  create_app_container
  cch_wait_for_host_http "http://127.0.0.1:${APP_PORT}/api/actions/health" "App" "${APP_CONTAINER}"
  cmd_status
}

cmd_app_nocache() {
  ensure_dev_stack
  build_image_no_cache
  create_app_container
  cch_wait_for_host_http "http://127.0.0.1:${APP_PORT}/api/actions/health" "App" "${APP_CONTAINER}"
  cmd_status
}

cmd_prune_images() {
  cch_require_podman
  "${PODMAN_BIN}" image prune -f
}

cmd_rm_app_image() {
  cch_require_podman
  "${PODMAN_BIN}" image rm -f "${APP_IMAGE}" >/dev/null 2>&1 || true
}

cmd_migrate() {
  ensure_dev_stack
  cd "${REPO_ROOT}"
  DSN="${LOCAL_DSN}" bun run db:migrate
}

cmd_db_shell() {
  ensure_dev_stack
  exec "${PODMAN_BIN}" exec -it "${POSTGRES_CONTAINER}" psql -U "${DB_USER}" -d "${DB_NAME}"
}

cmd_redis_shell() {
  ensure_dev_stack
  exec "${PODMAN_BIN}" exec -it "${REDIS_CONTAINER}" redis-cli
}

cmd_logs() {
  cch_require_podman
  exec "${PODMAN_BIN}" pod logs -f --tail 200 "${POD_NAME}"
}

cmd_logs_app() {
  cch_require_podman
  exec "${PODMAN_BIN}" logs -f --tail 200 "${APP_CONTAINER}"
}

cmd_logs_db() {
  cch_require_podman
  exec "${PODMAN_BIN}" logs -f --tail 200 "${POSTGRES_CONTAINER}"
}

cmd_logs_redis() {
  cch_require_podman
  exec "${PODMAN_BIN}" logs -f --tail 200 "${REDIS_CONTAINER}"
}

cmd_status() {
  cch_require_podman
  "${PODMAN_BIN}" pod ps --filter "name=${POD_NAME}"
  "${PODMAN_BIN}" ps --all --filter "pod=${POD_NAME}"
}

cmd_stop() {
  cch_require_podman
  if cch_pod_exists "${POD_NAME}"; then
    "${PODMAN_BIN}" pod stop "${POD_NAME}"
  fi
}

cmd_clean() {
  cch_require_podman
  if cch_pod_exists "${POD_NAME}"; then
    "${PODMAN_BIN}" pod rm -f "${POD_NAME}"
  fi
}

cmd_reset() {
  cmd_clean
  "${PODMAN_BIN}" unshare rm -rf "${POSTGRES_DATA_DIR}" "${REDIS_DATA_DIR}"
}

cmd_compose() {
  echo "Podman native workflow no longer uses docker compose."
  echo "Pod name: ${POD_NAME}"
}

main() {
  local command="${1:-help}"
  case "${command}" in
    help) cmd_help ;;
    db) cmd_db ;;
    dev) cmd_dev ;;
    build) cmd_build ;;
    build-nocache) cmd_build_nocache ;;
    app) cmd_app ;;
    app-rebuild) cmd_app_rebuild ;;
    app-nocache) cmd_app_nocache ;;
    prune-images) cmd_prune_images ;;
    rm-app-image) cmd_rm_app_image ;;
    migrate) cmd_migrate ;;
    db-shell) cmd_db_shell ;;
    redis-shell) cmd_redis_shell ;;
    logs) cmd_logs ;;
    logs-app) cmd_logs_app ;;
    logs-db) cmd_logs_db ;;
    logs-redis) cmd_logs_redis ;;
    status) cmd_status ;;
    stop) cmd_stop ;;
    clean) cmd_clean ;;
    reset) cmd_reset ;;
    compose) cmd_compose ;;
    *)
      cch_log_error "Unknown command: ${command}"
      exit 1
      ;;
  esac
}

main "$@"
