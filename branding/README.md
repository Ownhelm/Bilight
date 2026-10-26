# Bilight 品牌资源

本目录是当前品牌的唯一矢量来源，品牌文字统一为 **Bilight**，仅首字母 B 大写。标志均无天线，字标不带后缀圆点；网页、手机、文档及当前宣发截图和视频同步使用这一写法。协议、包名、容器名和登录存储键属于固定技术标识，保持兼容。

| 源文件 | 用途 |
| :--- | :--- |
| `project-mark.svg` | README、项目介绍、视频片头与封面的小电视项目 Logo |
| `playback-mark.svg` | 网页与 iPhone 首页的圆角方框加播放三角 |
| `app-icon.svg` | iPhone 安装图标的粉色底版本 |

网页直接导入源 SVG，README 直接引用源文件。手机的 PlaybackMark 和 AppIcon 是生成资源，不单独手绘；`docs/assets/logo.svg` 仅保留为自动同步的兼容路径。

修改源文件后执行 `npm run brand:sync`；生成 AppIcon 需要系统 `rsvg-convert`（librsvg），普通运行、构建和校验不依赖它。`npm run check:brand` 校验实际引用、生成图标及所有存在的工作区副本，CI 也会运行。

完整工作区另执行 `../Promotion/Video/.venv/bin/python ../Promotion/Tools/sync-brand-assets.py`，重新生成高分辨率 README 总览与品牌预览，随后检查宣发模板及当前视频。PNG／SVG 配图有输入指纹，不能只改源文件而遗漏导出。截图始终来自隔离 mock 账号；宣发图片和视频不进入代码仓库。`Promotion/Exports` 的历史版本保持原样，不再作为当前入口。
