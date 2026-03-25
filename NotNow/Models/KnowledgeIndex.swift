import Foundation
import SwiftData

/// Indexing status state machine
enum KnowledgeIndexStatus: String, Codable {
    case pending   // needs (re)indexing
    case indexing  // in progress
    case indexed   // ready for recall
    case failed    // last attempt failed
}

/// Derived knowledge document from a Bookmark.
/// Bookmark is always the source of truth. This is a cache/index layer.
@Model
final class KnowledgeIndex {
    @Attribute(.unique) var id: UUID
    /// Foreign key to Bookmark.id (loose coupling — no SwiftData relationship)
    var bookmarkID: UUID
    /// SHA256 of the content used to build this index; used to detect stale entries
    var contentHash: String
    var status: String
    /// Full extracted plain text (stored externally to avoid bloating the row)
    @Attribute(.externalStorage) var plainText: String
    /// AI-generated summary
    var summary: String
    /// Extracted keywords and topics
    var keywords: [String]
    /// Behavior-driven relevance score; increases with open/save/cite events
    var usageScore: Double
    /// Terms learned from user feedback (skips, saves, citations)
    var learnedTerms: [String]
    var failureReason: String?
    var createdAt: Date
    var updatedAt: Date

    init(bookmarkID: UUID, contentHash: String) {
        self.id = UUID()
        self.bookmarkID = bookmarkID
        self.contentHash = contentHash
        self.status = KnowledgeIndexStatus.pending.rawValue
        self.plainText = ""
        self.summary = ""
        self.keywords = []
        self.usageScore = 0.0
        self.learnedTerms = []
        self.failureReason = nil
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var indexStatus: KnowledgeIndexStatus {
        get { KnowledgeIndexStatus(rawValue: status) ?? .pending }
        set { status = newValue.rawValue }
    }
}
