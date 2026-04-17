#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_FILE="${STATE_FILE:-${HOME}/.local/share/claude-code-hub/.podman-state}"
TOOLS_IMAGE="${TOOLS_IMAGE:-oven/bun:1.3.2-slim}"

if [[ ! -f "${STATE_FILE}" ]]; then
  echo "Podman deployment state file not found: ${STATE_FILE}" >&2
  exit 1
fi

source "${STATE_FILE}"

if [[ -z "${POD_NAME:-}" ]]; then
  echo "POD_NAME missing from ${STATE_FILE}" >&2
  exit 1
fi

exec podman run --rm -it \
  --pod "${POD_NAME}" \
  --working-dir /app \
  -v "${REPO_ROOT}:/app$(command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null || true)" != "Disabled" ] && printf ':z')" \
  --env-file "${DEPLOY_DIR}/.env" \
  -e "DSN=postgresql://${DB_USER:-postgres}:${DB_PASSWORD:-postgres}@127.0.0.1:5432/${DB_NAME:-claude_code_hub}" \
  -e "REDIS_URL=redis://127.0.0.1:6379" \
  -e "TZ=Asia/Shanghai" \
  "${TOOLS_IMAGE}" \
  "$@"
