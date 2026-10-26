# 电脑端 Docker 使用说明

Bilight 是本机单用户服务。需要安装并启动支持 Docker Compose 的容器运行环境。默认 Compose 项目名与容器名均为 `bilight`，只发布 `127.0.0.1:3880`，不需要公共域名或云服务器。

## 首次启动

```bash
git clone https://github.com/Ownhelm/Bilight.git
cd Bilight
node scripts/setup.mjs
docker compose up -d --build
docker compose ps
```

`setup` 生成 `../Local/secrets/master-key`，不会覆盖已有密钥。本机没有 Node.js 时，用一次性 Node 容器执行：

```bash
mkdir -p ../Local
docker run --rm -v "$PWD:/work" -v "$PWD/../Local:/Local" -w /work node:24-bookworm-slim node scripts/setup.mjs
```

打开 **http://127.0.0.1:3880**，扫码或短信登录已有的 B 站账号，不需要额外注册 Bilight 账号。使用期间需保持容器运行环境和 Bilight 服务运行。

```bash
curl --fail http://127.0.0.1:3880/health
docker compose logs --tail=40
```

健康接口只返回服务状态。请勿为了排查问题打印 Cookie 或上传数据库。首次启动构建会安装依赖；后续运行无需本机 Node 常驻。

## 更新和停止

```bash
git pull --ff-only
docker compose up -d --build
```

停止使用 `docker compose stop`，恢复使用 `docker compose up -d`。持久卷 `bilight_bilight_data` 保存加密会话，重建容器会保留登录；密钥必须与数据库配对。**不要用 `docker compose down -v` 更新项目**，它会删除持久卷。

## 备份

先停止服务，确保 SQLite 不再写入，然后复制数据：

```bash
docker compose stop
mkdir -p ../Local/Backups
docker cp bilight:/data ../Local/Backups/bilight-backup
docker compose up -d
```

将 `../Local/secrets/master-key` **单独备份**到安全位置。备份目录包括加密的私人账号状态，不能提交或公开。即使只有数据库，没有原密钥也无法恢复登录。视频历史以 B 站云端为准，不保存在这份本地数据库中。

## 恢复

在已有的停止容器上恢复原来的密钥文件和数据目录，再启动：

```bash
docker compose stop
docker cp ../Local/Backups/bilight-backup/. bilight:/data
docker compose up -d
```

新环境先准备源码、恢复 `../Local/secrets/master-key`，执行 `docker compose create` 创建停止的容器与卷，再复制 `/data`。不要生成新密钥覆盖原密钥；丢失原密钥时需重新登录。

## 隔离与入口

镜像不包含密钥、数据库、iOS 文件或截图。会话在服务端加密持久化，浏览器仅持有本地 HttpOnly 会话；服务使用只读根文件系统、独立数据卷与受限媒体代理。不要直接向公网暴露此单用户服务。

如需在 Safari 中将 B 站链接跳转到 Bilight，可另行设置 [RedirectWeb 规则](safari-redirect.md)。这是可选配置，不是安装或使用 Bilight 的前提。
