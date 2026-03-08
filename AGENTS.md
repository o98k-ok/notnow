# Development Principles

1. **勤劳务实** — 开发过程中有 Codex 持续监控，出现问题会强行打断；每次改动必须构建验证，不留侥幸。
2. **全面思考** — 任何代码变更都要评估是否产生负面影响或改变现有逻辑，不做"只看当前"的修改。
3. **经验丰富** — 以资深 Swift / SwiftUI 开发者的标准要求自己，具备架构设计能力，拒绝新手式写法。
4. **追求卓越** — 始终寻求更优雅的方案，而不是 can run / try run。
5. **善于合作** — 遇到瓶颈主动求助：其他 Agent、互联网、或用户本人。
6. **主人翁意识** — 项目开源，全世界可见，代码质量代表我们的水准，不容嘲笑。

# Agent Build Rule

## Rule
- 每次完成代码改动后，必须使用 `./build.sh` 进行编译验证。
- 不使用 `xcodebuild` 直接命令作为最终验证入口；统一以 `build.sh` 为准。
- 每次执行 `./build.sh` 后，必须在下方 Build Log 表格末尾追加一条构建记录。
- 每次代码修改或编辑后，必须显式告知用户已遵守本准则；即使自行判断有些准则被跳过，也必须向用户说明理由并确认是否跳过。

