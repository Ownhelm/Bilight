# 参与 Bilight

欢迎提交问题、修复或改进。产品边界是搜索与已关注内容：请不要增加推荐流、热搜、榜单、猜你喜欢或自动连播。界面交互尽量简洁，接口失败要显示真实错误。

## 开始开发

网页使用 Node.js 24，与 Docker 镜像保持一致：

```bash
npm ci
npm run setup
npm run dev
```

前端为 `http://127.0.0.1:5173`，API 为 `http://127.0.0.1:3880`；不要与占用3880的 Docker 后端同时启动。生产构建使用 `npm run build && npm start`。网页技术栈为 React、Vite、TypeScript、Fastify 和 SQLite，播放器使用 ArtPlayer、dash.js 与 ArtPlayer 弹幕插件。

前后端共用 `shared/types.ts`；上游适配集中在 `server/transport.ts`、`server/auth.ts` 和 `server/gateway.ts`。媒体只允许登记过的本地资源标识，不接受任意远程地址。

iOS 项目位于 `ios/`，直接用 Xcode 打开；构建和账号说明见 [iPhone 文档](ios/README.md)。上游适配集中在 `Core/`，不要把接口请求散落到视图。上游格式变化时先用不含账号的最小只读例子确认。

原生界面使用 SwiftUI，播放使用 AVFoundation，登录使用临时 WebKit 页面与本机 Keychain。`Features/` 为页面，`Playback/` 负责播放器、DASH、字幕与全屏，`Downloads/` 负责下载与导出，`Demo/` 保存离线预览逻辑与 JSON。

修改 `ios/project.yml` 后使用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 同步已提交的 Xcode 工程：

```bash
xcodegen generate --spec ios/project.yml
```

所有命令均在仓库根目录执行。

## 提交前验证

```bash
npm test
npm run build
npm run check:repo
npm run check:brand
BILIGHT_DESTINATION='platform=iOS Simulator,name=你的模拟器名称' bash ios/scripts/verify.sh test
```

默认测试使用假上游与隔离存储；不要在自动化测试中发送真实短信、投币、点赞、关注或收藏。修改播放行为时另行核对暂停、切换分 P、全屏与进度，测试通过不等于真实账号验收。

图文触控回归使用合成离线样本，不恢复账号或读取 Keychain：

```bash
xcodebuild -project ios/Bilight.xcodeproj -scheme BilightInteractionTests -destination 'platform=iOS Simulator,name=你的模拟器名称' test
```

`bash ios/scripts/verify.sh build` 构建模拟器，`archive` 生成未签名归档，`live` 是显式联网的匿名只读烟测。`python3 ios/scripts/package-source.py` 生成源码包。构建缓存默认在仓库外的 `../Local/Builds/`，交付包在被 Git 忽略的 `releases/`。

## 仓库与品牌资源

代码仓库只维护源码、开发文档及构建／测试所需资源。`releases/` 保留本地安装包和归档，不提交 Git；宣发素材、运行数据、密钥及法律研究分别保存在仓库外的 `Promotion/`、`Local/`、`Legal/`，不可复制进仓库。`npm run check:repo` 检查实际 Git 索引中的边界。

品牌唯一矢量源位于 [`branding/`](branding/README.md)。README 使用 project-mark，网页和 iPhone 使用 playback-mark，App 图标使用 app-icon；全部无天线和品牌后缀圆点。修改后运行 `npm run brand:sync`，再用 `npm run check:brand` 检查副本与引用。

## 截图与问题报告

优先使用 [离线 mock 模式](docs/demo.md) 提供截图和可复现步骤。不要上传 Cookie、刷新令牌、手机号、验证码、密钥、数据库、Keychain 导出、签名证书、设备描述文件或带有私人账号的信息。内部验收笔记及个人构建产物不纳入仓库。

预览启动方式、外部图片目录和截图流程统一维护在[演示文档](docs/demo.md)。用户 README 只保留产品功能、安装、日常使用与隐私信息，不加入截图制作、测试、品牌同步或本地工作区管理说明。

说明操作步骤、预期结果、实际结果和可公开的错误码即可。不要复制完整网络请求或含认证信息的日志。对不确定是否敏感的信息，请先在本地删除或换成明确的占位符。

## 许可

提交的原创代码与素材沿用项目 MIT 许可。复用第三方代码时保留其许可与来源，新增依赖时同步说明。不要提交 B 站内容本身作为测试或截图素材。
