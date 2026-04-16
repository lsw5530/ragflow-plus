# RAGFlow-Plus Bug 修复记录

## 1. 文档解析 504 Gateway Timeout

### 问题
点击知识库文档的"解析"按钮时，前端报 504 Gateway Timeout。  
请求路径：`POST http://10.101.190.97:8888/api/v1/knowledgebases/documents/{doc_id}/parse`

### 根本原因
两层问题叠加：
1. `docker/nginx/management_nginx.conf` 的 `/api/` location 块没有设置超时时间，使用 nginx 默认 60s
2. `/parse` 路由直接调用 `KnowledgebaseService.parse_document()`，该方法同步阻塞，执行 PDF 解析 + embedding + ES 写入，大文档需要数分钟

### 解决方案
**文件 1**：`docker/nginx/management_nginx.conf`
```nginx
location /api/ {
    proxy_pass http://management-backend:5000/api/;
    ...
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
}
```

**文件 2**：`management/server/routes/knowledgebases/routes.py`  
将同步调用改为异步（`async_parse_document` 方法已存在于 service.py）：
```python
# 改前
result = KnowledgebaseService.parse_document(doc_id)

# 改后
result = KnowledgebaseService.async_parse_document(doc_id)
return success_response(data={"message": result.get("message"), ...})
```

**部署**：
- nginx 改动：`docker exec ragflowplus-management-frontend nginx -s reload`
- 路由改动：`docker cp` + `docker compose up -d management-backend`

---

## 2. management-backend 启动报 ModuleNotFoundError

### 问题
```
ModuleNotFoundError: No module named 'services.auth'
```

### 根本原因
本地仓库 `routes.py` 比镜像（v0.5.0）新，包含 `from services.auth import ...`，但镜像中没有该模块。直接 `docker cp` 本地文件到容器导致启动失败。

### 解决方案
从镜像中提取原始 `routes.py`，只修改目标函数后再 `docker cp` 回容器：
```bash
docker run --rm zstar1003/ragflowplus-management-server:v0.5.0 \
  cat /app/routes/knowledgebases/routes.py > /tmp/original_routes.py
# 编辑 /tmp/original_routes.py，只改需要的部分
docker cp /tmp/original_routes.py ragflowplus-management-backend:/app/routes/knowledgebases/routes.py
```

---

## 3. 本地代码热更新（volume 挂载）

### 问题
`management-backend` 使用预构建镜像，修改本地代码需要重新打镜像才能生效。

### 解决方案
`docker/docker-compose.yml` 中将本地代码目录挂载到容器：
```yaml
management-backend:
  volumes:
    - ../management/server:/app   # 新增：挂载本地代码
    - ./ragflow-plus-logs:/app/logs
    - ./magic-pdf.json:/root/magic-pdf.json
  environment:
    - FLASK_ENV=development
    - FLASK_DEBUG=1               # 新增：开启热重载
```

`management/server/app.py`：
```python
app.run(host="0.0.0.0", port=5000, use_reloader=True)
```

**注意**：挂载配置变更后必须用 `docker compose up -d`（重建容器），`make restart` 内部是 `docker compose restart`，不会重建容器，挂载不会生效。

---

## 4. Makefile restart 不重建容器

### 问题
`make restart` 使用 `docker compose restart`，只重启进程，不应用 `docker-compose.yml` 的配置变更。

### 解决方案
修改 `Makefile`：
```makefile
# restart 改为 up -d，自动对比配置变化并重建有变更的容器
restart:
    $(COMPOSE) up -d

# 新增 recreate，强制重建指定服务
recreate:
    $(COMPOSE) up -d --force-recreate $(svc)
    # 用法：make recreate svc=management-backend
```

---

## 5. 聊天报错：Knowledge bases use different embedding models

### 问题
```
ERROR: Knowledge bases use different embedding models.
```

### 根本原因
`api/db/services/dialog_service.py` 直接比较原始 `embd_id` 字符串（含厂商后缀，如 `model@Vendor`），而设置对话时用了 `split_model_name_and_factory()` 去掉后缀后再比较，导致同一模型被误判为不同模型。

