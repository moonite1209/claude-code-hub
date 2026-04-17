# Podman 数据持久化目录

此目录用于存储 Podman 开发容器的持久化数据:

- `postgres/pgdata/` - PostgreSQL 数据库数据（实际数据存储位置）
- `redis/` - Redis 持久化数据

## 注意事项

1. 此目录内容不会被提交到 Git 仓库
2. 重建 Podman 容器时,数据不会丢失
3. 备份此目录即可备份所有数据库数据
4. 删除此目录将清空所有数据库数据

## PostgreSQL 数据目录说明

为了避免权限问题,PostgreSQL 配置了 `PGDATA=/data/pgdata`:
- 容器挂载点: `/data` → `./data/postgres`
- 实际数据目录: `/data/pgdata` → `./data/postgres/pgdata`

这样 PostgreSQL 可以在挂载点内创建所需的子目录结构。

## 常见问题

### 如果遇到 "no such file or directory" 错误

**原因**: PostgreSQL 容器需要在挂载点内创建 pgdata 子目录

**解决方案**:
1. 确保 PostgreSQL 容器包含 `PGDATA=/data/pgdata`
2. 清空 data/postgres 目录并重启:
   ```bash
   make clean
   podman unshare rm -rf data/postgres-dev/*
   make db
   ```

### 权限问题

如果遇到 PostgreSQL 权限问题,执行:
```bash
podman unshare chown -R 999:999 data/postgres-dev
```

如果遇到 Redis 权限问题,执行:
```bash
podman unshare chown -R 999:999 data/redis-dev
```
