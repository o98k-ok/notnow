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
