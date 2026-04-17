#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "E2E 测试运行脚本"
echo "===================="
echo ""

echo "检查数据库连接..."
bash "${SCRIPT_DIR}/podman-dev.sh" db >/dev/null
echo "PostgreSQL / Redis 已就绪"
echo ""

echo "启动 Next.js 开发服务器..."
PORT=13500 bun run dev > /tmp/nextjs-dev.log 2>&1 &
SERVER_PID=$!

echo "服务器 PID: $SERVER_PID"
echo "等待服务器就绪..."

TIMEOUT=60
COUNTER=0

while [[ ${COUNTER} -lt ${TIMEOUT} ]]; do
  if curl -fsS http://localhost:13500/api/actions/health >/dev/null 2>&1; then
    echo "服务器已就绪"
    break
  fi

  COUNTER=$((COUNTER + 1))
  sleep 1
  echo -n "."
done

if [[ ${COUNTER} -eq ${TIMEOUT} ]]; then
  echo ""
  echo "服务器启动超时"
  kill "${SERVER_PID}" 2>/dev/null || true
  exit 1
fi

echo ""
echo "运行 E2E 测试..."
echo ""

export API_BASE_URL="http://localhost:13500/api/actions"
export AUTO_CLEANUP_TEST_DATA=true

bun run test tests/e2e/
TEST_EXIT_CODE=$?

echo ""
echo "停止开发服务器..."
kill "${SERVER_PID}" 2>/dev/null || true
wait "${SERVER_PID}" 2>/dev/null || true

echo "服务器已停止"
echo ""

if [[ ${TEST_EXIT_CODE} -eq 0 ]]; then
  echo "E2E 测试全部通过"
  exit 0
fi

echo "E2E 测试失败"
exit "${TEST_EXIT_CODE}"
