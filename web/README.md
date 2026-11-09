# LinkNest Web 备用入口

这是由 Host App 提供的 Vue 3 Web 备用入口，用于无法安装 App 的访客上传普通媒体、浏览画廊和下载单个文件。它不是独立公网服务，也不承担完整 App 能力。

## 开发

```bash
npm ci
npm run dev
```

## 验证与同步

```bash
npm test
npm run build:host
```

`build:host` 先执行 Vite 构建，再通过 `scripts/sync-to-host.mjs` 原子更新 `../host_app/assets/web/`。Host App 实际提供的是同步后的资产，不会直接读取 `web/src/`。请将 Web 源码和同步后的资产一并提交。

功能边界、鉴权与验收记录见[需求文档](../docs/02-需求文档.md)，许可证见仓库根目录的 [LICENSE](../LICENSE)。
