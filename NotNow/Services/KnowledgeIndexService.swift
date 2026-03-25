import CryptoKit
import Foundation
import SwiftData

/// Bookmark → KnowledgeIndex indexing pipeline.
/// - Skips if contentHash unchanged and status is already .indexed
/// - Falls back to basic keyword extraction when AI is unavailable
/// - Failed entries are retried on next call
@MainActor
class KnowledgeIndexService {
    static let shared = KnowledgeIndexService()

    // MARK: - Public API

    /// Index a single bookmark. Creates or updates its KnowledgeIndex entry.
    func index(_ bookmark: Bookmark, context: ModelContext) async {
        let hash = contentHash(for: bookmark)
        let bookmarkID = bookmark.id

        let descriptor = FetchDescriptor<KnowledgeIndex>(
            predicate: #Predicate { $0.bookmarkID == bookmarkID }
        )
        let existing = try? context.fetch(descriptor)

        if let entry = existing?.first {
            // Only skip when already indexed and content hasn't changed.
            // pending/indexing states always proceed so they can be recovered.
            guard entry.indexStatus != .indexed || entry.contentHash != hash else { return }
            await performIndexing(entry: entry, bookmark: bookmark, hash: hash, context: context)
        } else {
            let entry = KnowledgeIndex(bookmarkID: bookmarkID, contentHash: hash)
            context.insert(entry)
            await performIndexing(entry: entry, bookmark: bookmark, hash: hash, context: context)
        }
    }

    /// Index all bookmarks in batch (e.g., after import).
    func indexAll(_ bookmarks: [Bookmark], context: ModelContext) async {
        for bookmark in bookmarks {
            await index(bookmark, context: context)
        }
    }

    // MARK: - Internal

    private func performIndexing(
        entry: KnowledgeIndex,
        bookmark: Bookmark,
        hash: String,
        context: ModelContext
    ) async {
        entry.indexStatus = .indexing
        entry.contentHash = hash
        entry.failureReason = nil
        entry.updatedAt = Date()

        let plainText = extractPlainText(from: bookmark)
        entry.plainText = plainText

        // Run AI off main thread so we don't block the UI
        let kindRaw = bookmark.bookmarkKind.rawValue
        let title = bookmark.title
        let basicKW = basicKeywords(from: bookmark)
        let meta = await Task.detached(priority: .background) {
            await AIService.shared.summarizeForIndex(plainText: plainText, kind: kindRaw, title: title)
        }.value

        // Back on MainActor — safe to write to SwiftData model
        if let meta {
            entry.summary = meta.summary
            entry.keywords = meta.keywords
        } else {
            entry.summary = ""
            entry.keywords = basicKW
        }

        entry.indexStatus = .indexed
        entry.updatedAt = Date()

        do {
            try context.save()
        } catch {
            entry.indexStatus = .failed
            entry.failureReason = error.localizedDescription
            NSLog("[KnowledgeIndex] save failed for %@: %@", bookmark.id.uuidString, error.localizedDescription)
        }
    }

    // MARK: - Content Hash

    func contentHash(for bookmark: Bookmark) -> String {
        var parts = [bookmark.url, bookmark.title, bookmark.desc, bookmark.notes]
        parts.append(contentsOf: bookmark.tags)
        switch bookmark.bookmarkKind {
        case .snippet:
            parts.append(bookmark.snippetContent ?? "")
        case .api:
            parts.append(bookmark.apiMethod ?? "")
            parts.append(bookmark.apiBody ?? "")
        case .task:
            if let due = bookmark.dueDate {
                parts.append(String(due.timeIntervalSinceReferenceDate))
            }
        case .link:
            break
        }
        let raw = parts.joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Plain Text Extraction

    private func extractPlainText(from bookmark: Bookmark) -> String {
        var parts: [String] = []
        if !bookmark.title.isEmpty { parts.append(bookmark.title) }
        if !bookmark.desc.isEmpty { parts.append(bookmark.desc) }
        if !bookmark.notes.isEmpty { parts.append(bookmark.notes) }
        if !bookmark.tags.isEmpty { parts.append(bookmark.tags.joined(separator: " ")) }
        switch bookmark.bookmarkKind {
        case .snippet:
            let content = bookmark.snippetContent ?? ""
            if !content.isEmpty { parts.append(content) }
        case .api:
            parts.append(bookmark.url)
            if let method = bookmark.apiMethod, !method.isEmpty { parts.append(method) }
            if let body = bookmark.apiBody, !body.isEmpty {
                parts.append(String(body.prefix(2000)))
            }
        case .link:
            parts.append(bookmark.url)
        case .task:
            break
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Fallback Keywords

    private func basicKeywords(from bookmark: Bookmark) -> [String] {
        var kw = bookmark.tags
        if bookmark.bookmarkKind == .link || bookmark.bookmarkKind == .api,
           let host = URL(string: bookmark.url)?.host {
            kw.append(host)
        }
        return kw
    }
}
