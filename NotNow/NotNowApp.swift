import SwiftData
import SwiftUI

@main
struct NotNowApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(AppTheme.colorScheme)
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
}
