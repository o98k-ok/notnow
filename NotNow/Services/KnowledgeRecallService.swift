import Foundation
import SwiftData

// MARK: - Output Types

struct RecallResult: Sendable, Identifiable {
    let id: UUID           // bookmarkID
    let bookmarkID: UUID
    let url: String
    let title: String
    let desc: String
    let tags: [String]
    let notes: String
    let summary: String    // from KnowledgeIndex
    let keywords: [String] // from KnowledgeIndex
    let reason: String     // human-readable why this was recalled
    let score: Double      // local relevance score (higher = more relevant)
    let usageScore: Double // behavior-driven score from KnowledgeIndex
}

// MARK: - Service

@MainActor
class KnowledgeRecallService {
    static let shared = KnowledgeRecallService()

    /// Recall bookmarks relevant to `seed`.
    /// - Parameters:
    ///   - seed: free text — URL, article text, search query, or question
    ///   - context: SwiftData model context
    ///   - maxResults: cap on returned results
    ///   - useAI: whether to run AI reranking pass (requires AIConfig to be set)
    func recall(
        seed: String,
        context: ModelContext,
        maxResults: Int = 20,
        useAI: Bool = true
    ) async -> [RecallResult] {
        let trimmed = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // 1. Fetch all indexed KnowledgeIndex entries
        let indexDescriptor = FetchDescriptor<KnowledgeIndex>(
            predicate: #Predicate { $0.status == "indexed" }
        )
        guard let indexEntries = try? context.fetch(indexDescriptor), !indexEntries.isEmpty else {
            return []
        }

        // 2. Build a lookup map bookmarkID -> KnowledgeIndex (keep last on duplicate)
        let indexByBookmarkID = Dictionary(
            indexEntries.map { ($0.bookmarkID, $0) },
            uniquingKeysWith: { _, last in last }
        )

        // 3. Fetch all bookmarks whose IDs appear in the index
        let indexedIDs = Array(indexByBookmarkID.keys)
        let bookmarkDescriptor = FetchDescriptor<Bookmark>()
        guard let allBookmarks = try? context.fetch(bookmarkDescriptor) else { return [] }
        let bookmarks = allBookmarks.filter { indexedIDs.contains($0.id) }

        // 4. Tokenize seed
        let tokens = tokenize(trimmed)

        // 5. Score each bookmark locally
        var scored: [(bookmark: Bookmark, index: KnowledgeIndex, localScore: Double)] = []
        for bookmark in bookmarks {
            guard let ki = indexByBookmarkID[bookmark.id] else { continue }
            let s = localScore(tokens: tokens, bookmark: bookmark, index: ki)
            if s > 0 {
                scored.append((bookmark, ki, s))
            }
        }

        // Sort by combined local + usageScore
        scored.sort {
            ($0.localScore + $0.index.usageScore * 0.3) >
            ($1.localScore + $1.index.usageScore * 0.3)
        }

        // Pre-filter to top candidate pool before AI pass
        let pool = Array(scored.prefix(min(120, scored.count)))
        guard !pool.isEmpty else { return [] }

        // 6. Optional AI rerank using existing AIService
        if useAI, let _ = AIConfig.load() {
            let candidates = pool.map { item in
                AIRecommendationCandidate(
                    url: item.bookmark.url,
                    title: item.bookmark.title,
                    desc: item.bookmark.desc,
                    notes: item.bookmark.notes,
                    tags: item.bookmark.tags,
                    snippet: String(item.index.summary.prefix(300))
                )
            }

            if let aiResult = await AIService.shared.recommendBookmarksTournament(
                query: trimmed,
                candidates: candidates,
                maxResults: maxResults
            ) {
                // Reorder pool by AI selection, then append remaining locals
                let aiURLs = Set(aiResult.selectedURLs.map { $0.lowercased() })
                var aiOrdered: [(Bookmark, KnowledgeIndex, Double)] = []
                var rest: [(Bookmark, KnowledgeIndex, Double)] = []
                for item in pool {
                    if aiURLs.contains(item.bookmark.url.lowercased()) {
                        aiOrdered.append(item)
                    } else {
                        rest.append(item)
                    }
                }
                // Re-sort aiOrdered by original AI URL order
                let urlOrder = Dictionary(uniqueKeysWithValues:
                    aiResult.selectedURLs.enumerated().map { ($0.element.lowercased(), $0.offset) }
                )
                aiOrdered = aiOrdered.sorted { lhs, rhs in
                    let li = urlOrder[lhs.0.url.lowercased()] ?? 999
                    let ri = urlOrder[rhs.0.url.lowercased()] ?? 999
                    return li < ri
                }
                let merged = aiOrdered + rest
                return buildResults(from: merged, tokens: tokens, aiSummary: aiResult.summary, maxResults: maxResults)
            }
        }

        // 7. Fallback: pure local results
        return buildResults(from: pool, tokens: tokens, aiSummary: nil, maxResults: maxResults)
    }

