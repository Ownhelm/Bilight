# 电脑端 Docker 使用说明

Bilight 是本机单用户服务。默认 Compose 项目名与容器名均为 `bilight`，只发布 `127.0.0.1:3880`；不需要公共域名或云服务器。Mac 可使用 OrbStack，其他支持 Docker Compose 的环境也可构建运行。

## 首次启动

```bash
git clone https://github.com/Tiresiasel/bilight.git
cd bilight
node scripts/setup.mjs
docker compose up -d --build
docker compose ps
```

`setup` 生成 `.secrets/master-key`，不会覆盖已有密钥。本机没有 Node.js 时，用一次性 Node 容器执行：

```bash
docker run --rm -v "$PWD:/work" -w /work node:24-bookworm-slim node scripts/setup.mjs
```

打开 http://127.0.0.1:3880，使用官方扫码或短信登录。无需另建本地账号。OrbStack 的域名标签还提供 http://bilibili.local，详见 [本地域名](local-domain.md)。OrbStack 需保持运行；希望开机恢复时，在其设置中开启登录启动。

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
docker cp bilight:/data ./bilight-backup
docker compose up -d
```

将 `.secrets/master-key` **单独备份**到安全位置。备份目录包括加密的私人账号状态，不能提交或公开。即使只有数据库，没有原密钥也无法恢复登录。视频历史以 B 站云端为准，不保存在这份本地数据库中。

## 恢复

在已有的停止容器上恢复原来的密钥文件和数据目录，再启动：

```bash
docker compose stop
docker cp ./bilight-backup/. bilight:/data
docker compose up -d
```

新环境先准备源码、恢复 `.secrets/master-key`，执行 `docker compose create` 创建停止的容器与卷，再复制 `/data`。不要生成新密钥覆盖原密钥；丢失原密钥时需重新登录。

## 隔离与入口

镜像不包含密钥、数据库、iOS 文件或截图。会话在服务端加密持久化，浏览器仅持有本地 HttpOnly 会话；服务使用只读根文件系统、独立数据卷与受限媒体代理。不要直接向公网暴露此单用户服务。

Safari 可使用 [RedirectWeb 规则](safari-redirect.md) 将主站页面导航导向本地；它不修改 API、登录域名或 CDN。单纯的 DNS／hosts 映射无法接管 B 站 HTTPS 地址。
