# Agent Build Rule

## Rule
- 每次完成代码改动后，必须使用 `./build.sh` 进行编译验证。
- 不使用 `xcodebuild` 直接命令作为最终验证入口；统一以 `build.sh` 为准。
- 每次执行 `./build.sh` 后，在下方追加一条构建记录。

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
