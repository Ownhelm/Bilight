# Bilight for iPhone

独立运行的原生 SwiftUI 客户端，最低 iOS 17。手机直接连接 B 站，不依赖 Mac、Docker 或 Bilight 网页后端。首页只有居中的搜索框，底部进入关注动态，不提供推荐、热搜或自动连播。

<p align="center"><img src="../docs/assets/ios-home.png" width="240" alt="首页"><img src="../docs/assets/ios-following.png" width="240" alt="关注动态"><img src="../docs/assets/ios-account.png" width="240" alt="演示账号"></p>

截图使用虚构账号与离线 mock 数据。

## 构建与安装

用支持 iOS 17 及以上的 Xcode 打开 `Bilight.xcodeproj`。选择 **Bilight → Signing & Capabilities**，开启自动签名，选择自己的 Apple Team，再把 Bundle Identifier 改成自己的唯一标识。仓库没有预置个人 Team 或签名资料。

选择已连接的 iPhone，点击 Run。首次运行需要按 iPhone 提示启用开发者模式，并在“设置 → 通用 → VPN 与设备管理”中信任对应开发者；Apple ID 和安全验证由本人在 Xcode 完成。个人账号签名的有效期以 Xcode 提示为准，过期后重新构建安装即可。

启动后在 App 内打开官方登录页并完成登录。App 只读取自己临时登录页面中的会话，存入设备 Keychain，不读取 Safari 或其他应用中的 Cookie，不会上传给 Bilight 服务端。

发布页中的 `Bilight-iOS-unsigned.ipa` 没有 Apple 签名和设备描述文件，不能直接安装。常规使用建议通过 Xcode 源码构建；没有 App Store／TestFlight 下载渠道。

## 日常使用

搜索支持视频、UP 主、视频链接与 BV 号。UP 主页面区分投稿、合集和列表，选中分组后才加载其中内容；关注图标点击即可切换，取消关注不弹二次确认。

关注页按时间展示已关注账号的视频、文字、图文、转发和专栏摘要；逐页核验关注关系，过滤平台插入内容。靠近页尾继续加载，也保留手动加载和刷新。搜索、合集、评论与历史手动分页。

原生播放器默认最高实际可用 AVC 画质；DASH 音视频通过本机分段适配器播放，只监听 iPhone 的回环地址。横屏直接进入全屏，画质、倍速与字幕设置共用状态，字幕可用时默认开启且优先中文，评论默认展开。分 P 手动切换，播放结束停止。

视频操作栏提供一键三连、下载、字幕开关、设置与前后 5 秒。下载保存在 App 内，完成后可以离线播放或通过系统分享菜单导出；权限、容量和网络错误会如实显示。三连是一次真实账号操作，投币不可撤回，不会因失败而自动重试。当前未提供独立点赞／投币／收藏编辑及弹幕。

“我的账号”内包含关注的人、常访问 UP 主、收藏、下载和最近访问入口。常访问排序来自 B 站接口，并非本地记录的逐次主页访问。视频历史统一读取 B 站云端，实际播放推进后同步真实分 P 和进度；仅打开视频或拖动暂停视频不会生成观看记录。

## 开发与验证

Xcode 工程已经提交，可以直接打开。修改 `project.yml` 后可使用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 重新生成工程：

```bash
xcodegen generate --spec ios/project.yml
BILIGHT_DESTINATION='platform=iOS Simulator,name=你的模拟器名称' bash ios/scripts/verify.sh test
```

以上命令在仓库根目录执行。`test` 使用内存会话和假上游，不碰真实账号；`live` 是单独的匿名只读播放与下载烟测，会访问网络。`build` 构建模拟器，`archive` 生成未签名 Release archive：

```bash
bash ios/scripts/verify.sh archive
python3 ios/scripts/package-source.py
```

产物位于被 Git 忽略的 `.build/`、`.artifacts/` 和仓库根目录 `artifacts/`。不要提交个人签名证书、描述文件、Keychain 导出或真实观看诊断。

## 离线界面预览

Debug 构建支持启动参数 `--demo`。在 Xcode 的 Scheme → Run → Arguments 中添加该参数后运行，即可使用内存会话、虚构账号与打包的自制图片。全部 API 请求由本地 URLProtocol 拦截，未覆盖的操作直接报错，写入被禁止，不会回退访问真实 B 站。

详细的截图复现步骤见 [演示说明](../docs/demo.md)。正常启动不带该参数，Release 构建不包含演示执行逻辑。

## 代码布局

`Core/` 处理接口、WBI、会话、云端历史与数据模型；`Features/` 为 SwiftUI 页面；`Playback/` 负责 AVPlayer、DASH 分段、字幕和全屏；`Downloads/` 处理下载、合并、离线观看与导出；`Demo/` 是独立发布预览数据；`BilightTests/` 为隔离测试。

支持的链接包括 `bilight://following`、`bilight://video/BV号`、`bilight://account` 以及账号子路径 `/following`、`/frequent`、`/favorites`、`/recent`、`/downloads`。
