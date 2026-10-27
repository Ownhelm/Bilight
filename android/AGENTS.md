# Android

使用 Kotlin、Jetpack Compose 和 Media3，手机直接连接 B 站。遵守上级 AGENTS.md 与 `docs/android-parity.md`，不增加推荐或自动连播。播放器由 ViewModel 持有，旋转及全屏只改变容器，不替换播放器；弹幕使用独立原生绘制时钟。

所有凭据仅由本 App 官方登录产生，使用 Android Keystore 加密并排除系统备份。退出、账号变化取消旧请求并清空会话缓存。不得读取或输出其他 App 数据及调试凭据。自动化真机测试只在 Bilight 或专门的环境检查 App 内操作；互动写入使用隔离测试，不替用户做真实三连。

SDK、Gradle缓存、模拟器和验收证据放在 `../../Local/`。`local.properties`、APK、AAB、keystore 和构建产物不得提交。构建完成不等于真实账号及播放验收。未经用户要求不提交、不推送。
