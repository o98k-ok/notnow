import Foundation
import SwiftData

/// User interaction events recorded against a Bookmark / KnowledgeIndex.
/// These drive learnedTerms updates and usageScore adjustments.
enum KnowledgeEventType: String, Codable, CaseIterable {
    case open           // user opened the bookmark
    case save           // user saved a candidate into their library
    case skip           // user explicitly skipped/dismissed a candidate
    case createSnippet  // user created a snippet from this content
    case createTask     // user created a task from this content
    case cite           // user cited this bookmark in an Ask response
    case expand         // user clicked "continue exploring" from this bookmark
}

@Model
final class KnowledgeEventLog {
    @Attribute(.unique) var id: UUID
    /// Foreign key to Bookmark.id
    var bookmarkID: UUID
    var eventType: String
    /// The search query or seed context that triggered this event (for term learning)
    var queryContext: String?
    var createdAt: Date

    init(bookmarkID: UUID, eventType: KnowledgeEventType, queryContext: String? = nil) {
        self.id = UUID()
        self.bookmarkID = bookmarkID
        self.eventType = eventType.rawValue
        self.queryContext = queryContext
        self.createdAt = Date()
    }

    var resolvedEventType: KnowledgeEventType {
        KnowledgeEventType(rawValue: eventType) ?? .open
    }
}
