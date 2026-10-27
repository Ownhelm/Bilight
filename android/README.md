# Bilight Android

Android 客户端使用 Kotlin、Jetpack Compose 和 Media3，直接连接 B 站，不依赖 Mac 后端或 Docker，已提供可安装的签名 APK。支持搜索、关注动态、UP 主投稿与合集、收藏、云端历史、视频播放和离线下载；详细验收记录见 `../docs/android-parity.md`。

## 预览版安装

GitHub Release 提供 Android 8.0 及以上可安装的签名 APK。下载后打开文件，按系统提示允许该来源安装即可，不需要开发者选项或 USB 调试。预览 APK 使用项目开发签名，Release 构建关闭调试；从同一发布来源获取的后续版本可覆盖更新。自行构建时使用自己的签名，通常无法直接覆盖 GitHub 安装包。

## 构建与安装

安装 Android Studio、SDK Platform 36、Build Tools 36.0.0 和 Platform Tools，按 Google 提示阅读并接受 SDK 许可。设置 `ANDROID_HOME` 指向 SDK，`JAVA_HOME` 指向 Android Studio 内置 JBR 或兼容 JDK。Gradle Wrapper 会使用工程需要的 Java 工具链。

在代码仓库根目录运行：

```sh
npm run android:test
npm run android:build
npm run android:install
```

安装命令默认选择唯一的 USB 安卓真机。存在多个设备时用 `ANDROID_SERIAL` 指定目标。APK 位于 `android/app/build/outputs/apk/debug/`，不进入 Git；调试签名只用于本地开发，正式发布需另行配置自己的签名密钥。

手机需开启开发者选项、USB 调试并确认电脑授权。部分小米系统还需允许 USB 安装；安装脚本使用非流式安装，兼容不显示安装弹窗的机型。如系统仍要求确认，请本人允许。不需要 root、解锁 Bootloader 或读取其他 App 的权限。

## 下载

视频页右侧的下载图标可选择当前分P及可用画质。“我的下载”支持暂停、继续、重新下载、离线观看和导出 MP4。文件保存在 App 内，卸载会删除；重要文件请先导出。下载通知权限可自行选择，不需要相册或整个文件存储的访问权限。

## 数据与测试边界

登录默认直接显示二维码，由本人用另一台设备的 B 站 App 扫码并确认；同机登录可切换「手机验证」进入官方页面。二维码过期或失败时可重新获取。会话用 Android Keystore 加密并排除系统备份，不从电脑或其他 App 导入 Cookie。自动化验证不替用户进行真实关注、点赞、投币或收藏。开发工具、模拟器、截图和设备验收记录留在源码仓库外的 `Local/`。
