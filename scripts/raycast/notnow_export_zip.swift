#!/usr/bin/env swift

import Foundation
import SQLite3

// Required parameters:
// @raycast.schemaVersion 1
// @raycast.title NotNow Export ZIP
// @raycast.mode fullOutput
//
// Optional parameters:
// @raycast.icon 🧳
// @raycast.packageName NotNow
// @raycast.argument1 { "type": "text", "placeholder": "output path or directory (optional)", "optional": true }
//
// Documentation:
// @raycast.description Export NotNow data/config into backup ZIP (same structure as GUI export)
// @raycast.author shadow
// @raycast.authorURL https://github.com/o98k-ok

struct ExportManifest: Encodable {
    let version: Int
    let exportedAt: String
    let app: String
}

struct ExportCategory: Encodable {
    let id: String
    let name: String
    let icon: String
    let colorHex: Int
    let sortOrder: Int
    let createdAt: Date
}

struct ExportBookmark: Encodable {
    let id: String
    let url: String
    let title: String
    let desc: String
    let coverURL: String?
    let tags: [String]
    let notes: String
    let isFavorite: Bool
    let createdAt: Date
    let updatedAt: Date
    let categoryId: String?
    let openWithApp: String?
    let openWithScript: String?
    let kind: String
    let snippetContent: String
    let snippetLanguage: String?
    let snippetFormat: String?
    let isCompleted: Bool?
    let completedAt: Date?
    let dueDate: Date?
    let taskPriority: Int?
    let apiMethod: String?
    let apiHeaders: String?
    let apiBody: String?
    let apiBodyType: String?
    let apiQueryParams: String?
}

struct ExportConfig: Encodable {
    let accentTheme: String
    let aiEnabled: Bool
    let aiAPIURL: String
    let aiAPIKey: String
    let aiModel: String
}

enum ScriptError: Error {
    case message(String)
}

let fileManager = FileManager.default
let env = ProcessInfo.processInfo.environment
let args = CommandLine.arguments
let outputArg = env["ARG_OUTPUT_PATH"] ?? (args.count > 1 ? args[1] : "")
let storePath = env["NOTNOW_STORE_PATH"] ?? "\(NSHomeDirectory())/Library/Application Support/default.store"
let bundleID = env["NOTNOW_BUNDLE_ID"] ?? "com.notnow.app"

func fail(_ message: String, code: Int32 = 1) -> Never {
    fputs("Error: \(message)\n", stderr)
    exit(code)
}

func sqliteText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
    guard let cString = sqlite3_column_text(stmt, index) else { return nil }
    return String(cString: cString)
}

func sqliteBlobData(_ stmt: OpaquePointer?, _ index: Int32) -> Data? {
    let bytes = sqlite3_column_blob(stmt, index)
    let length = sqlite3_column_bytes(stmt, index)
    if bytes == nil || length <= 0 {
        return nil
    }
    return Data(bytes: bytes!, count: Int(length))
}

func sqliteOptionalDate(_ stmt: OpaquePointer?, _ index: Int32) -> Date? {
    if sqlite3_column_type(stmt, index) == SQLITE_NULL {
        return nil
    }
    let seconds = sqlite3_column_double(stmt, index)
    return Date(timeIntervalSinceReferenceDate: seconds)
}

func sqliteRequiredDate(_ stmt: OpaquePointer?, _ index: Int32) -> Date {
    let seconds = sqlite3_column_double(stmt, index)
    return Date(timeIntervalSinceReferenceDate: seconds)
}

func uuidString(from blob: Data?) -> String? {
    guard let blob, blob.count == 16 else { return nil }
    var bytes = [UInt8](blob)
    let uuid = bytes.withUnsafeMutableBytes { raw -> UUID in
        let p = raw.bindMemory(to: UInt8.self).baseAddress!
        let tuple = uuid_t(
            p[0], p[1], p[2], p[3],
            p[4], p[5],
            p[6], p[7],
            p[8], p[9],
            p[10], p[11], p[12], p[13], p[14], p[15]
        )
        return UUID(uuid: tuple)
    }
    return uuid.uuidString
}

func decodeTags(_ blob: Data?) -> [String] {
    guard let blob else { return [] }
    do {
        if let tags = try NSKeyedUnarchiver.unarchivedObject(
            ofClasses: [NSArray.self, NSString.self],
            from: blob
        ) as? [String] {
            return tags
        }
    } catch {
        return []
    }
    return []
}

func writeJSON<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder) throws {
    let data = try encoder.encode(value)
    try data.write(to: url)
}

func normalizedDestinationPath(outputArg: String, generatedZipName: String) throws -> URL {
    let trimmed = outputArg.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(generatedZipName)
    }

    let expanded = NSString(string: trimmed).expandingTildeInPath
    if expanded.lowercased().hasSuffix(".zip") {
        return URL(fileURLWithPath: expanded)
    }

    var isDir: ObjCBool = false
    if fileManager.fileExists(atPath: expanded, isDirectory: &isDir) {
        if isDir.boolValue {
            return URL(fileURLWithPath: expanded, isDirectory: true)
                .appendingPathComponent(generatedZipName)
        }
        throw ScriptError.message("output path exists but is not a directory: \(expanded)")
    }

    try fileManager.createDirectory(atPath: expanded, withIntermediateDirectories: true)
    return URL(fileURLWithPath: expanded, isDirectory: true).appendingPathComponent(generatedZipName)
}

