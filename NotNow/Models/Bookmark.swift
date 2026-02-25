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

    init(
        url: String,
        title: String = "",
        desc: String = "",
        coverURL: String? = nil,
        coverData: Data? = nil,
        tags: [String] = [],
        notes: String = ""
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
    }

    var domain: String {
        URL(string: url)?.host ?? url
    }

    var hasCover: Bool {
        coverData != nil
    }
}
