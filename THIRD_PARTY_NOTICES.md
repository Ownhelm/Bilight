# 第三方依赖与致谢

Bilight 原创代码与自制演示素材采用 MIT 许可。依赖分别沿用自身许可，安装包中的完整许可文件应保留；MIT 许可不覆盖 B 站商标、视频、用户头像及其他用户内容。

预览中的影视飓风、小鹿Lawrence、超Carry的柴西视频标题、封面、头像及合集信息取自公开页面，原样展示并保留[来源记录](docs/demo-content.md)。仓库外 `Promotion/DemoAssets/` 的公开素材及包含这些内容的界面截图不属于本项目原创素材，不随代码重新授权为 MIT；相关权利仍归原作者或其他权利人所有。README 在 `docs/assets/` 中保留精选界面截图，同样不改变其中第三方内容的权属。预览不捆绑原视频媒体。

| 组件 | 用途 | 上游许可 |
| :--- | :--- | :--- |
| [React](https://github.com/facebook/react) | 网页界面 | MIT |
| [Vite](https://github.com/vitejs/vite) | 前端构建 | MIT |
| [Fastify](https://github.com/fastify/fastify) | 本地 API | MIT |
| [better-sqlite3](https://github.com/WiseLibs/better-sqlite3) | SQLite 访问 | MIT |
| [ArtPlayer](https://github.com/zhw2590582/ArtPlayer) | 网页播放器与弹幕插件 | MIT |
| [dash.js](https://github.com/Dash-Industry-Forum/dash.js) | DASH 音视频 | BSD-3-Clause |
| [Phosphor Icons](https://github.com/phosphor-icons/react) | 网页图标 | MIT |
| [AndroidX / Jetpack Compose](https://github.com/androidx/androidx) | Android 界面与系统组件 | Apache-2.0 |
| [Media3](https://github.com/androidx/media) | Android 播放器 | Apache-2.0 |
| [OkHttp / Okio](https://github.com/square/okhttp) | Android 网络与流式读取 | Apache-2.0 |
| [Coil](https://github.com/coil-kt/coil) | Android 图片加载 | Apache-2.0 |
| [ZXing](https://github.com/zxing/zxing) | Android 登录二维码 | Apache-2.0，保留其附带声明 |
| [Kotlin / kotlinx.coroutines](https://github.com/Kotlin/kotlinx.coroutines) | Android 运行时与协程 | Apache-2.0 |

网页锁定的完整依赖树以 `package-lock.json` 为准；其余依赖的许可可查看各包的 LICENSE。Docker 保留 npm 包的上游许可，网页所用的主要依赖许可副本见 `docs/licenses/`。Android 依赖版本记录在 Gradle 配置中，主要依赖许可随 APK 打包在 `assets/licenses/`。iOS 使用 Apple 系统框架，没有捆绑第三方播放器 SDK。

[FocuBili](https://github.com/L1Xu4n/FocuBili) 仅作为专注观看的产品参考，未移植其代码。README 布局参考 ArtPlayer 和 Immich 的信息组织方式，未复制其设计素材或代码。
