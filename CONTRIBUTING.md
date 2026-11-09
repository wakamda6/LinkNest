# 参与贡献

感谢关注 LinkNest。可以通过 GitHub Issues 报告问题、提出建议，或通过 Pull Request 提交改进。

## 开始前

- 先阅读[产品概述](docs/01-产品概述.md)和[需求文档](docs/02-需求文档.md)，确认改动符合产品边界。
- 对会影响现有行为、数据或协议的改动，先在 Issue 中讨论，避免重复工作。
- 不提交真实用户照片、软著资料、签名密钥、密码、访问令牌、`.env` 或本地开发配置。
- 使用 GitHub no-reply 邮箱等你愿意公开的提交身份。

## 开发流程

1. Fork 仓库，并从 `main` 创建描述清晰的功能分支。
2. 保持改动聚焦，不顺带格式化或重构无关文件。
3. 遵循现有 Dart、Kotlin、Swift、Vue 和 Markdown 风格。
4. 更新与改动直接相关的文档；需求级变化保留稳定需求 ID。
5. 在提交说明中描述用户可理解的行为变化，而不只写文件名。

## 验证

根据改动范围选择相关检查：

```bash
cd host_app
flutter pub get
flutter analyze
flutter test
```

修改 Web 备用入口时：

```bash
cd web
npm ci
npm test
npm run build:host
```

`build:host` 会同步更新 `host_app/assets/web/`，请将对应构建资产与 Web 源码一并提交。Android/iOS 平台行为、媒体保存、热点和扫码流程需要真机验证；无法执行的检查应在 Pull Request 中明确说明。

## Pull Request

请说明改动目的、涉及范围、测试结果和未验证项目。提交即表示你有权提交这些内容，并同意按照仓库的 Apache License 2.0 提供贡献；第三方内容必须保留原有许可与署名。
