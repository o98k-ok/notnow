import Foundation
import SwiftData

// MARK: - Export

struct NotNowExportConfig {
    var accentTheme: String
    var aiEnabled: Bool
    var aiAPIURL: String
    var aiAPIKey: String
    var aiModel: String
}

struct NotNowExportManifest: Encodable {
    let version: Int
    let exportedAt: String
    let app: String
}

struct NotNowExportCategory: Encodable {
    let id: String
    let name: String
    let icon: String
    let colorHex: Int
    let sortOrder: Int
    let createdAt: Date
}

struct NotNowExportBookmark: Encodable {
    let id: String
    let url: String
    let title: String
    let desc: String
    let coverURL: String?
    let tags: [String]
    let notes: String
    let isRead: Bool
    let isFavorite: Bool
    let createdAt: Date
    let updatedAt: Date
    let categoryId: String?
    let openWithApp: String?
    let openWithScript: String?
}

struct NotNowExportAppConfig: Codable {
    let accentTheme: String
    let aiEnabled: Bool
    let aiAPIURL: String
    let aiAPIKey: String
    let aiModel: String
}

// MARK: - Import

struct NotNowImportCategory: Decodable {
    let id: String
    let name: String
    let icon: String
    let colorHex: Int
    let sortOrder: Int
    let createdAt: Date
}

struct NotNowImportBookmark: Decodable {
    let id: String
    let url: String
    let title: String
    let desc: String
    let coverURL: String?
    let tags: [String]
    let notes: String
    let isRead: Bool
    let isFavorite: Bool
    let createdAt: Date
    let updatedAt: Date
    let categoryId: String?
    let openWithApp: String?
    let openWithScript: String?
}

struct NotNowImportStats {
    var categoriesCreated: Int
    var bookmarksCreated: Int
    var configRestored: Bool
}

enum NotNowBackupError: Error {
    case invalidZip
    case missingManifest
    case missingCategories
    case missingBookmarks
    case writeFailed(String)
    case readFailed(String)
}

// MARK: - Service

enum NotNowBackupService {
    private static let manifestFileName = "manifest.json"
    private static let categoriesFileName = "categories.json"
    private static let bookmarksFileName = "bookmarks.json"
    private static let configFileName = "config.json"
    private static let coversDirName = "covers"

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: Export

