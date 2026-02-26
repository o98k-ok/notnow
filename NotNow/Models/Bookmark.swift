import Foundation
import SwiftData

@Model
final class Bookmark {
    @Attribute(.unique) var id: UUID
    var url: String
    var title: String
    var desc: String
    var coverURL: String?
    @Attribute(.externalStorage) var coverData: Data?
    var tags: [String]
    var notes: String
    var isRead: Bool
    var isFavorite: Bool
    var createdAt: Date
    var updatedAt: Date
    /// Bundle identifier of the app to open this bookmark with
    var openWithApp: String?
    /// Shell command to open this bookmark; use {url} as placeholder
    var openWithScript: String?
    /// Category this bookmark belongs to
    var category: Category?
    /// Whether this bookmark is a text snippet (not a URL)
    var isSnippet: Bool
    /// The text content for snippet bookmarks
    @Attribute(.externalStorage) var snippetText: String?

    init(
        url: String,
        title: String = "",
        desc: String = "",
        coverURL: String? = nil,
        coverData: Data? = nil,
        tags: [String] = [],
        notes: String = "",
        isSnippet: Bool = false,
        snippetText: String? = nil
    ) {
        self.id = UUID()
        self.url = url
        self.title = title
        self.desc = desc
        self.coverURL = coverURL
        self.coverData = coverData
        self.tags = tags
        self.notes = notes
        self.isRead = false
        self.isFavorite = false
        self.createdAt = Date()
        self.updatedAt = Date()
        self.isSnippet = isSnippet
        self.snippetText = snippetText
    }

    var domain: String {
        URL(string: url)?.host ?? url
    }

    var hasCover: Bool {
        coverData != nil
    }
}
