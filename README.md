<p align="center"><img src="branding/project-mark.svg" width="80" alt="Bilight"></p>
<h1 align="center">Bilight</h1>
<p align="center"><strong>搜你所想，看你所选。</strong></p>
<p align="center">一个只保留搜索与关注的 B 站客户端。支持 iPhone 客户端与通过 Docker 本地部署的电脑客户端。</p>
<p align="center">
  <img alt="iOS 17+" src="https://img.shields.io/badge/iOS-17%2B-303440?style=flat-square">
  <img alt="Docker" src="https://img.shields.io/badge/Docker-本地部署-76b9db?style=flat-square">
  <a href="LICENSE"><img alt="MIT" src="https://img.shields.io/badge/License-MIT-ed7a9e?style=flat-square"></a>
</p>
<p align="center"><a href="https://github.com/Ownhelm/Bilight">项目仓库</a> · <a href="#为什么做-bilight">初衷</a> · <a href="#可以做什么">功能</a> · <a href="#快速开始">开始使用</a> · <a href="ios/README.md">iPhone 安装</a> · <a href="docs/docker.md">Docker 部署</a></p>

> [!IMPORTANT]
> Bilight 是个人学习与技术研究项目，并非哔哩哔哩官方客户端，与哔哩哔哩无隶属或合作关系。项目依赖的非官方接口可能随时变更或失效；使用时请遵守平台规则、版权要求与所在地法律，不得用于绕过付费、隐私保护或其他访问控制。

## 为什么做 Bilight

本来只是想搜一个视频，打开首页，却被推荐带到了另一个地方。一个接着一个，最后忘记了自己为什么打开 B 站。

Bilight 的起点很简单：**我想继续看 B 站，但想由自己决定看什么。**

打开后，只有一个搜索框。想看什么就搜，想跟进谁就关注谁。保留视频、UP 主、合集、收藏和观看历史这些有明确目的的入口，去掉推荐、热搜、榜单和自动连播。视频结束，就停在那里。

它不是一个让人刷得更久的客户端，而是希望让“看完了”重新成为一个自然的结束。

## 当前界面与入口

iPhone 底部只有“搜索”和“关注”两个页签。首页的搜索框居中，标识和“搜你所想，看你所选”位于搜索框上方；左上角头像打开“我的账号”，右上角提供下载和历史入口。

“我的账号”依次提供“我的关注的人”“我的收藏”“我的下载”，以及“常访问的 UP 主”入口和头像列表。“常访问的 UP 主”位于账号页内，不是底部页签，也没有单独的“我的最近访问”入口。

手机关注页为单列动态，通过下拉刷新读取最新内容，向下浏览继续加载；电脑客户端保持多列关注视频网格，保留“刷新最新”和“加载更多”。电脑首页右上方提供关注、历史和账号入口。

需要查看实际布局或制作截图时，可使用[隔离的离线预览](docs/demo.md)，无需登录真实账号。

## 可以做什么

| 功能 | iPhone 客户端 | 电脑客户端 |
| :--- | :--- | :--- |
| 搜索视频、UP 主、BV 号或链接 | ✓ | ✓ |
| 关注内容 | 视频、文字、图文、转发等动态，单列浏览 | 关注视频，多列网格整行加载 |
| UP 主投稿、合集和列表 | ✓ | ✓ |
| 关注／取消关注 UP 主 | ✓ | — |
| 原生／本地页面播放、画质、倍速、分 P、字幕 | AVPlayer，横屏全屏 | ArtPlayer + DASH，全屏与键盘快进 |
| 点赞、投币、收藏 | 独立操作、收藏夹选择、长按点赞三连 | 独立操作、收藏夹选择、长按点赞三连 |
| 账号入口 | 我的关注的人、我的收藏、我的下载、常访问的 UP 主 | 已登录账号与退出 |
| 云端观看历史与真实进度同步 | ✓ | ✓ |
| 视频下载、App 内离线播放与文件导出 | ✓ | — |
| 评论 | 只读 | 只读 |
| 弹幕 | 只读，可开关 | 只读，可开关 |

两端首次使用账号实际可用的最高 AVC 画质，此后记住手动选择；新视频无对应档位时逐档向下选取，且不覆盖偏好。有字幕时默认开启并优先中文，点开视频后自动播放，分 P 由用户选择，播放结束停止。网页端遇到浏览器有声自动播放限制时会提示点击播放。弹幕首次默认关闭，之后记住开关。弹幕和画质偏好跨视频、分 P 及重启保留，两端各自在本机保存。手机双击画面左右两侧可后退／前进10秒。会员、地区和平台风控限制如实显示；当前聚焦普通 UP 主视频，不包含直播和番剧。

关注页会在当前会话内保留已加载内容、分页和浏览位置，从视频返回直接恢复；只有主动下拉刷新或点击“刷新最新”才更新首屏，继续向下浏览时再加载后页。刷新失败保留原列表，退出或切换账号清空缓存。

两端分别登录同一个 B 站账号，观看历史来自同一份 B 站云端记录；实际播放后同步进度，打开或刷新历史时读取更新。“常访问的 UP 主”排序也来自 B 站，不是按本机逐次访问时间生成的列表。