## Build Log
| Date (YYYY-MM-DD) | Time | Commit/Ref | Command | Result | Notes |
|---|---|---|---|---|---|
| 2026-03-04 | 15:59 | working-tree | `./build.sh` | success | 首次执行，产物输出到 `build/export/NotNow.app` |
| 2026-03-04 | 16:19 | working-tree | `./build.sh` | failed | `ContentView` 触发 type-check 超时（body 表达式过重） |
| 2026-03-04 | 16:36 | working-tree | `./build.sh` | success | 调整后重新构建通过，产物输出到 `build/export/NotNow.app` |
| 2026-03-04 | 17:56 | working-tree | `./build.sh` | success | 目录切换与编辑弹窗卡顿优化后构建通过（保留既有 `ModelContext` sendable 警告） |
| 2026-03-04 | 18:08 | working-tree | `./build.sh` | failed | 推荐全量化改造首轮编译失败（`ContentView` 括号闭合 + `AIService` actor await） |
| 2026-03-04 | 18:09 | working-tree | `./build.sh` | success | 修复编译错误后通过；存在新增 `fallbackRecommendations` 异步警告与既有 `ModelContext` 警告 |
| 2026-03-04 | 18:11 | working-tree | `./build.sh` | success | 将 `fallbackRecommendations`/`recommendationScore` 设为 `nonisolated` 后通过，仅保留既有 `ModelContext` 警告 |
| 2026-03-04 | 18:24 | working-tree | `./build.sh` | success | 推荐流程覆盖层交互完成后复验通过，仍仅保留既有 `ModelContext` sendable 警告 |
| 2026-03-06 | 10:56 | working-tree | `./build.sh` | success | Raycast Script Commands（Search/Open）接入后构建通过，仍仅保留既有 `ModelContext` sendable 警告 |
| 2026-03-06 | 10:58 | working-tree | `./build.sh` | success | Raycast 脚本 ASCII 收敛后复验通过，仍仅保留既有 `ModelContext` sendable 警告 |
| 2026-03-06 | 11:08 | working-tree | `./build.sh` | success | Raycast Search JSON + Open 精确匹配改造后通过，仍仅保留既有 `ModelContext` sendable 警告 |
| 2026-03-06 | 11:13 | working-tree | `./build.sh` | success | Search JSON 新增图片/素材字段后通过，仍仅保留既有 `ModelContext` sendable 警告 |
| 2026-03-06 | 11:35 | working-tree | `./build.sh` | success | NotNow Search 脚本新增 NeoShell list 输出（items[] + output_mode=list），兼容原 results 字段；构建通过，仅保留既有 ModelContext sendable 警告 |
| 2026-03-06 | 11:45 | working-tree | `./build.sh` | success | 修复导入流程的 ModelContext sendable 告警：导入解析放入 detached 任务，SwiftData 写入保持 MainActor。 |
| 2026-03-06 | 12:02 | working-tree | ./build.sh | success | Search 列表输出改为纯列表：移除 detail 与冗余字段，仅保留关键信息。 |
| 2026-03-06 | 22:29 | working-tree | `./build.sh` | success | `notnow_search.sh` 按卡片类型输出业务字段：移除 `items/output_mode/store`，保留 `query/total/limit/results`，并按 `link/snippet/task/api` 返回对应字段。 |
| 2026-03-06 | 22:47 | working-tree | `./build.sh` | success | 新增独立 Raycast Extension `raycast-notnow`：URL-only 搜索、按类型分组（link/snippet/task/api）、同组内非 x.com 优先、Tag 颜色高亮。 |
| 2026-03-06 | 23:05 | working-tree | `./build.sh` | success | Raycast Extension：snippet/task/api 默认 Action 改为 `notnow://edit/<id>` 打开编辑页，link 保持浏览器打开。 |
| 2026-03-06 | 23:17 | working-tree | `./build.sh` | success | 新增 `notnow://edit/<uuid>` URL Scheme：Info.plist 注册 + onOpenURL 解析 + openBookmarkByID 通知打开编辑弹窗。 |
| 2026-03-06 | 23:21 | working-tree | `./build.sh` | success | NotNow 新增 `notnow://edit/<uuid>` URL Scheme + Raycast Extension 类型下拉筛选 + 多维度搜索(url/title/desc/tags/kind/category) + 非 link 默认打开编辑弹窗 |
| 2026-03-06 | 23:47 | working-tree | `./build.sh` | success | 主窗口改为单例 `Window`，deep link 先激活现有窗口再异步投递 `openBookmarkByID`，避免 `notnow://edit/<uuid>` 打开新窗口后停在推荐页。 |
| 2026-03-07 | 00:01 | working-tree | `./build.sh` | success | Raycast deep link 收口为只使用 `Bookmark.id`，移除 URL 业务 UUID 分支，并清理未使用的 `BookmarkDetail` helper；构建通过。 |
| 2026-03-07 | 12:23 | working-tree | `./build.sh` | success | 拉取 `origin/main` 最新后构建通过，归档成功并导出到 `build/export/NotNow.app`。 |
| 2026-03-07 | 12:43 | working-tree | `./build.sh` | success | 统一按钮与点击区按下反馈：新增 `.notNowPlainInteractive` 样式并全量替换 `.plain`，书签卡片点击区加入按下态反馈。 |
| 2026-03-07 | 13:00 | working-tree | `./build.sh` | success | 修复 `TapPressFeedbackModifier` 中 `DragGesture` 吞掉 `onTapGesture` 的问题，改用 `LongPressGesture(minimumDuration: .infinity)`。 |
| 2026-03-07 | 13:15 | working-tree | `./build.sh` | success | 点击反馈全面优化：增大 feedback 值使反馈肉眼可见；卡片从 `onTapGesture` 改为 `Button` 包裹复用 ButtonStyle 反馈；删除无用 `TapPressFeedbackModifier`。 |
| 2026-03-08 | 10:30 | working-tree | `./build.sh` | success | Chromium 浏览器书签导入扩展：`.chrome` → `.browser`，新增 `ChromiumBrowserDefinition`（Chrome/Edge/Brave/Arc/Tabbit），导入弹窗增加浏览器选择 + Profile 多选。 |
| 2026-03-08 | 10:58 | working-tree | `./build.sh` | success | 修复默认浏览器选中逻辑：自动检测第一个有 Profile 的浏览器；收窄文案避免误导"多浏览器同时导入"。 |