### 解决方案
`api/db/services/dialog_service.py`：
```python
# 改前
embedding_list = list(set([kb.embd_id for kb in kbs]))
if len(embedding_list) != 1:
    ...

# 改后
embd_base_ids = list(set([
    TenantLLMService.split_model_name_and_factory(kb.embd_id)[0]
    for kb in kbs
]))
if len(embd_base_ids) != 1:
    ...
embedding_model_name = kbs[0].embd_id  # 初始化 LLMBundle 时仍用完整名称
```

---

## 6. 聊天长时间"搜索中"无响应

### 问题
发送中文消息后，前端一直显示"搜索中"，无任何回复。

### 根本原因
前端开启"跨语言检索"时，每次中文消息都调翻译接口 `/v1/translate/translate`。该接口使用 T5 模型惰性加载，而容器内没有 `models/` 目录，触发时尝试从 HuggingFace 下载模型，无网或慢网环境下永久挂起，整个 chat 等待翻译完成才继续。

### 解决方案
`api/apps/translate_app.py`：模型目录不存在时直接返回原文，不触发下载：
```python
def translate_text(text, source_lang="zh", target_lang="en"):
    MODEL_PATH = os.path.join(os.path.dirname(__file__), "..", "..", "models")
    if not os.path.exists(MODEL_PATH):
        logging.warning("Translation model not found, returning original text")
        return text
    ...
```

---

## 7. 聊天报错：url error, please check url（阿里云模型）

### 问题
```
ERROR: url error, please check url! For details, see: https://help.aliyun.com/...
```

### 根本原因
对话助手配置的 LLM 是 `qwen-vl-plus`（视觉多模态模型）。纯文本对话时 `image=""` 为空，但 `QWenCV.chat_prompt()` 仍生成 `{"image": ""}` 字段，DashScope API 收到空 image URL 报错。

### 解决方案
`rag/llm/cv_model.py` — `QWenCV.chat_prompt()`：
```python
def chat_prompt(self, text, b64):
    if b64:
        return [{"image": f"{b64}"}, {"text": text}]
    return [{"text": text}]  # 无图片时只传文本
```

> 建议：对话助手选用纯文本模型（如 `qwen-max`），视觉模型适合图文混合场景。

---

## 8. 图片上传失败（MinIO 连接拒绝）

### 问题
文档撰写页面点击"插入图片"后提示上传失败，后端报：
```
HTTPConnectionPool(host='minio', port=9010): Max retries exceeded
Failed to establish a new connection: [Errno 111] Connection refused
```

### 根本原因
两个问题叠加：
1. `MINIO_PORT=9010` 是宿主机对外映射端口，但 Docker 内部容器间通信时 MinIO 实际监听 `9000`，导致 `minio:9010` 连接失败
2. `MINIO_VISIT_HOST=localhost` 导致上传后返回的图片 URL 是 `http://localhost:9010/...`，浏览器无法访问

### 解决方案
**文件 1**：`docker/.env`
```
MINIO_VISIT_HOST=10.101.190.97   # 改为服务器实际 IP
```

**文件 2**：`api/db/services/database.py` — 分离内部连接端口与外部访问端口：
```python
if is_running_in_docker():
    MINIO_HOST = "minio"
    MINIO_INTERNAL_PORT = 9000           # 容器内部固定 9000
    MINIO_PORT = int(os.getenv("MINIO_PORT", "9000"))  # 宿主机对外端口，用于生成 URL

MINIO_CONFIG = {
    "endpoint": f"{MINIO_HOST}:{MINIO_INTERNAL_PORT}",  # 内部连接
    "visit_point": f"{MINIO_VISIT_HOST}:{MINIO_PORT}",  # 外部访问 URL
    ...
}
```

修复后图片上传返回 URL：`http://10.101.190.97:9010/public/images/xxx.png`，浏览器可正常访问。
