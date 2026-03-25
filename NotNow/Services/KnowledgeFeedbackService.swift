import Foundation
import SwiftData

/// Records user interaction events and updates KnowledgeIndex scores/terms accordingly.
@MainActor
final class KnowledgeFeedbackService {
    static let shared = KnowledgeFeedbackService()

    // Score deltas per event type
    private let scoreDeltas: [KnowledgeEventType: Double] = [
        .open:          0.5,
        .save:          2.0,
        .skip:         -1.0,
        .createSnippet: 3.0,
        .createTask:    2.5,
        .cite:          2.0,
        .expand:        1.0,
    ]

    // MARK: - Public API

    /// Record an event for a bookmark and update its KnowledgeIndex.
    func record(
        event: KnowledgeEventType,
        bookmarkID: UUID,
        queryContext: String? = nil,
        context: ModelContext
    ) {
        // Insert event log entry
        let log = KnowledgeEventLog(
            bookmarkID: bookmarkID,
            eventType: event,
            queryContext: queryContext
        )
        context.insert(log)

        // Update KnowledgeIndex for this bookmark
        let descriptor = FetchDescriptor<KnowledgeIndex>(
            predicate: #Predicate { $0.bookmarkID == bookmarkID }
        )
        guard let entry = (try? context.fetch(descriptor))?.first else {
            try? context.save()
            return
        }

        // Adjust usageScore
        let delta = scoreDeltas[event] ?? 0
        entry.usageScore = max(0, entry.usageScore + delta)
        entry.updatedAt = Date()

        // Update learnedTerms from queryContext
        if let query = queryContext, !query.isEmpty {
            let newTerms = tokenizeTerms(query)
            switch event {
            case .save, .createSnippet, .createTask, .cite:
                // Positive signal: add terms
                var existing = Set(entry.learnedTerms)
                for term in newTerms {
                    existing.insert(term)
                }
                entry.learnedTerms = Array(existing.prefix(50))
            case .skip:
                // Negative signal: remove terms that match
                let skipSet = Set(newTerms)
                entry.learnedTerms = entry.learnedTerms.filter { !skipSet.contains($0) }
            default:
                break
            }
        }

        try? context.save()
    }

    /// Convenience: record a save event when user adds a candidate as a Bookmark.
    func recordSave(bookmarkID: UUID, queryContext: String? = nil, context: ModelContext) {
        record(event: .save, bookmarkID: bookmarkID, queryContext: queryContext, context: context)
    }

    /// Convenience: record a skip event.
    func recordSkip(bookmarkID: UUID, queryContext: String? = nil, context: ModelContext) {
        record(event: .skip, bookmarkID: bookmarkID, queryContext: queryContext, context: context)
    }

    /// Convenience: record an open event.
    func recordOpen(bookmarkID: UUID, queryContext: String? = nil, context: ModelContext) {
        record(event: .open, bookmarkID: bookmarkID, queryContext: queryContext, context: context)
    }

    // MARK: - Query History

    /// Fetch recent events for a bookmark (latest first).
    func recentEvents(
        for bookmarkID: UUID,
        limit: Int = 20,
        context: ModelContext
    ) -> [KnowledgeEventLog] {
        var descriptor = FetchDescriptor<KnowledgeEventLog>(
            predicate: #Predicate { $0.bookmarkID == bookmarkID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Fetch the most frequently cited query contexts (used for learned term seeding).
    func topQueryContexts(limit: Int = 10, context: ModelContext) -> [String] {
        let descriptor = FetchDescriptor<KnowledgeEventLog>(
            predicate: #Predicate {
                $0.eventType == "save" || $0.eventType == "createSnippet" || $0.eventType == "cite"
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let events = (try? context.fetch(descriptor)) ?? []
        var freq: [String: Int] = [:]
        for event in events {
            guard let q = event.queryContext, !q.isEmpty else { continue }
            freq[q, default: 0] += 1
        }
        return freq.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    // MARK: - Internal

    private func tokenizeTerms(_ text: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        return text
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { $0.count >= 2 }
    }
}
