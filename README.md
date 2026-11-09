# LinkNest

LinkNest 是一款开源的局域网照片与视频共享工具。通过手机热点或同一 Wi-Fi，Host 手机创建临时空间，访客上传、浏览并保存原始媒体文件，无需注册公网账号或上传到第三方云盘。

**相聚即刻，美好即享。**

## 下载与网站

- Android：前往 [GitHub Releases](https://github.com/wakamda6/LinkNest/releases) 下载已发布版本。
- 宣传网站：[wakamda.fun/linknest](https://wakamda.fun/linknest/)。
- 问题反馈：[GitHub Issues](https://github.com/wakamda6/LinkNest/issues)。

当前稳定版本为 `1.3.0`。Android 构建、签名和安装说明见[开发环境](docs/07-开发环境.md)。

## 主要特点

- 通过手机热点或现有 Wi-Fi 组成临时局域网。
- 原始图片和视频按字节保存，不压缩、不转码。
- Android 与 iOS 均可作为 Host 或 App 访客。
- 支持 Apple Live Photo 的成对资源传输。
- 支持多个历史空间、继续共享和本机历史管理。
- 无法安装 App 的访客可使用 Web 备用入口上传、浏览和下载单个文件。

LinkNest 不提供互联网中继、跨网络同步或公网账号体系。所有设备必须处于同一局域网；平台热点、后台运行和权限限制见[产品概述](docs/01-产品概述.md)。

## 仓库结构

```text
LinkNest/
├── docs/           产品、需求、版本与部署文档
├── host_app/       Flutter App 与内置 Web 资产
└── web/            Vue Web 备用入口源码
```

## 本地开发

环境要求和故障处理以[开发环境](docs/07-开发环境.md)为准。当前使用 Flutter `3.47.2`，Web 备用入口使用 Vue 3、Vite 和 Tailwind CSS。

运行 App：

```bash
cd host_app
flutter pub get
flutter run
```

修改 Web 备用入口：

```bash
cd web
npm ci
npm test
npm run build:host
```

`build:host` 会同步更新 `host_app/assets/web/`，请将同步后的资产与 Web 源码一并提交。

## 验证

根据改动范围运行：

```bash
cd host_app
flutter analyze
flutter test
flutter build apk
```

iOS 构建和签名需要 macOS、Xcode 与相应开发者配置。热点、扫码、媒体保存和前后台恢复等平台行为还需要真机验证。

## 文档

1. [产品概述](docs/01-产品概述.md)
2. [需求文档](docs/02-需求文档.md)
3. [变更日志](docs/03-变更日志.md)
4. [版本管理](docs/06-版本管理.md)
5. [开发环境](docs/07-开发环境.md)

## 贡献与安全

欢迎通过 [Issues](https://github.com/wakamda6/LinkNest/issues) 和 Pull Request 参与贡献，开始前请阅读[贡献指南](CONTRIBUTING.md)。安全漏洞请按照[安全说明](SECURITY.md)私密报告，不要在公开 Issue 中发布敏感细节。

## 许可证

LinkNest 使用 [Apache License 2.0](LICENSE)。项目署名见 [NOTICE](NOTICE)，第三方组件和字体说明见[第三方许可声明](THIRD_PARTY_NOTICES.md)。第三方组件仍遵循各自许可证。