if !fileManager.fileExists(atPath: storePath) {
    fail("NotNow store not found: \(storePath)")
}

var db: OpaquePointer?
guard sqlite3_open_v2(storePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
    let msg = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
    fail("failed to open sqlite db: \(msg)")
}
defer { sqlite3_close(db) }

let tempDir = fileManager.temporaryDirectory.appendingPathComponent("NotNowExport-\(UUID().uuidString)", isDirectory: true)
do {
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
} catch {
    fail("failed to create temp dir: \(error.localizedDescription)")
}
defer { try? fileManager.removeItem(at: tempDir) }

let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601

let manifest = ExportManifest(
    version: 1,
    exportedAt: ISO8601DateFormatter().string(from: Date()),
    app: "NotNow"
)

do {
    try writeJSON(manifest, to: tempDir.appendingPathComponent("manifest.json"), encoder: encoder)
} catch {
    fail("write manifest failed: \(error.localizedDescription)")
}

var categories: [ExportCategory] = []
let categorySQL = """
SELECT
  ZID,
  COALESCE(ZNAME, ''),
  COALESCE(ZICON, ''),
  COALESCE(ZCOLORHEX, 0),
  COALESCE(ZSORTORDER, 0),
  COALESCE(ZCREATEDAT, 0)
FROM ZCATEGORY;
"""
var categoryStmt: OpaquePointer?
guard sqlite3_prepare_v2(db, categorySQL, -1, &categoryStmt, nil) == SQLITE_OK else {
    let msg = String(cString: sqlite3_errmsg(db))
    fail("prepare category query failed: \(msg)")
}
defer { sqlite3_finalize(categoryStmt) }

while sqlite3_step(categoryStmt) == SQLITE_ROW {
    let id = uuidString(from: sqliteBlobData(categoryStmt, 0)) ?? UUID().uuidString
    let name = sqliteText(categoryStmt, 1) ?? ""
    let icon = sqliteText(categoryStmt, 2) ?? ""
    let colorHex = Int(sqlite3_column_int64(categoryStmt, 3))
    let sortOrder = Int(sqlite3_column_int64(categoryStmt, 4))
    let createdAt = sqliteRequiredDate(categoryStmt, 5)
    categories.append(
        ExportCategory(
            id: id,
            name: name,
            icon: icon,
            colorHex: colorHex,
            sortOrder: sortOrder,
            createdAt: createdAt
        )
    )
}

do {
    try writeJSON(categories, to: tempDir.appendingPathComponent("categories.json"), encoder: encoder)
} catch {
    fail("write categories failed: \(error.localizedDescription)")
}

struct RawBookmark {
    let dto: ExportBookmark
    let coverData: Data?
}

var rawBookmarks: [RawBookmark] = []
let bookmarkSQL = """
SELECT
  b.ZID,
  COALESCE(b.ZURL, ''),
  COALESCE(b.ZTITLE, ''),
  COALESCE(b.ZDESC, ''),
  b.ZCOVERURL,
  b.ZTAGS,
  COALESCE(b.ZNOTES, ''),
  COALESCE(b.ZISFAVORITE, 0),
  COALESCE(b.ZCREATEDAT, 0),
  COALESCE(b.ZUPDATEDAT, 0),
  c.ZID,
  b.ZOPENWITHAPP,
  b.ZOPENWITHSCRIPT,
  COALESCE(b.ZKIND, 'link'),
  COALESCE(b.ZSNIPPETCONTENT, ''),
  b.ZSNIPPETLANGUAGE,
  b.ZSNIPPETFORMAT,
  b.ZISCOMPLETED,
  b.ZCOMPLETEDAT,
  b.ZDUEDATE,
  b.ZTASKPRIORITY,
  b.ZAPIMETHOD,
  b.ZAPIHEADERS,
  b.ZAPIBODY,
  b.ZAPIBODYTYPE,
  b.ZAPIQUERYPARAMS,
  b.ZCOVERDATA
FROM ZBOOKMARK b
LEFT JOIN ZCATEGORY c ON c.Z_PK = b.ZCATEGORY;
"""
var bookmarkStmt: OpaquePointer?
guard sqlite3_prepare_v2(db, bookmarkSQL, -1, &bookmarkStmt, nil) == SQLITE_OK else {
    let msg = String(cString: sqlite3_errmsg(db))
    fail("prepare bookmark query failed: \(msg)")
}
defer { sqlite3_finalize(bookmarkStmt) }

