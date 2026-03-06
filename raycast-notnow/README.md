# NotNow URL Search (Raycast Extension)

独立的 Raycast Extension（非 Script Command）：

- 默认仅按 `URL` 字段搜索
- 结果按类型分组：`link -> snippet -> task -> api`
- 每组内默认非 `x.com` 结果优先
- 支持 Tag 颜色高亮（按 tag 文本稳定映射）

## 1) 开发运行

```bash
cd raycast-notnow
npm install
npm run dev
```

## 2) 偏好设置

命令 `Search NotNow URL` 支持以下 Preferences：

- `Store Path`：默认 `~/Library/Application Support/default.store`
- `Max Results`：默认 `200`
- `Include x.com Results`：默认开启（开启时降权但保留）

## 3) 团队分发建议

```bash
cd raycast-notnow
npm install
npm run build
```

将本目录纳入仓库后，团队成员拉取代码后按上面步骤运行即可。
