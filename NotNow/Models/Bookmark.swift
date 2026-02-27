import Foundation
import SwiftData

enum BookmarkKind: String, CaseIterable, Codable {
    case link
    case snippet
}

enum SnippetFormat: String, CaseIterable, Codable {
    case code
    case quote
    case plain
}

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
    var isFavorite: Bool
    var createdAt: Date
    var updatedAt: Date
    /// Bundle identifier of the app to open this bookmark with
    var openWithApp: String?
    /// Shell command to open this bookmark; use {url} as placeholder
    var openWithScript: String?
    /// Category this bookmark belongs to
    var category: Category?
    /// `link` or `snippet`
    var kind: String?
    /// snippet core content
    var snippetContent: String?
    /// language for code snippet
    var snippetLanguage: String?
    /// `code | quote | plain`
    var snippetFormat: String?

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
        self.isFavorite = false
        self.createdAt = Date()
        self.updatedAt = Date()
        self.kind = nil
        self.snippetContent = nil
        self.snippetLanguage = nil
        self.snippetFormat = nil
    }

    var domain: String {
        if isSnippet { return "Snippet" }
        return URL(string: url)?.host ?? url
    }

    var hasCover: Bool {
        coverData != nil
    }

    var bookmarkKind: BookmarkKind {
        get { BookmarkKind(rawValue: kind ?? "") ?? .link }
        set { kind = newValue.rawValue }
    }

    var isSnippet: Bool {
        bookmarkKind == .snippet
    }

    var resolvedSnippetFormat: SnippetFormat {
        get { SnippetFormat(rawValue: snippetFormat ?? "") ?? .plain }
        set { snippetFormat = newValue.rawValue }
    }

    var snippetText: String {
        get { snippetContent ?? "" }
        set { snippetContent = newValue }
    }
}
