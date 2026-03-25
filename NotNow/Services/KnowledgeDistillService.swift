import Foundation

// MARK: - Output Types

enum DistillSuggestedAction: String, Sendable, CaseIterable {
    case save           // add as link bookmark
    case createSnippet  // worth saving as a snippet
    case createTask     // implies an action to take
    case skip           // not useful
}

struct DistilledCandidate: Sendable, Identifiable {
    let id: UUID                        // matches ExploreCandidate.id
    let url: String
    let title: String
    let summary: String                 // AI-generated summary
    let reason: String                  // why recommended
    let relationToExisting: String      // how it relates to recalled knowledge
    let suggestedAction: DistillSuggestedAction
    let source: ExploreCandidateSource
    let seedBookmarkID: UUID?
}

// MARK: - Service

actor KnowledgeDistillService {
    static let shared = KnowledgeDistillService()

    private let batchSize = 5

    /// Distill explore candidates using existing recall results as knowledge context.
    func distill(
        candidates: [ExploreCandidate],
        recallContext: [RecallResult]
    ) async -> [DistilledCandidate] {
        guard !candidates.isEmpty else { return [] }

        // Build a compact knowledge context string from top recall results
        let contextSnippet = recallContext.prefix(5)
            .map { "- \($0.title): \($0.summary.prefix(80))" }
            .joined(separator: "\n")

        // Process in batches
        var results: [DistilledCandidate] = []
        let chunks = stride(from: 0, to: candidates.count, by: batchSize).map {
            Array(candidates[$0..<min($0 + batchSize, candidates.count)])
        }

        for chunk in chunks {
            let distilled = await distillBatch(chunk, contextSnippet: contextSnippet)
            results.append(contentsOf: distilled)
        }
        return results
    }

    // MARK: - Batch Processing

    private func distillBatch(
        _ batch: [ExploreCandidate],
        contextSnippet: String
    ) async -> [DistilledCandidate] {
        // If AI is available, use it; otherwise fall back to local distillation
        if let _ = AIConfig.load(),
           let aiResults = await aiDistill(batch, contextSnippet: contextSnippet) {
            return aiResults
        }
        // Fallback: passthrough with empty enrichment
        return batch.map { candidate in
            DistilledCandidate(
                id: candidate.id,
                url: candidate.url,
                title: candidate.title,
                summary: "",
                reason: candidate.reason,
                relationToExisting: "",
                suggestedAction: .save,
                source: candidate.source,
                seedBookmarkID: candidate.seedBookmarkID
            )
        }
    }

    private func aiDistill(
        _ batch: [ExploreCandidate],
        contextSnippet: String
    ) async -> [DistilledCandidate]? {
        struct InputItem: Encodable {
            let index: Int
            let url: String
            let title: String
            let reason: String
        }

        let inputItems = batch.enumerated().map { i, c in
            InputItem(index: i, url: c.url, title: c.title, reason: c.reason)
        }
        guard let inputJSON = try? String(data: JSONEncoder().encode(inputItems), encoding: .utf8) else {
            return nil
        }

        let contextSection = contextSnippet.isEmpty ? "（无已有知识条目）" : contextSnippet
        let prompt = """
        你是一个知识整理助手。

        用户已有的知识条目（参考）：
        \(contextSection)

        以下是待评估的候选内容：
        \(inputJSON)

        对每条候选内容，请输出：
        - summary: 50字以内的内容摘要
        - reason: 推荐理由（结合用户已有知识）
        - relation: 与用户已有知识的关系（补充、深入、对比、无关等）
        - action: 建议动作，只能是以下之一：save / createSnippet / createTask / skip

        输出格式为 JSON 数组，每项包含 index、summary、reason、relation、action 字段：
        [{"index": 0, "summary": "...", "reason": "...", "relation": "...", "action": "save"}, ...]
        只输出 JSON，不要输出任何其他内容。
        """

        guard let aiItems = await AIService.shared.distillCandidates(prompt: prompt) else { return nil }

        // Map AI results back to DistilledCandidate by index (keep first on duplicate)
        let byIndex = Dictionary(aiItems.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })

        return batch.enumerated().map { i, candidate in
            let ai = byIndex[i]
            let action: DistillSuggestedAction
            switch ai?.action {
            case "createSnippet": action = .createSnippet
            case "createTask":    action = .createTask
            case "skip":          action = .skip
            default:              action = .save
            }
            return DistilledCandidate(
                id: candidate.id,
                url: candidate.url,
                title: ai?.title ?? candidate.title,
                summary: ai?.summary ?? "",
                reason: ai?.reason ?? candidate.reason,
                relationToExisting: ai?.relation ?? "",
                suggestedAction: action,
                source: candidate.source,
                seedBookmarkID: candidate.seedBookmarkID
            )
        }
    }
}
