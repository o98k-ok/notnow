import AppKit
import Foundation

enum OpenService {
    /// Open a bookmark using its configured method, falling back to default browser
    static func open(_ bookmark: Bookmark) {
        guard let url = URL(string: bookmark.url) else { return }

        if let script = bookmark.openWithScript, !script.isEmpty {
            runScript(script, url: url)
        } else if let bundleID = bookmark.openWithApp, !bundleID.isEmpty {
            openWithApp(url: url, bundleID: bundleID)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Open URL with a specific application by bundle identifier
    static func openWithApp(url: URL, bundleID: String) {
        guard
            let appURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleID)
        else {
            NSWorkspace.shared.open(url)
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
    }

    /// Run a shell command, replacing {url} with the bookmark URL
    static func runScript(_ script: String, url: URL) {
        let command = script.replacingOccurrences(of: "{url}", with: url.absoluteString)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try? process.run()
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
