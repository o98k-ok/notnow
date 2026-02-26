# Snippet Bookmark 需求与方案记录

更新时间：2026-02-26

## 背景

当前 NotNow 的核心对象是 URL 书签（`link`），但有一类常见内容并不以 URL 为核心：

- 代码片段
- 语录/摘抄
- 纯文本片段

这类内容的核心字段应是内容本身（`desc/content`），而不是 `url`。

## 目标范围（本阶段）

- 支持手动逐条添加 `snippet`（不做批量导入源）
- 支持在 ZIP 备份中导出/导入 `snippet`
- 卡片展示中对代码片段提供“代码预览区”，替代封面区域，保持视觉一致性
- 打开行为遵循配置策略

## 关键产品决策

1. 对象类型
- 引入 `BookmarkKind`：`link | snippet`
- `link` 维持现有行为
- `snippet` 以内容为核心

2. 打开行为
- 打开行为应受“配置”控制（与当前 OpenService 设计一致）
- `link`：继续使用现有打开策略（浏览器/App/脚本）
- `snippet`：新增可配置动作（建议：`detail | copy | open_in_editor`）

3. 本阶段不做
- 外部导入源（Twitter/GitHub）直接生成 snippet
- 复杂协作能力

## 数据模型建议

在 `Bookmark` 上新增字段（向后兼容）：

- `kind: String`（默认 `link`）
- `snippetContent: String`（snippet 核心内容）
- `snippetLanguage: String?`（代码语言，可空）
- `snippetFormat: String?`（`code | quote | plain`）

兼容策略：
- 旧数据默认 `kind = link`
- 旧备份缺字段时使用默认值

## UI/交互建议

1. 新增入口
- “添加书签”保留
- 新增“添加片段”入口

2. 编辑页
- `link`：保持现状（URL/封面/元数据）
- `snippet`：显示内容编辑区（多行）+ 类型/语言字段

3. 卡片展示
- `link`：继续展示封面
- `snippet(code)`：卡片顶部改为代码块预览（替代封面位）
- `snippet(quote/plain)`：展示内容摘要（多行截断）

4. 搜索
- 将 `snippetContent` 纳入全文检索

## 备份导出/导入

1. 导出
- `bookmarks.json` 增加 snippet 字段输出
- 建议记录 schema/version（便于未来演进）

2. 导入
- 读取新字段
- 对旧版本备份进行默认值回填

## 技术实现建议

1. 代码高亮
- 优先方案：先上轻量实现（等宽字体 + 基础配色 + 行截断）
- 后续再评估引入成熟高亮库（减少自维护成本）

2. 实施顺序（MVP）
- 第一步：模型扩展 + CRUD + 导入导出兼容
- 第二步：卡片代码预览（无/轻高亮）
- 第三步：配置化 snippet 打开动作

## 验收清单

- 能手动新增/编辑/删除 snippet
- snippet 在列表中可正常展示与搜索
- ZIP 导出再导入后 snippet 信息完整
- 老备份导入不崩溃
- 打开行为符合配置（link/snippet 分别验证）

