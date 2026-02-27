import Foundation
import SwiftData
import SwiftUI

enum BookmarkKind: String, CaseIterable, Codable {
    case link
    case snippet
    case task
}

enum SnippetFormat: String, CaseIterable, Codable {
    case code
    case quote
    case plain
}

enum TaskPriority: Int, CaseIterable, Codable {
    case none = 0
    case low = 1
    case medium = 2
    case high = 3

    var label: String {
        switch self {
        case .none: "无"
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        }
    }

    var icon: String {
        switch self {
        case .none: "minus"
        case .low: "arrow.down"
        case .medium: "equal"
        case .high: "arrow.up"
        }
    }

    var color: Color {
        switch self {
        case .none: .secondary
        case .low: .blue
        case .medium: .orange
        case .high: .red
        }
    }
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
    /// Whether this task is completed
    var isCompleted: Bool?
    /// When this task was completed
    var completedAt: Date?
    /// Due date for task
    var dueDate: Date?
    /// Priority: 0=none, 1=low, 2=medium, 3=high
    var taskPriority: Int?

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

    var isTask: Bool {
        bookmarkKind == .task
    }

    var resolvedSnippetFormat: SnippetFormat {
        get { SnippetFormat(rawValue: snippetFormat ?? "") ?? .plain }
        set { snippetFormat = newValue.rawValue }
    }

    var snippetText: String {
        get { snippetContent ?? "" }
        set { snippetContent = newValue }
    }

    var taskCompleted: Bool {
        get { isCompleted ?? false }
        set {
            isCompleted = newValue
            completedAt = newValue ? Date() : nil
        }
    }

    var resolvedTaskPriority: TaskPriority {
        get { TaskPriority(rawValue: taskPriority ?? 0) ?? .none }
        set { taskPriority = newValue.rawValue }
    }

    var isOverdue: Bool {
        guard isTask, !taskCompleted, let due = dueDate else { return false }
        return due < Date()
    }
}
