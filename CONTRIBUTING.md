# 参与 Bilight

欢迎提交问题、修复或改进。产品边界是搜索与已关注内容：请不要增加推荐流、热搜、榜单、猜你喜欢或自动连播。界面交互尽量简洁，接口失败要显示真实错误。

## 开始开发

网页使用 Node.js 24，运行 `npm ci`、`npm run setup` 和 `npm run dev`。前后端共用 `shared/types.ts`；上游适配集中在 `server/transport.ts`、`server/auth.ts` 和 `server/gateway.ts`。媒体只允许登记过的本地资源标识，不接受任意远程地址。

iOS 项目位于 `ios/`，直接用 Xcode 打开；构建和账号说明见 [iPhone 文档](ios/README.md)。上游适配集中在 `Core/`，不要把接口请求散落到视图。上游格式变化时先用不含账号的最小只读例子确认。

## 提交前验证

```bash
npm test
npm run build
npm run check:repo
BILIGHT_DESTINATION='platform=iOS Simulator,name=你的模拟器名称' bash ios/scripts/verify.sh test
```

默认测试使用假上游与隔离存储；不要在自动化测试中发送真实短信、投币、点赞、关注或收藏。修改播放行为时另行核对暂停、切换分 P、全屏与进度，测试通过不等于真实账号验收。

## 截图与问题报告

优先使用 [离线 mock 模式](docs/demo.md) 提供截图和可复现步骤。不要上传 Cookie、刷新令牌、手机号、验证码、密钥、数据库、Keychain 导出、签名证书、设备描述文件或带有私人账号的信息。内部验收笔记及个人构建产物不纳入仓库。

说明操作步骤、预期结果、实际结果和可公开的错误码即可。不要复制完整网络请求或含认证信息的日志。对不确定是否敏感的信息，请先在本地删除或换成明确的占位符。

## 许可

提交的原创代码与素材沿用项目 MIT 许可。复用第三方代码时保留其许可与来源，新增依赖时同步说明。不要提交 B 站内容本身作为测试或截图素材。
