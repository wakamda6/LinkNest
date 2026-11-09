# LinkNest 图标

- 需求：REQ-1204。青绿色底，四人围拢中心星光，寓意“相聚即刻，美好即享”。
- 源图：`linknest-icon.png`，使用内置 image_gen 生成；源图保留完整画面，平台裁切由系统完成。
- 在 `host_app/` 运行 `dart run tool/generate_app_icons.dart`，按根目录配置生成 Android 普通/自适应及 iOS 各尺寸图标；生成资源一并提交。Web 不变。脚本会保留 Xcode 原设置，避免生成工具误改资源目录编译开关。
- 修改源图后重新运行生成命令并检查桌面圆形/圆角遮罩、iOS 无透明通道。安装后桌面可能需要重新加载图标。

生成提示词：

> Use case: logo-design. Create one production-ready square 1024x1024 mobile app icon asset for LinkNest, a friendly offline photo-sharing app for friends and family gathered together. Meaning: gather instantly, share beautiful moments (相聚即刻，美好即享). Full-bleed opaque solid deep teal background #006A60, all the way to all four square corners. A single distinctive centered white rounded emblem: four softly interlocking curved petal/embrace shapes gathering inward, subtly suggesting people together and a photo aperture, with a tiny warm pale-gold sparkle in the center representing a shared beautiful moment. Sophisticated simple generous geometry, warm approachable Scandinavian-style visual identity, crisp smooth edges, very restrained subtle depth, strong contrast and legibility as a tiny launcher icon. Keep the entire foreground emblem within the central 56 percent of the square with generous plain teal margins so circular Android masks cannot crop it. No words, no letters, no text, no watermark, no frame, no inset rounded-square tile, no mockup, no surrounding canvas. Deliver the actual icon only.