## 快速开始

### 电脑端：Docker

需要安装并启动支持 Docker Compose 的容器运行环境。先克隆项目，然后生成**自己的本地加密密钥**再启动：

```bash
git clone https://github.com/Ownhelm/Bilight.git
cd Bilight
# 这一步只需本机有 Node.js；不会覆盖已经生成的密钥。
node scripts/setup.mjs
docker compose up -d --build
```

打开 **http://127.0.0.1:3880**，扫码或短信登录已有的 B 站账号。服务只绑定本机地址，不需要额外注册 Bilight 账号。

没有 Node.js 时，也可以在仓库目录用一次性容器生成密钥：

```bash
mkdir -p ../Local
docker run --rm -v "$PWD:/work" -v "$PWD/../Local:/Local" -w /work node:24-bookworm-slim node scripts/setup.mjs
docker compose up -d --build
```

更新、停止、备份与恢复见 [Docker 使用说明](docs/docker.md)。

### iPhone：Xcode 构建

需要 macOS、支持 iOS 17 及以上的 Xcode 和 Apple ID。打开 `ios/Bilight.xcodeproj`，选择 Bilight target，在 **Signing & Capabilities** 中选择自己的 Team，并将 Bundle Identifier 改成自己的唯一标识。选择 iPhone 后运行；首次真机安装按系统提示完成开发者模式与信任。

手机端使用 App 内官方登录页，凭据保存在这台 iPhone 的 Keychain。**不需要启动电脑端服务，也不需要把 Mac 的 Cookie 复制到手机。**

当前版本请使用仓库源码构建。[发布页](https://github.com/Ownhelm/Bilight/releases) 保留历史源码包与未签名 IPA；它们可能早于当前界面和品牌资源。未签名 IPA 供自行签名使用，不能直接点击安装；项目目前没有 App Store 或 TestFlight 版本。详细步骤见 [iPhone 使用与构建](ios/README.md)。

## 仓库范围

本仓库维护应用源码、开发文档与构建／测试必需资源。`releases/` 可在本地保存源码包、IPA 和归档，但不提交 Git；`npm run check:repo` 检查 Git 索引，防止宣发素材、发布包或本地凭据混入。

品牌矢量源统一放在 [`branding/`](branding/README.md)。README 使用项目小电视标志；网页和 iPhone 使用同一份圆角播放标志，均不带天线或品牌后缀圆点。修改后通过 `npm run brand:sync` 同步构建资源，`npm run check:brand` 检查引用与副本。

## 本地开发

网页使用 Node.js 24，与 Docker 镜像版本保持一致：

```bash
npm ci
npm run setup
npm run dev
```

前端位于 `http://127.0.0.1:5173`，API 位于 `http://127.0.0.1:3880`。不要与已占用 3880 的 Docker 服务同时启动本地后端。生产构建使用 `npm run build && npm start`。

```bash
npm test
npm run build
bash ios/scripts/verify.sh test
```

iOS 模拟器名称按本机情况通过 `BILIGHT_DESTINATION` 指定。测试默认隔离账号与网络，不发送真实短信或互动；联网播放烟测为单独、显式的命令。目录结构与贡献方式见 [贡献指南](CONTRIBUTING.md)。

## 隐私与演示数据

网页凭据在本地服务端以 AES-256-GCM 加密写入 SQLite，密钥独立挂载；iPhone 凭据只保存在本机 Keychain。仓库和发布文件不包含 Cookie、个人密钥、Apple 签名证书、设备描述文件或真实账号截图。

项目不再维护独立本机视频历史，旧记录也不会批量补报。进度同步依赖登录与网络；失败会显示真实错误，仅在当前页面／App 会话暂存待发进度，不保证断网并终止进程后的补同步。

希望试改界面、录屏或补充文档时，可使用 [离线 mock 预览](docs/demo.md)，无需登录任何账号。

## 技术与致谢

网页：React、Vite、TypeScript、Fastify、SQLite；播放器使用 [ArtPlayer](https://github.com/zhw2590582/ArtPlayer)、[dash.js](https://github.com/Dash-Industry-Forum/dash.js) 和 ArtPlayer 弹幕插件。iPhone：SwiftUI、AVFoundation、WebKit、Keychain。

专注观看的思路也参考了 [FocuBili](https://github.com/L1Xu4n/FocuBili)，没有整体移植其实现。README 的信息结构参考 [ArtPlayer](https://github.com/zhw2590582/ArtPlayer) 与 [Immich](https://github.com/immich-app/immich)，界面和截图由本项目制作，预览封面及作者头像归原作者所有。第三方许可见 [依赖说明](THIRD_PARTY_NOTICES.md)。

## 状态与许可

项目仍在持续打磨，欢迎提交可以复现的问题；请勿在 issue 中粘贴登录凭据或包含账号信息的截图。

项目原创代码与演示素材使用 [MIT License](LICENSE)。视频、用户内容、商标及第三方依赖分别属于其权利人。
