#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_NAME="${PROJECT_NAME:-cch-dev}"
POSTGRES_CONTAINER="${PROJECT_NAME}-postgres"

echo "检查测试用户数量..."
bash "${SCRIPT_DIR}/podman-dev.sh" db >/dev/null

podman exec -i "${POSTGRES_CONTAINER}" psql -U postgres -d claude_code_hub -c "
SELECT
  COUNT(*) as 测试用户数量
FROM users
WHERE (name LIKE '测试用户%' OR name LIKE '%test%' OR name LIKE 'Test%')
  AND deleted_at IS NULL;
"

echo ""
echo "预览将要删除的用户（前 10 个）..."
podman exec -i "${POSTGRES_CONTAINER}" psql -U postgres -d claude_code_hub -c "
SELECT id, name, created_at
FROM users
WHERE (name LIKE '测试用户%' OR name LIKE '%test%' OR name LIKE 'Test%')
  AND deleted_at IS NULL
ORDER BY created_at DESC
LIMIT 10;
"

echo ""
read -r -p "确认删除这些测试用户吗？(y/N): " confirm

if [[ "${confirm}" == "y" || "${confirm}" == "Y" ]]; then
  echo "开始清理..."

  podman exec -i "${POSTGRES_CONTAINER}" psql -U postgres -d claude_code_hub -c "
  UPDATE keys
  SET deleted_at = NOW(), updated_at = NOW()
  WHERE user_id IN (
    SELECT id FROM users
    WHERE (name LIKE '测试用户%' OR name LIKE '%test%' OR name LIKE 'Test%')
      AND deleted_at IS NULL
  )
  AND deleted_at IS NULL;
  "

  podman exec -i "${POSTGRES_CONTAINER}" psql -U postgres -d claude_code_hub -c "
  UPDATE users
  SET deleted_at = NOW(), updated_at = NOW()
  WHERE (name LIKE '测试用户%' OR name LIKE '%test%' OR name LIKE 'Test%')
    AND deleted_at IS NULL;
  "

  echo "清理完成！"
  echo ""
  echo "剩余用户统计："
  podman exec -i "${POSTGRES_CONTAINER}" psql -U postgres -d claude_code_hub -c "
  SELECT COUNT(*) as 总用户数 FROM users WHERE deleted_at IS NULL;
  "
else
  echo "取消清理"
fi
