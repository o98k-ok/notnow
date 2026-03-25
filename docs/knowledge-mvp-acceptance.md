# 知识库 MVP 验收标准与里程碑

## 第一阶段验收标准（5 条全部满足才算 MVP 成立）

| # | 验收项 | 验证方式 |
|---|--------|----------|
| 1 | 保存一篇文章后，能在「知识探索」中召回与之相关的已有 Bookmark | 输入该文章关键词，RecallResult 列表中出现该书签 |
| 2 | 每条召回结果附带可读的相关原因（关键词命中 / 标签匹配 / summary 片段） | 目视检查 RecallRow.reason 非空且有意义 |
| 3 | 基于召回结果能生成候选扩散内容（至少 1 类：outboundLink / keywordSearch / similarTopic） | AI 关闭时仍能走 outboundLink 路径返回候选 |
| 4 | 候选内容可一键存为 Bookmark / Snippet / Task，且不会重复入库 | 点击「保存」后在主库可见；再次点击无效 |
| 5 | 用户的点击（open/save/skip）会影响对应 KnowledgeIndex.usageScore，下次召回排序有变化 | 多次 save 后 usageScore 上升，同 seed 召回时该书签排位靠前 |

## 可演示路径（Demo Script）

1. 打开 NotNow，进入「智能推荐」页
2. 点击「知识探索」按钮，打开 ExploreView
3. 输入一个已有书签涉及的主题词（如 `SwiftUI performance`）
4. 点击「探索」，观察：
   - 「已有知识匹配」区出现相关书签（Recall）
   - 「探索候选内容」区出现新内容（Explore + Distill）
5. 点击某候选的「保存」，确认主库出现该书签
6. 点击某候选的「跳过」，确认该条从列表消失
7. 重新以同一词探索，确认已保存的书签出现在召回靠前位置（usageScore 提升）

## 上线后观测指标

| 指标 | 含义 | 目标值（软性） |
|------|------|----------------|
| `KnowledgeIndex` 覆盖率 | `indexed` 条目 / 总 Bookmark 数 | > 80% |
| Recall 命中率 | 用户探索后点击了至少 1 条召回结果 | > 50% session |
| Explore 保存率 | 每次探索平均保存候选数 | ≥ 1 |
| Skip 率 | skip / (save + skip) | < 60%（过高说明候选质量差）|
| usageScore 分布 | 是否有明显分层（活跃书签 score 远高于冷书签） | 有分层 |

## 不在第一阶段范围内的内容

- 向量检索 / embedding
- 知识图谱 / 自动关系发现
- 多 Agent 协作
- 自动外网爬取
- Explore 页单独入口（目前通过推荐页按钮触发）

## 第二阶段方向（仅参考，不排期）

- 问答后一键沉淀为 Snippet
- 从 `api` 类型书签挑工具执行
- learnedTerms 驱动的个性化权重
- 索引覆盖率不足时的主动补全提示
