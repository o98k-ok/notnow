import AppKit
import SQLite3
import SwiftData
import SwiftUI

@main
struct NotNowApp: App {
    init() {
        Self.fixOrphanedCategoryReferences()
    }

    /// Clean up bookmarks that reference deleted categories to prevent SwiftData assertion failures.
    private static func fixOrphanedCategoryReferences() {
        let url = URL.applicationSupportDirectory.appendingPathComponent("default.store")
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }

        let sql = "UPDATE ZBOOKMARK SET ZCATEGORY = NULL WHERE ZCATEGORY IS NOT NULL AND ZCATEGORY NOT IN (SELECT Z_PK FROM ZCATEGORY)"
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    var body: some Scene {
        Window("NotNow", id: "main") {
            ContentView()
                .preferredColorScheme(AppTheme.colorScheme)
                .onOpenURL { url in
                    guard url.scheme == "notnow", url.host == "edit" else { return }
                    let path = url.pathComponents
                    guard path.count >= 2, let uuid = UUID(uuidString: path[1]) else { return }
                    NSApp.activate(ignoringOtherApps: true)
                    DispatchQueue.main.async {
                        NSApp.windows.first?.makeKeyAndOrderFront(nil)
                        NotificationCenter.default.post(
                            name: .openBookmarkByID, object: nil,
                            userInfo: ["id": uuid])
                    }
                }
        }
        .modelContainer(for: [Bookmark.self, Category.self])
        .defaultSize(width: 1100, height: 750)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建书签") {
                    NotificationCenter.default.post(
                        name: .addBookmark, object: nil)
                }
                .keyboardShortcut("n")
            }
            CommandGroup(after: .textEditing) {
                Button("命令面板") {
                    NotificationCenter.default.post(
                        name: .openCommandPalette, object: nil)
                }
                .keyboardShortcut("k", modifiers: [.command])
                
                Button("搜索书签") {
                    NotificationCenter.default.post(
                        name: .focusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
            }
            CommandGroup(after: .appSettings) {
                Button("偏好设置…") {
                    NotificationCenter.default.post(
                        name: .showSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }
    }
}

extension Notification.Name {
    static let addBookmark = Notification.Name("addBookmark")
    static let focusSearch = Notification.Name("focusSearch")
    static let showSettings = Notification.Name("showSettings")
    static let openCommandPalette = Notification.Name("openCommandPalette")
    static let modelDataDidChange = Notification.Name("modelDataDidChange")
    static let openBookmarkByID = Notification.Name("openBookmarkByID")
}
