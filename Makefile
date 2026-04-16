COMPOSE      := docker compose -f docker/docker-compose.yml --env-file docker/.env --profile elasticsearch
COMPOSE_GPU  := docker compose -f docker/docker-compose_gpu.yml --env-file docker/.env --profile elasticsearch
PROJECT      := ragflowplus

# 从 .env 读取端口，方便 info 命令展示
include docker/.env
export

.DEFAULT_GOAL := help

# ─────────────────────────────────────────────
# 帮助
# ─────────────────────────────────────────────
.PHONY: help
help:
	@echo ""
	@echo "Ragflow-Plus 管理命令"
	@echo "────────────────────────────────────────"
	@echo "  make up          启动所有服务（CPU 模式）"
	@echo "  make up-gpu      启动所有服务（GPU 模式）"
	@echo "  make down        停止并移除容器（保留数据卷）"
	@echo "  make restart     重建并启动所有服务（应用 compose 配置变更）"
	@echo "  make recreate svc=<服务名>  强制重建指定服务"
	@echo "  make stop        暂停所有容器（不删除）"
	@echo "  make start       恢复已暂停的容器"
	@echo ""
	@echo "  make ps          查看容器运行状态"
	@echo "  make logs        跟踪所有服务日志"
	@echo "  make logs-main   跟踪主服务日志（ragflow）"
	@echo "  make logs-mgmt   跟踪后台管理服务日志"
	@echo ""
	@echo "  make urls        仅输出所有访问 URL（便于复制）"
	@echo "  make info        显示服务访问地址（含端口说明和账号）"
	@echo "  make pull        拉取/更新所有镜像"
	@echo "  make clean       停止容器并删除数据卷（危险！）"
	@echo ""

# ─────────────────────────────────────────────
# 启停
# ─────────────────────────────────────────────
.PHONY: up
up:
	$(COMPOSE) up -d
	@echo ""
	@$(MAKE) --no-print-directory info

.PHONY: up-gpu
up-gpu:
	$(COMPOSE_GPU) up -d
	@echo ""
	@$(MAKE) --no-print-directory info

.PHONY: down
down:
	$(COMPOSE) down

.PHONY: stop
stop:
	$(COMPOSE) stop

.PHONY: start
start:
	$(COMPOSE) start
	@echo ""
	@$(MAKE) --no-print-directory info

.PHONY: restart
restart:
	$(COMPOSE) up -d
	@echo ""
	@$(MAKE) --no-print-directory info

.PHONY: recreate
recreate:
	@if [ -z "$(svc)" ]; then \
		echo "用法: make recreate svc=<服务名>  例: make recreate svc=management-backend"; \
		exit 1; \
	fi
	$(COMPOSE) up -d --force-recreate $(svc)
	@echo ""
	@$(MAKE) --no-print-directory info

# ─────────────────────────────────────────────
# 状态 & 日志
# ─────────────────────────────────────────────
.PHONY: ps
ps:
	$(COMPOSE) ps

.PHONY: logs
logs:
	$(COMPOSE) logs -f --tail=100

.PHONY: logs-main
logs-main:
	$(COMPOSE) logs -f --tail=100 ragflow

.PHONY: logs-mgmt
logs-mgmt:
	$(COMPOSE) logs -f --tail=100 management-backend management-frontend

# ─────────────────────────────────────────────
# 信息
# ─────────────────────────────────────────────
.PHONY: urls
urls:
	@echo "http://10.101.190.97:8100"
	@echo "http://10.101.190.97:8888"
	@echo "http://10.101.190.97:5000"
	@echo "http://10.101.190.97:$(SVR_HTTP_PORT)"
	@echo "http://10.101.190.97:$(ES_PORT)"
	@echo "http://10.101.190.97:$(MINIO_CONSOLE_PORT)"

.PHONY: info
info:
	@echo "────────────────────────────────────────"
	@echo "  前台用户系统    http://10.101.190.97:8100"
	@echo "  后台管理系统    http://10.101.190.97:8888"
	@echo "  管理后端 API    http://10.101.190.97:5000"
	@echo "  RAGFlow API     http://10.101.190.97:$(SVR_HTTP_PORT)"
	@echo "  Elasticsearch   http://10.101.190.97:$(ES_PORT)"
	@echo "  MinIO Console   http://10.101.190.97:$(MINIO_CONSOLE_PORT)"
	@echo "  MySQL           10.101.190.97:$(MYSQL_PORT)"
	@echo "  Redis           10.101.190.97:$(REDIS_PORT)"
	@echo "────────────────────────────────────────"
	@echo "  后台初始账号    admin / 12345678"
	@echo "────────────────────────────────────────"

# ─────────────────────────────────────────────
# 镜像管理
# ─────────────────────────────────────────────
.PHONY: pull
pull:
	$(COMPOSE) pull

# ─────────────────────────────────────────────
# 危险操作
# ─────────────────────────────────────────────
.PHONY: clean
clean:
	@echo "警告：此操作将删除所有容器和数据卷，数据不可恢复！"
	@read -p "确认删除？输入 yes 继续：" confirm && [ "$$confirm" = "yes" ] || (echo "已取消" && exit 1)
	$(COMPOSE) down -v