while sqlite3_step(bookmarkStmt) == SQLITE_ROW {
    let bookmarkID = uuidString(from: sqliteBlobData(bookmarkStmt, 0)) ?? UUID().uuidString
    let dto = ExportBookmark(
        id: bookmarkID,
        url: sqliteText(bookmarkStmt, 1) ?? "",
        title: sqliteText(bookmarkStmt, 2) ?? "",
        desc: sqliteText(bookmarkStmt, 3) ?? "",
        coverURL: sqliteText(bookmarkStmt, 4),
        tags: decodeTags(sqliteBlobData(bookmarkStmt, 5)),
        notes: sqliteText(bookmarkStmt, 6) ?? "",
        isFavorite: sqlite3_column_int(bookmarkStmt, 7) != 0,
        createdAt: sqliteRequiredDate(bookmarkStmt, 8),
        updatedAt: sqliteRequiredDate(bookmarkStmt, 9),
        categoryId: uuidString(from: sqliteBlobData(bookmarkStmt, 10)),
        openWithApp: sqliteText(bookmarkStmt, 11),
        openWithScript: sqliteText(bookmarkStmt, 12),
        kind: sqliteText(bookmarkStmt, 13) ?? "link",
        snippetContent: sqliteText(bookmarkStmt, 14) ?? "",
        snippetLanguage: sqliteText(bookmarkStmt, 15),
        snippetFormat: sqliteText(bookmarkStmt, 16),
        isCompleted: sqlite3_column_type(bookmarkStmt, 17) == SQLITE_NULL ? nil : (sqlite3_column_int(bookmarkStmt, 17) != 0),
        completedAt: sqliteOptionalDate(bookmarkStmt, 18),
        dueDate: sqliteOptionalDate(bookmarkStmt, 19),
        taskPriority: sqlite3_column_type(bookmarkStmt, 20) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(bookmarkStmt, 20)),
        apiMethod: sqliteText(bookmarkStmt, 21),
        apiHeaders: sqliteText(bookmarkStmt, 22),
        apiBody: sqliteText(bookmarkStmt, 23),
        apiBodyType: sqliteText(bookmarkStmt, 24),
        apiQueryParams: sqliteText(bookmarkStmt, 25)
    )
    rawBookmarks.append(RawBookmark(dto: dto, coverData: sqliteBlobData(bookmarkStmt, 26)))
}

do {
    try writeJSON(rawBookmarks.map(\.dto), to: tempDir.appendingPathComponent("bookmarks.json"), encoder: encoder)
} catch {
    fail("write bookmarks failed: \(error.localizedDescription)")
}

let defaults = UserDefaults(suiteName: bundleID)
let config = ExportConfig(
    accentTheme: defaults?.string(forKey: "accentTheme") ?? "dark",
    aiEnabled: defaults?.bool(forKey: "ai.enabled") ?? false,
    aiAPIURL: defaults?.string(forKey: "ai.apiURL") ?? "",
    aiAPIKey: defaults?.string(forKey: "ai.apiKey") ?? "",
    aiModel: defaults?.string(forKey: "ai.model") ?? ""
)
do {
    try writeJSON(config, to: tempDir.appendingPathComponent("config.json"), encoder: encoder)
} catch {
    fail("write config failed: \(error.localizedDescription)")
}

let coversDir = tempDir.appendingPathComponent("covers", isDirectory: true)
do {
    try fileManager.createDirectory(at: coversDir, withIntermediateDirectories: true)
    for item in rawBookmarks {
        guard let coverData = item.coverData else { continue }
        let out = coversDir.appendingPathComponent(item.dto.id)
        try coverData.write(to: out)
    }
} catch {
    fail("write covers failed: \(error.localizedDescription)")
}

let zipName = "NotNow-backup-\(ISO8601DateFormatter().string(from: Date()).prefix(10)).zip"
let tempZipURL = tempDir.deletingLastPathComponent().appendingPathComponent(zipName)
let destinationURL: URL
do {
    destinationURL = try normalizedDestinationPath(outputArg: outputArg, generatedZipName: zipName)
} catch ScriptError.message(let msg) {
    fail(msg)
} catch {
    fail("resolve output path failed: \(error.localizedDescription)")
}

let zipProcess = Process()
zipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
zipProcess.arguments = ["-r", "-q", tempZipURL.path, "."]
zipProcess.currentDirectoryURL = tempDir
do {
    try zipProcess.run()
    zipProcess.waitUntilExit()
    guard zipProcess.terminationStatus == 0 else {
        fail("zip command failed with status \(zipProcess.terminationStatus)")
    }
} catch {
    fail("zip failed: \(error.localizedDescription)")
}

do {
    let parent = destinationURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
    if fileManager.fileExists(atPath: destinationURL.path) {
        try fileManager.removeItem(at: destinationURL)
    }
    try fileManager.copyItem(at: tempZipURL, to: destinationURL)
} catch {
    fail("copy zip failed: \(error.localizedDescription)")
}

print("""
Exported successfully.
zip=\(destinationURL.path)
bookmarks=\(rawBookmarks.count)
categories=\(categories.count)
bundle=\(bundleID)
store=\(storePath)
""")