    // MARK: - Scoring

    /// Local relevance score: higher = more relevant. Returns 0 if no match.
    private func localScore(tokens: [String], bookmark: Bookmark, index: KnowledgeIndex) -> Double {
        guard !tokens.isEmpty else { return 0 }
        var score = 0.0
        let keywordsText = index.keywords.joined(separator: " ").lowercased()
        let summaryText = index.summary.lowercased()
        let plainText = index.plainText.lowercased()
        let titleText = bookmark.title.lowercased()
        let descText = bookmark.desc.lowercased()
        let notesText = bookmark.notes.lowercased()
        let tagsText = bookmark.tags.joined(separator: " ").lowercased()
        let urlText = bookmark.url.lowercased()

        for token in tokens {
            let t = token.lowercased()
            if titleText.contains(t)    { score += 4.0 }
            if keywordsText.contains(t) { score += 3.0 }
            if tagsText.contains(t)     { score += 3.0 }
            if summaryText.contains(t)  { score += 2.0 }
            if descText.contains(t)     { score += 2.0 }
            if notesText.contains(t)    { score += 2.0 }
            if urlText.contains(t)      { score += 1.0 }
            if plainText.contains(t)    { score += 1.0 }
        }

        // Boost snippet/task kinds (user-created content = higher signal)
        switch bookmark.bookmarkKind {
        case .snippet: score *= 1.3
        case .task:    score *= 1.1
        case .api, .link: break
        }

        return score
    }

    private func tokenize(_ text: String) -> [String] {
        // Split on whitespace and common punctuation; keep tokens ≥ 2 chars
        let separators = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        let tokens = text.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { $0.count >= 2 }
        // Deduplicate while preserving order
        var seen = Set<String>()
        return tokens.filter { seen.insert($0).inserted }
    }

    // MARK: - Result Building

    private func buildResults(
        from items: [(bookmark: Bookmark, index: KnowledgeIndex, localScore: Double)],
        tokens: [String],
        aiSummary: String?,
        maxResults: Int
    ) -> [RecallResult] {
        Array(items.prefix(maxResults).map { item in
            let reason = buildReason(
                tokens: tokens,
                bookmark: item.bookmark,
                index: item.index,
                aiSummary: aiSummary
            )
            return RecallResult(
                id: item.bookmark.id,
                bookmarkID: item.bookmark.id,
                url: item.bookmark.url,
                title: item.bookmark.title,
                desc: item.bookmark.desc,
                tags: item.bookmark.tags,
                notes: item.bookmark.notes,
                summary: item.index.summary,
                keywords: item.index.keywords,
                reason: reason,
                score: item.localScore,
                usageScore: item.index.usageScore
            )
        })
    }

    private func buildReason(
        tokens: [String],
        bookmark: Bookmark,
        index: KnowledgeIndex,
        aiSummary: String?
    ) -> String {
        // Surface the most specific match explanation
        let matchedKeywords = index.keywords.filter { kw in
            let lower = kw.lowercased()
            return tokens.contains { lower.contains($0) }
        }
        let matchedTags = bookmark.tags.filter { tag in
            let lower = tag.lowercased()
            return tokens.contains { lower.contains($0) }
        }

        var parts: [String] = []
        if !matchedKeywords.isEmpty {
            parts.append("关键词匹配：\(matchedKeywords.prefix(3).joined(separator: "、"))")
        }
        if !matchedTags.isEmpty {
            parts.append("标签：\(matchedTags.prefix(3).joined(separator: "、"))")
        }
        if !index.summary.isEmpty, parts.isEmpty {
            parts.append(String(index.summary.prefix(60)))
        }
        if let ai = aiSummary, !ai.isEmpty, parts.isEmpty {
            parts.append(String(ai.prefix(60)))
        }
        return parts.isEmpty ? "内容相关" : parts.joined(separator: "；")
    }
}