    static func export(
        bookmarks: [Bookmark],
        categories: [Category],
        config: NotNowExportConfig
    ) async -> Result<URL, NotNowBackupError> {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("NotNowExport-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempDir) }

        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            return .failure(.writeFailed("创建临时目录失败：\(error.localizedDescription)"))
        }

        let manifest = NotNowExportManifest(
            version: 1,
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            app: "NotNow"
        )
        guard let manifestData = try? encoder.encode(manifest) else {
            return .failure(.writeFailed("manifest 编码失败"))
        }
        do {
            try manifestData.write(to: tempDir.appendingPathComponent(manifestFileName))
        } catch {
            return .failure(.writeFailed("写入 manifest 失败：\(error.localizedDescription)"))
        }

        let catDtos = categories.map { c in
            NotNowExportCategory(
                id: c.id.uuidString,
                name: c.name,
                icon: c.icon,
                colorHex: c.colorHex,
                sortOrder: c.sortOrder,
                createdAt: c.createdAt
            )
        }
        guard let catData = try? encoder.encode(catDtos) else {
            return .failure(.writeFailed("categories 编码失败"))
        }
        do {
            try catData.write(to: tempDir.appendingPathComponent(categoriesFileName))
        } catch {
            return .failure(.writeFailed("写入 categories 失败：\(error.localizedDescription)"))
        }

        let bmDtos = bookmarks.map { b in
            NotNowExportBookmark(
                id: b.id.uuidString,
                url: b.url,
                title: b.title,
                desc: b.desc,
                coverURL: b.coverURL,
                tags: b.tags,
                notes: b.notes,
                isRead: b.isRead,
                isFavorite: b.isFavorite,
                createdAt: b.createdAt,
                updatedAt: b.updatedAt,
                categoryId: b.category?.id.uuidString,
                openWithApp: b.openWithApp,
                openWithScript: b.openWithScript
            )
        }
        guard let bmData = try? encoder.encode(bmDtos) else {
            return .failure(.writeFailed("bookmarks 编码失败"))
        }
        do {
            try bmData.write(to: tempDir.appendingPathComponent(bookmarksFileName))
        } catch {
            return .failure(.writeFailed("写入 bookmarks 失败：\(error.localizedDescription)"))
        }

        let appConfig = NotNowExportAppConfig(
            accentTheme: config.accentTheme,
            aiEnabled: config.aiEnabled,
            aiAPIURL: config.aiAPIURL,
            aiAPIKey: config.aiAPIKey,
            aiModel: config.aiModel
        )
        if let configData = try? encoder.encode(appConfig) {
            try? configData.write(to: tempDir.appendingPathComponent(configFileName))
        }

        let coversDir = tempDir.appendingPathComponent(coversDirName, isDirectory: true)
        try? fm.createDirectory(at: coversDir, withIntermediateDirectories: true)
        for b in bookmarks {
            guard let data = b.coverData else { continue }
            let path = coversDir.appendingPathComponent(b.id.uuidString)
            try? data.write(to: path)
        }

        let zipName = "NotNow-backup-\(ISO8601DateFormatter().string(from: Date()).prefix(10)).zip"
        let zipURL = tempDir.deletingLastPathComponent().appendingPathComponent(zipName)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-q", zipURL.path, "."]
        process.currentDirectoryURL = tempDir
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return .failure(.writeFailed("zip 命令执行失败"))
            }
        } catch {
            return .failure(.writeFailed("zip 失败：\(error.localizedDescription)"))
        }

        return .success(zipURL)
    }

    // MARK: Import

    static func `import`(from zipURL: URL, into modelContext: ModelContext) async -> Result<NotNowImportStats, NotNowBackupError> {
        let fm = FileManager.default
        let unzipDir = fm.temporaryDirectory
            .appendingPathComponent("NotNowImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: unzipDir) }

        do {
            try fm.createDirectory(at: unzipDir, withIntermediateDirectories: true)
        } catch {
            return .failure(.readFailed("创建解压目录失败：\(error.localizedDescription)"))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", zipURL.path, "-d", unzipDir.path]
        process.currentDirectoryURL = unzipDir
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return .failure(.invalidZip)
            }
        } catch {
            return .failure(.readFailed("unzip 失败：\(error.localizedDescription)"))
        }

        let categoriesURL = unzipDir.appendingPathComponent(categoriesFileName)
        let bookmarksURL = unzipDir.appendingPathComponent(bookmarksFileName)
        let configURL = unzipDir.appendingPathComponent(configFileName)
        let coversDir = unzipDir.appendingPathComponent(coversDirName, isDirectory: true)

        guard fm.fileExists(atPath: categoriesURL.path) else {
            return .failure(.missingCategories)
        }
        guard fm.fileExists(atPath: bookmarksURL.path) else {
            return .failure(.missingBookmarks)
        }

        let catData: Data
        let bmData: Data
        do {
            catData = try Data(contentsOf: categoriesURL)
            bmData = try Data(contentsOf: bookmarksURL)
        } catch {
            return .failure(.readFailed("读取 JSON 失败：\(error.localizedDescription)"))
        }

        let importCats: [NotNowImportCategory]
        let importBms: [NotNowImportBookmark]
        do {
            importCats = try decoder.decode([NotNowImportCategory].self, from: catData)
            importBms = try decoder.decode([NotNowImportBookmark].self, from: bmData)
        } catch {
            return .failure(.readFailed("解析 JSON 失败：\(error.localizedDescription)"))
        }

        var oldCategoryIdToNew: [String: Category] = [:]
        for c in importCats {
            let newCat = Category(
                name: c.name,
                icon: c.icon,
                colorHex: c.colorHex,
                sortOrder: c.sortOrder
            )
            newCat.createdAt = c.createdAt
            modelContext.insert(newCat)
            oldCategoryIdToNew[c.id] = newCat
        }

        for b in importBms {
            let cat = b.categoryId.flatMap { oldCategoryIdToNew[$0] }
            let bm = Bookmark(
                url: b.url,
                title: b.title,
                desc: b.desc,
                coverURL: b.coverURL,
                coverData: nil,
                tags: b.tags,
                notes: b.notes
            )
            bm.isRead = b.isRead
            bm.isFavorite = b.isFavorite
            bm.createdAt = b.createdAt
            bm.updatedAt = b.updatedAt
            bm.category = cat
            bm.openWithApp = b.openWithApp
            bm.openWithScript = b.openWithScript
            modelContext.insert(bm)

            let coverPath = coversDir.appendingPathComponent(b.id).path
            if fm.fileExists(atPath: coverPath), let coverData = try? Data(contentsOf: URL(fileURLWithPath: coverPath)) {
                bm.coverData = coverData
            }
        }

        var configRestored = false
        if fm.fileExists(atPath: configURL.path),
           let configData = try? Data(contentsOf: configURL),
           let config = try? decoder.decode(NotNowExportAppConfig.self, from: configData) {
            UserDefaults.standard.set(config.accentTheme, forKey: "accentTheme")
            UserDefaults.standard.set(config.aiEnabled, forKey: "ai.enabled")
            UserDefaults.standard.set(config.aiAPIURL, forKey: "ai.apiURL")
            UserDefaults.standard.set(config.aiAPIKey, forKey: "ai.apiKey")
            UserDefaults.standard.set(config.aiModel, forKey: "ai.model")
            configRestored = true
        }

        do {
            try modelContext.save()
        } catch {
            return .failure(.writeFailed("保存失败：\(error.localizedDescription)"))
        }

        return .success(NotNowImportStats(
            categoriesCreated: importCats.count,
            bookmarksCreated: importBms.count,
            configRestored: configRestored
        ))
    }
}
