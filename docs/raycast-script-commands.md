# Raycast Script Commands for NotNow

本文档提供最小可用方案：通过 Raycast Script Commands 读取 NotNow 本地数据，并支持“先确认、再精确打开”。

## 1) 命令说明

- `NotNow Search`：按关键词搜索 NotNow 数据，返回 JSON，不会打开页面。
- `NotNow Open`：按 target 精确打开。只有唯一命中才打开；歧义时仅返回候选，不执行打开。

兼容 NeoShell：
- `notnow_search.sh` 已包含 `@ai-shell` 元数据与 `@output list` 声明。
- 同一份输出里会提供 `items[]`（Raycast List 渲染结构）。

## 2) 前置条件

- macOS 已安装 Raycast
- 系统有 `sqlite3`（macOS 默认自带）
- NotNow 已经运行过，存在默认数据库：
  - `~/Library/Application Support/default.store`

如果你的数据库不在默认路径，可设置环境变量：

```bash
export NOTNOW_STORE_PATH="/your/custom/path/default.store"
```

## 3) 安装脚本命令

1. 在 Raycast 中打开 Script Commands 配置目录（Raycast Settings -> Extensions -> Script Commands）。
2. 将本项目脚本复制或软链进去：

```bash
# 示例：使用软链（推荐）
mkdir -p "$HOME/.config/raycast/scripts"
ln -sf "/Users/shadow/Documents/code/notnow/scripts/raycast/notnow_search.sh" "$HOME/.config/raycast/scripts/notnow_search.sh"
ln -sf "/Users/shadow/Documents/code/notnow/scripts/raycast/notnow_open.sh" "$HOME/.config/raycast/scripts/notnow_open.sh"
chmod +x "$HOME/.config/raycast/scripts/notnow_search.sh" "$HOME/.config/raycast/scripts/notnow_open.sh"
```

3. 在 Raycast 中刷新 Script Commands（或重启 Raycast）。

## 4) 使用方式

### Search（先确认）

在 Raycast 输入 `NotNow Search`，参数：

- `keyword`：关键词（必填）
- `limit`：返回条数（可选，默认 8，最大 20）

示例：

```bash
NotNow Search "hapi" 10
```

Search 返回 JSON，核心字段：

- `total`：命中总数
- `results[]`：候选列表
- `results[].id`：稳定标识（建议用于后续 Open 精确打开）
- `results[].cover_url`：卡片封面 URL（如果有）
- `results[].has_cover_data`：是否有本地封面二进制（`0/1`）
- `results[].material`：素材信息对象
- `results[].material.media_source`：`cover_url | cover_data | none`
- `results[].material.snippet_preview`：snippet 预览文本（截断）
- `results[].material.snippet_language`：snippet 语言
- `results[].material.api_method`：API 卡片方法（如 `GET`）
- `results[].material.api_body_type`：API body 类型（如 `json`）
- `items[]`：NeoShell 列表结构（含 `title/subtitle/url/accessories/detail`）

### Open（再精确打开）

`NotNow Open` 参数：

- `target`：可传 `id / title / url / keyword`
- `mode`：`auto | id | title | url | keyword`（默认 `auto`）

示例：

```bash
NotNow Open "3d0b0d0f..." id
NotNow Open "HAPI：AI Agent 全平台远程控制中心" title
NotNow Open "hapi" auto
```

`auto` 行为：

1. 先尝试 `id` 精确匹配
2. 再尝试 `url` 精确匹配
3. 再尝试 `title` 精确匹配
4. 最后尝试 `keyword` 模糊匹配

只有唯一命中才会执行 `open`。如果命中多条，会输出候选（含 `id`）并提示你用 `id` 再执行一次。

## 5) 排序规则（简化）

匹配字段：`title`、`url`、`desc`、`notes`、`snippetContent`  
权重方向：`title > url > desc/notes/snippet`，收藏与更新时间有轻微加权。

## 6) 常见问题

1. 提示找不到数据库
- 检查 `~/Library/Application Support/default.store` 是否存在
- 或设置 `NOTNOW_STORE_PATH`

2. Open 没有打开
- 当前条目可能不是 `http(s)`（如 `task://`、snippet 等）
- 或匹配结果不唯一（脚本会列出候选并要求更精确 target）

3. Raycast 里看不到命令
- 检查脚本目录是否为 Raycast 当前配置目录
- 确认脚本可执行：`chmod +x <script>`
