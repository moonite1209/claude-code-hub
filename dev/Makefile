# ================================
# Claude Code Hub - Podman dev 工具链
# ================================
#
# 目标:
# 1) 通过 Podman pod 启动 PostgreSQL + Redis（供本机 bun dev 使用）
# 2) 通过 Podman 本地构建并运行 app 容器（无需预构建镜像）
#
# 说明:
# - 在项目根目录可直接运行 `make <target>`（根 Makefile 会转发到此处）
# - 官方支持 Linux rootless Podman

.PHONY: help dev db app build build-nocache app-rebuild app-nocache prune-images rm-app-image compose clean migrate db-shell redis-shell logs logs-app logs-db logs-redis reset status stop

SCRIPT := ../scripts/podman-dev.sh

help:
	@bash "$(SCRIPT)" help

db:
	@bash "$(SCRIPT)" db

dev:
	@bash "$(SCRIPT)" dev

build:
	@bash "$(SCRIPT)" build

build-nocache:
	@bash "$(SCRIPT)" build-nocache

app:
	@bash "$(SCRIPT)" app

app-rebuild:
	@bash "$(SCRIPT)" app-rebuild

app-nocache:
	@bash "$(SCRIPT)" app-nocache

prune-images:
	@bash "$(SCRIPT)" prune-images

rm-app-image:
	@bash "$(SCRIPT)" rm-app-image

migrate:
	@bash "$(SCRIPT)" migrate

db-shell:
	@bash "$(SCRIPT)" db-shell

redis-shell:
	@bash "$(SCRIPT)" redis-shell

logs:
	@bash "$(SCRIPT)" logs

logs-app:
	@bash "$(SCRIPT)" logs-app

logs-db:
	@bash "$(SCRIPT)" logs-db

logs-redis:
	@bash "$(SCRIPT)" logs-redis

status:
	@bash "$(SCRIPT)" status

stop:
	@bash "$(SCRIPT)" stop

clean:
	@bash "$(SCRIPT)" clean

reset:
	@bash "$(SCRIPT)" reset

compose:
	@bash "$(SCRIPT)" compose
