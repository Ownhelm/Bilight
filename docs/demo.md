# 离线演示与截图

演示账号、关注关系、动态容器和历史进度为 mock；影视飓风、小鹿Lawrence、超Carry的柴西的视频标题、封面、头像与合集快照来自公开页面。没有读取个人账号或对真实截图打码。[公开内容来源与权属](demo-content.md)。代码仓库只保存演示逻辑与 JSON 数据，不捆绑宣发图片。

## 外部素材

完整 Bilight 工作区把公开图片放在代码仓库同级的 `Promotion/DemoAssets/`，截图放在 `Promotion/Screenshots/`；仅克隆源码不会获得这些资料。可通过 `BILIGHT_DEMO_ASSETS_DIR` 指定自己的素材目录。缺少素材时网页图片接口返回明确错误，不回退访问 B 站；普通 iOS 工程不包含预览图片。

## 网页预览

```bash
npm ci
npm run build
npm run demo
```

在代码仓库执行后打开 http://127.0.0.1:3881。演示不导入真实 Gateway、Auth 或 SQLite，只绑定回环地址；写请求返回 `DEMO_READ_ONLY`，未覆盖的 API 返回真实错误，CSP 阻止远程连接。不影响3880的正常服务。

## iPhone 预览

```bash
bash ios/scripts/preview.sh
```

该命令需要 XcodeGen 和外部素材目录，生成被 Git 忽略的 `ios/BilightPreview.xcodeproj`；配置和构建输出保存在仓库外 `Local/Builds/`。用 Bilight scheme 编译 Debug，在 Run Arguments 中添加 `--demo`；素材作为 DemoAssets 文件夹加入该临时 App，普通工程不受影响。专用 URLProtocol 拦截全部 API，不读取真实 Keychain 或本地下载目录，不提供登录、播放或互动写入；Release 不编译演示逻辑。

## 维护与截图

`scripts/demo-public-content.json` 记录公开资料及校验值，`scripts/demo-fixtures.mjs` 组合虚构账号，`node scripts/prepare-demo.mjs` 更新原生 JSON。素材合成脚本位于仓库外 `Promotion/Tools/readme-assets.py`，生成图片始终写入 Promotion。

仅截取模拟器或演示网页，不能包含真实设备列表、桌面、通知和个人信息。代码 README 不嵌入本地宣发图片；完整工作区的总览 README 可展示这些外部截图。
