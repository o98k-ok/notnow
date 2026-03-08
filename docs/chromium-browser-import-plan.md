# Chromium 浏览器书签导入扩展方案

## Summary

将现有“Chrome 导入”升级为“浏览器书签导入”，覆盖 macOS 上常见 Chromium 系列浏览器，采用“浏览器选择 + 自动发现 profile”交互。v1 目标包含 Chrome、Edge、Brave、Arc、Tabbit 这类使用 `Bookmarks` JSON 的浏览器；不做 Safari/Firefox，也不做用户手填任意目录作为主流程。

## Key Changes

- 将 `ImportSource.chrome` 重命名为更通用的浏览器来源，文案层面显示“浏览器书签”或“Chromium 浏览器”。
- 导入说明改为“从本机 Chromium 系浏览器书签中导入，支持多浏览器、多 Profile”。
- 把当前 `ChromeBookmarksImporter` 抽象为通用 importer。
- 新增浏览器描述类型，至少包含 `id`、展示名、用户数据根目录相对路径、图标或文案。
- 内置支持列表至少包含：Chrome、Edge、Brave、Arc、Tabbit。
- 路径规则统一走 `~/Library/Application Support/<BrowserRoot>/`，profile 扫描继续支持 `Default` 和 `Profile *`。
- 仅把存在 `Bookmarks` 文件的 profile 视为可导入项。
- 导入弹窗新增两级选择：
  - 第一级选择导入源为“浏览器书签”。
  - 第二级在该来源下显示“浏览器选择”与“可用 Profile 列表”。
  - 若某浏览器未发现任何 profile，显示空态提示并禁用“开始导入”。
  - 默认优先选中第一个检测到可用 profile 的浏览器；若当前浏览器有多个 profile，则允许多选 profile，导入时合并结果。
- 导入执行逻辑改为基于“所选浏览器 + 所选 profile 文件列表”读取，而不是固定读取 Chrome 全部 profile。
- 导入后的业务行为保持不变：
  - 仍统一导入为 `link` 类型。
  - 仍沿用现有 URL 去重、分类归属、元数据补全和提示文案逻辑。
- 文档同步更新：
  - `README.md` 与 `docs/bookmark-features.md` 中把“Chrome 书签”改为“Chromium 浏览器书签”。
  - 明确列出 v1 支持的浏览器示例，并注明 Safari/Firefox 暂不支持。

## Public Interfaces / Types

- `ImportSource`
  - 将 `.chrome` 替换为更通用的浏览器来源枚举值。
  - 更新 `title`、`description`、`systemImageName`。
- 新增浏览器元数据类型，例如 `BrowserBookmarkSource` 或 `ChromiumBrowserDefinition`
  - 字段至少包含 `id`、`title`、`relativeUserDataPath`。
- 通用 importer 接口改为显式接收目标文件列表或浏览器/profile 选择结果，而不是内部写死 Chrome 根目录扫描。
- `ImportBookmarksSheet` 增加浏览器选择状态与 profile 选择状态的绑定输入。

## Test Plan

- 静态或单元层面验证：
  - 给定多个浏览器根目录时，仅识别存在 `Bookmarks` 的 `Default` / `Profile *`。
  - 同一浏览器多个 profile 可被正确枚举。
  - `Tabbit` 路径 `~/Library/Application Support/Tabbit/Default/Bookmarks` 能被识别。
  - 不存在目录、无权限、坏 JSON、空书签文件时返回空结果或失败提示，不崩溃。
- UI / 流程验证：
  - 导入弹窗选择“浏览器书签”后，能看到浏览器列表和 profile 列表。
  - 无可用浏览器时按钮禁用且有明确提示。
  - 选择单个 profile / 多个 profile 后都能触发导入。
- 回归验证：
  - 原 Chrome 多 profile 导入行为不退化。
  - GitHub Stars、Twitter Likes、NotNow 备份三种导入不受影响。
  - 完成实现后必须执行 `./build.sh` 作为最终验证，并按仓库规则追加构建记录。

## Assumptions

- v1 只支持 Chromium 风格 `Bookmarks` JSON；Safari/Firefox 留到后续单独做。
- profile 扫描规则继续限定 `Default` 和 `Profile *`，不额外兼容更特殊目录命名，除非某个已知浏览器明确需要。
- 主流程不加入“手动选任意 `Bookmarks` 文件”；如果后续需要兜底，再在同一抽象上补一个手动文件入口。
- 浏览器支持名单采用内置白名单，不做全盘模糊扫描 `~/Library/Application Support`，避免误识别和 UI 噪音。
