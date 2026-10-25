# OrbStack 本地域名

本地入口为 **http://bilibili.local**。它通过 OrbStack 路由到 Bilight 容器的 3880 端口，不依赖浏览器扩展，也不需要修改 `/etc/hosts`。原 `http://127.0.0.1:3880` 仍可使用。OrbStack 必须运行，且 Settings → Network → Allow access to container domains & IPs 需要开启。

Compose 标签 `dev.orbstack.domains: bilibili.local` 登记本地域名，`dev.orbstack.http-port: "3880"` 指定容器中的 HTTP 服务端口。应用仅精确允许这个域名及既有 localhost 入口，没有允许任意 Host 或整个 `.local` 域。登录仍由原服务端加密会话恢复；不需要为不同本地入口重新扫描 B 站账号。

更新与重启继续使用 `docker compose up -d --build`。可用 `curl --noproxy '*' http://bilibili.local/health` 验证路由。若本机代理或 VPN 拦截 `.local`，先将该本地域名设为代理例外；不要把 B 站 API、登录域名或视频 CDN 指向 Bilight。

OrbStack [原生自定义域名只支持 `.local`](https://docs.orbstack.dev/docker/domains)，不能以容器标签接管真正的 `bilibili.com`。DNS 映射只改变目标 IP，不能完成 HTTPS 证书校验或网页重定向；因此访问真正的 B 站域名仍正常前往 B 站，除非另行启用浏览器重定向规则。输入中文“哔哩哔哩”通常会发起搜索，也不在该域名映射范围内。

OrbStack 另提供自动 HTTPS，但首次信任其本地根证书可能需要本人确认。本次本地域名入口使用 HTTP，不通过安装根证书或关闭证书校验接管真实 B 站域名。不要把“容器已运行”或“域名解析已生效”当作 Safari 自动重定向已经验收。
