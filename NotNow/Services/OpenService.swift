import AppKit
import Foundation

/// Click action types for bookmarks
enum ClickAction: String, CaseIterable, Codable {
    case browser = "browser"
    case copy = "copy"
    case edit = "edit"
    case script = "script"

    var label: String {
        switch self {
        case .browser: return "浏览器打开"
        case .copy: return "复制"
        case .edit: return "编辑"
        case .script: return "自定义脚本"
        }
    }
}

enum OpenService {
    /// Get the text content for a bookmark (URL for links, snippet text for snippets)
    static func textFor(_ bookmark: Bookmark) -> String {
        if bookmark.isSnippet {
            return bookmark.snippetText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return bookmark.url
    }

    /// Resolve the click action for a bookmark.
    /// Card-level custom script overrides global settings.
    static func resolveAction(for bookmark: Bookmark, isCmdClick: Bool) -> ClickAction {
        if let script = bookmark.openWithScript, !script.isEmpty {
            return .script
        }

        // Task type always opens edit dialog
        if bookmark.isTask {
            return .edit
        }

        let key: String
        if bookmark.isSnippet {
            key = isCmdClick ? "snippet.cmdClickAction" : "snippet.clickAction"
        } else {
            key = isCmdClick ? "link.cmdClickAction" : "link.clickAction"
        }

        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        if let action = ClickAction(rawValue: raw) { return action }

        // Defaults: link click → browser, snippet click → copy, cmd+click → edit
        if isCmdClick { return .edit }
        return bookmark.isSnippet ? .copy : .browser
    }

    /// Resolve the script command for an action.
    /// Card-level script overrides global settings.
    static func resolveScript(for bookmark: Bookmark, isCmdClick: Bool) -> String {
        // Task type doesn't support scripts
        if bookmark.isTask {
            return ""
        }

        if let script = bookmark.openWithScript, !script.isEmpty {
            return script
        }

        let key: String
        if bookmark.isSnippet {
            key = isCmdClick ? "snippet.cmdClickScript" : "snippet.clickScript"
        } else {
            key = isCmdClick ? "link.cmdClickScript" : "link.clickScript"
        }

        return UserDefaults.standard.string(forKey: key) ?? ""
    }

    /// Execute a click action. Returns `false` when action is `.edit` (caller must show detail sheet).
    static func executeAction(_ action: ClickAction, bookmark: Bookmark, isCmdClick: Bool) -> Bool {
        let text = textFor(bookmark)

        switch action {
        case .browser:
            if let url = URL(string: bookmark.url) {
                NSWorkspace.shared.open(url)
            }
            return true

        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return true

        case .edit:
            return false

        case .script:
            let script = resolveScript(for: bookmark, isCmdClick: isCmdClick)
            guard !script.isEmpty else { return true }
            runTextScript(script, text: text)
            return true
        }
    }

    /// Run a shell command, replacing {TEXT} with the text content.
    /// Also supports legacy {url} placeholder for backward compatibility.
    static func runTextScript(_ script: String, text: String) {
        let command = script
            .replacingOccurrences(of: "{TEXT}", with: text)
            .replacingOccurrences(of: "{url}", with: text)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try? process.run()
    }

    /// Simple open: browser for links, copy for snippets, open linked URL for tasks.
    /// Used by context menu and detail sheet.
    static func open(_ bookmark: Bookmark) {
        if bookmark.isTask {
            guard !bookmark.url.hasPrefix("task://"),
                  let url = URL(string: bookmark.url) else { return }
            NSWorkspace.shared.open(url)
            return
        }

        if bookmark.isSnippet {
            let content = bookmark.snippetText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(content, forType: .string)
            return
        }

        guard let url = URL(string: bookmark.url) else { return }
        NSWorkspace.shared.open(url)
    }

    /// List installed applications that can open URLs
    static func availableBrowsers() -> [(name: String, bundleID: String)] {
        guard let httpURL = URL(string: "https://example.com") else { return [] }
        let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: httpURL)
        return appURLs.compactMap { appURL in
            guard let bundle = Bundle(url: appURL),
                let bundleID = bundle.bundleIdentifier,
                let name = bundle.infoDictionary?["CFBundleName"] as? String
                    ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
            else { return nil }
            return (name: name, bundleID: bundleID)
        }
        .sorted { $0.name < $1.name }
    }
}
