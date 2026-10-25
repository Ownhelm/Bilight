# 离线 mock 预览与截图

README 展示的是实际页面组件，并非另外画的一套界面。所有账号、UID、BV 号、动态、关注关系和历史进度均为项目专门编写的虚构数据；图片为自制几何插画。没有使用真实账号截图进行打码或替换。

## 网页

```bash
npm ci
npm run build
npm run demo
```

打开 http://127.0.0.1:3881，可查看首页、关注、搜索和 UP 主合集。这个服务不导入真实 Gateway、Auth 或 SQLite，也没有上游请求。它只绑定回环地址，所有写请求返回 `DEMO_READ_ONLY`，未覆盖 API 返回明确错误；CSP 阻止远程资源连接。退出进程即可关闭，不影响 3880 的正常服务。

## iPhone

用 Xcode 编译 Debug，在 Scheme → Run → Arguments 添加 `--demo`。演示会话仅在内存，读取 `Demo/fixtures.json`，图片从 App 包加载；所有 API 都由专用 URLProtocol 拦截，未覆盖请求不会放行到网络。不读取真实 Keychain，也不读取本地下载目录。登录页面显示离线提示，不加载官方页面；这套预览用于浏览页面，不提供账号与媒体操作。

在 iOS Simulator 中查看首页、点击底部关注、点击左上角演示头像即可复现三张截图。仅截取模拟器屏幕，勿把真实设备列表、桌面、通知或其他应用一起截进去。正常使用请移除 `--demo`；Release 不编译演示代码。

## 维护数据与素材

`scripts/demo-fixtures.mjs` 是虚构数据源，`scripts/prepare-demo.mjs` 将原始接口格式导出为原生 App 的 `Demo/fixtures.json`。调整后运行：

```bash
node scripts/prepare-demo.mjs
python3 scripts/readme-assets.py
xcodegen generate --spec ios/project.yml
```

素材脚本需要 Python 与 Pillow，并使用系统中文字体；macOS 自带的黑体可直接使用。`readme-assets.py --compose` 使用现有 `web-following.png` 和 `ios-home.png` 截图合成首页预览，不改动截图内的页面内容。

截图文件位于 `docs/assets/`。更新时继续使用虚构数据，逐张检查账号、头像、通知、链接和元数据，确认没有真实身份与观看信息。
