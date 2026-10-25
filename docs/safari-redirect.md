# Safari 自动跳转

如果只需要用域名直接打开本地项目，可访问 **http://bilibili.local**，见 [OrbStack 本地域名](local-domain.md)。下面的扩展方案仅用于将真正的 `bilibili.com` 导航自动转到本地，两种功能不同。

安装 [RedirectWeb 免费版](https://redirectweb.net/introduction)，在 Safari 设置 → 扩展中启用。免费版只需一条启用规则；不需要购买订阅。当前 Safari 的 DNR 功能仍由扩展作者标为实验功能，必须用下面的例子实际验证。

可将本项目的 [bilight.redirectweb](bilight.redirectweb) 拖进 RedirectWeb 窗口，或通过 File → Import Rules 导入。文件使用[官方规则库的原生导出格式](https://github.com/mshibanami/redirect-web/tree/main/library)和[官方 DNR 示例](https://github.com/mshibanami/redirect-web/blob/main/library/rule-sets/19_youtube_shorts_to_normal_videos/rule-set.json)，只包含一条启用规则。官方公开样例没有显式编码 Raw 选项，因此导入后仍需打开 Advanced，将 Main Frame Redirection 确认为 **Raw**；不要把文件已生成理解为 Safari 中已安装或验收。

也可手动新建规则：Type 选择 **DNR**，URL Pattern 选择 **Regular Expression**，Resource Types 只选 **main_frame**，Main Frame Redirection 选择 **Raw**。只保留这条规则启用，避免免费版一条启用规则的限制。

Redirect From：
```text
^https?://(www\.)?bilibili\.com/(.*)$
```
Redirect To：
```text
http://127.0.0.1:3880/open/$2
```

授权只包含来源 bilibili.com、www.bilibili.com 和目标 127.0.0.1。不要授权全部网站，也不要使用 Original 类型：它可能在跳转前闪现原站。无需修改 hosts、DNS、系统证书或网络代理。

先确认 Bilight 正常运行，再在规则 Examples 中检查 `https://www.bilibili.com/` 和一个 `/video/BV...` 地址。然后在 Safari 实际访问，首页应进入 Bilight 首页，视频链接应进入本地播放器；查询参数中的分 P 应保留，原站内容不应闪现。重启 Safari 后再测一次，确认权限和规则保留。

这条规则只处理主站顶层页面，不改动 passport 登录域名、API、视频 CDN 或第三方网页。搜索子域名、UP 主页子域名及短链接可粘贴至 Bilight 搜索框解析。服务关闭时应看到本地连接失败，不会退回原站推荐。
