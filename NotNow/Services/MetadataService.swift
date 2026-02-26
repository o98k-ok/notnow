import Foundation

struct BookmarkMetadata {
    var title: String?
    var description: String?
    var imageURL: String?
    var imageData: Data?
}

actor MetadataService {
    static let shared = MetadataService()
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 18
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    func fetch(from urlString: String, fetchImage: Bool = true) async -> BookmarkMetadata {
        guard let url = URL(string: urlString) else {
            NSLog("[Meta] invalid URL: %@", urlString)
            return BookmarkMetadata()
        }

        do {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")

            let (data, response) = try await session.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            NSLog("[Meta] HTTP %d, data size: %d bytes", httpResponse?.statusCode ?? 0, data.count)
            if let statusCode = httpResponse?.statusCode, !(200...299).contains(statusCode) {
                NSLog("[Meta] unexpected status code: %d", statusCode)
                return BookmarkMetadata()
            }

            let htmlEncoding = stringEncoding(from: httpResponse?.textEncodingName)
            guard let html = String(data: data, encoding: htmlEncoding)
                ?? String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .unicode)
                ?? String(data: data, encoding: .ascii)
            else {
                NSLog("[Meta] failed to decode HTML")
                return BookmarkMetadata()
            }
            NSLog("[Meta] HTML length: %d chars", html.count)

            let title =
                extractMeta(from: html, attr: "property", value: "og:title")
                ?? extractMeta(from: html, attr: "name", value: "title")
                ?? extractHTMLTitle(from: html)
            NSLog("[Meta] title: %@", title ?? "nil")

            let description =
                extractMeta(from: html, attr: "property", value: "og:description")
                ?? extractMeta(from: html, attr: "name", value: "description")
            NSLog("[Meta] desc: %@", String(description?.prefix(60) ?? "nil"))

            var imageURLStr =
                extractMeta(from: html, attr: "property", value: "og:image")
                ?? extractMeta(from: html, attr: "name", value: "twitter:image")
                ?? extractMeta(from: html, attr: "name", value: "twitter:image:src")
            NSLog("[Meta] og:image raw: %@", imageURLStr ?? "nil")

            var imageData: Data?
            if fetchImage, let imgStr = imageURLStr {
                imageURLStr = resolvedImageURL(from: imgStr, baseURL: url)?.absoluteString
                if let resolvedURL = imageURLStr, let data = await fetchImageData(from: resolvedURL) {
                    imageData = data
                }
            } else if let imgStr = imageURLStr {
                imageURLStr = resolvedImageURL(from: imgStr, baseURL: url)?.absoluteString
            }

            NSLog("[Meta] result: title=%d, desc=%d, image=%d", title != nil ? 1 : 0, description != nil ? 1 : 0, imageData != nil ? 1 : 0)
            return BookmarkMetadata(
                title: title, description: description,
                imageURL: imageURLStr, imageData: imageData
            )
        } catch {
            NSLog("[Meta] error: %@", error.localizedDescription)
            return BookmarkMetadata()
        }
    }

    func fetchImageData(from urlString: String) async -> Data? {
        guard let imageURL = URL(string: urlString) else {
            NSLog("[Meta] invalid image URL: %@", urlString)
            return nil
        }
        NSLog("[Meta] fetching image: %@", imageURL.absoluteString)
        do {
            var imgReq = URLRequest(url: imageURL, timeoutInterval: 6)
            imgReq.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
            let (imgData, imgResp) = try await session.data(for: imgReq)
            let imgHTTP = imgResp as? HTTPURLResponse
            NSLog("[Meta] image HTTP %d, size: %d, type: %@", imgHTTP?.statusCode ?? 0, imgData.count, imgHTTP?.value(forHTTPHeaderField: "Content-Type") ?? "?")
            if let statusCode = imgHTTP?.statusCode, !(200...299).contains(statusCode) {
                NSLog("[Meta] image status not ok: %d", statusCode)
                return nil
            }
            return imgData.count > 100 ? imgData : nil
        } catch {
            NSLog("[Meta] image download failed: %@", error.localizedDescription)
            return nil
        }
    }

    func fetchHTMLSnippet(from urlString: String, maxLength: Int = 4000) async -> String? {
        guard let url = URL(string: urlString) else {
            NSLog("[Meta] invalid URL for snippet: %@", urlString)
            return nil
        }
        do {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")

            let (data, response) = try await session.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            NSLog("[Meta] snippet HTTP %d, data size: %d bytes", httpResponse?.statusCode ?? 0, data.count)
            if let statusCode = httpResponse?.statusCode, !(200...299).contains(statusCode) {
                NSLog("[Meta] snippet unexpected status code: %d", statusCode)
                return nil
            }

            let htmlEncoding = stringEncoding(from: httpResponse?.textEncodingName)
            guard let html = String(data: data, encoding: htmlEncoding)
                ?? String(data: data, encoding: .utf8)
            else {
                NSLog("[Meta] snippet failed to decode HTML")
                return nil
            }
            let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            return String(trimmed.prefix(maxLength))
        } catch {
            NSLog("[Meta] snippet error: %@", error.localizedDescription)
            return nil
        }
    }

    // MARK: - HTML Parsing (NSRegularExpression with capture groups)

    private func extractMeta(from html: String, attr: String, value: String) -> String? {
        let esc = NSRegularExpression.escapedPattern(for: value)
        let patterns = [
            // <meta property="og:title" content="...">
            "<meta\\s[^>]*\(attr)\\s*=\\s*[\"']\(esc)[\"'][^>]*content\\s*=\\s*[\"']([^\"']*)[\"']",
            // <meta content="..." property="og:title">
            "<meta\\s[^>]*content\\s*=\\s*[\"']([^\"']*)[\"'][^>]*\(attr)\\s*=\\s*[\"']\(esc)[\"']",
        ]
        let nsHTML = html as NSString
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) else { continue }
            guard let match = regex.firstMatch(
                in: html, range: NSRange(location: 0, length: nsHTML.length)
            ) else { continue }
            guard match.numberOfRanges > 1 else { continue }
            let range = match.range(at: 1)
            guard range.location != NSNotFound else { continue }
            let result = nsHTML.substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .decodingHTMLEntities()
            if !result.isEmpty { return result }
        }
        return nil
    }

    private func extractHTMLTitle(from html: String) -> String? {
        let pattern = "<title[^>]*>([^<]+)</title>"
        let nsHTML = html as NSString
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        guard let match = regex.firstMatch(
            in: html, range: NSRange(location: 0, length: nsHTML.length)
        ) else { return nil }
        guard match.numberOfRanges > 1 else { return nil }
        let range = match.range(at: 1)
        guard range.location != NSNotFound else { return nil }
        return nsHTML.substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .decodingHTMLEntities()
    }

    private func stringEncoding(from textEncodingName: String?) -> String.Encoding {
        guard let textEncodingName else { return .utf8 }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(textEncodingName as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return .utf8 }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    private func resolvedImageURL(from raw: String, baseURL: URL) -> URL? {
        if raw.hasPrefix("http") {
            return URL(string: raw)
        }
        if raw.hasPrefix("//") {
            return URL(string: "https:" + raw)
        }
        return URL(string: raw, relativeTo: baseURL)?.absoluteURL
    }
}

private extension String {
    func decodingHTMLEntities() -> String {
        var s = self
        let map: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&#x27;", "'"), ("&#x2F;", "/"), ("&nbsp;", " "),
        ]
        for (entity, char) in map {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        // Numeric entities: &#123; or &#x1F;
        if let regex = try? NSRegularExpression(pattern: "&#(x?[0-9a-fA-F]+);") {
            let ns = s as NSString
            let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            for m in matches.reversed() {
                let codeStr = ns.substring(with: m.range(at: 1))
                let codeVal: UInt32?
                if codeStr.hasPrefix("x") {
                    codeVal = UInt32(String(codeStr.dropFirst()), radix: 16)
                } else {
                    codeVal = UInt32(codeStr)
                }
                if let cv = codeVal, let scalar = Unicode.Scalar(cv) {
                    s = (s as NSString).replacingCharacters(
                        in: m.range, with: String(Character(scalar))
                    )
                }
            }
        }
        return s
    }
}

// MARK: - AI integration (BYOK)

struct AITitleDescription {
    let title: String?
    let desc: String?
    let tags: [String]?
}

struct AIConfig {
    let apiURL: URL
    let apiKey: String
    let model: String

    static func load() -> AIConfig? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "ai.enabled") else { return nil }
        guard
            let urlString = defaults.string(forKey: "ai.apiURL")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !urlString.isEmpty,
            let url = URL(string: urlString)
        else {
            NSLog("[AI] config missing or invalid apiURL")
            return nil
        }
        let key = defaults.string(forKey: "ai.apiKey") ?? ""
        let model = (defaults.string(forKey: "ai.model") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            NSLog("[AI] config missing model (ai.model)")
            return nil
        }
        return AIConfig(apiURL: url, apiKey: key, model: model)
    }
}

actor AIService {
    static let shared = AIService()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 25
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private func storeLog(_ log: String) {
        UserDefaults.standard.set(log, forKey: "ai.lastLog")
    }

    func refineTitleAndDescription(
        for url: String, originalTitle: String, originalDesc: String
    ) async -> AITitleDescription? {
        var logLines: [String] = []
        logLines.append("AI request started")
        logLines.append("url = \(url)")
        logLines.append("original_title = \(originalTitle)")
        logLines.append("original_description = \(originalDesc)")

        guard let cfg = AIConfig.load() else {
            logLines.append("config = missing or disabled (ai.enabled=false / invalid URL / empty model)")
            let log = logLines.joined(separator: "\n")
            storeLog(log)
            return nil
        }
        logLines.append("apiURL = \(cfg.apiURL.absoluteString)")
        logLines.append("apiKey.present = \(!cfg.apiKey.isEmpty)")
        logLines.append("model = \(cfg.model)")

        guard let htmlSnippet = await MetadataService.shared.fetchHTMLSnippet(from: url) else {
            let msg = "[AI] no HTML snippet, skip"
            NSLog("%@", msg)
            logLines.append("error = no HTML snippet fetched")
            let log = logLines.joined(separator: "\n")
            storeLog(log)
            return nil
        }
        logLines.append("html_snippet.length = \(htmlSnippet.count)")

        struct ChatRequest: Encodable {
            struct Message: Encodable {
                let role: String
                let content: String
            }
            let model: String
            let messages: [Message]
            let temperature: Double
        }

        let systemPrompt =
            """
            你是一个为稍后阅读应用生成中文标题、简介和标签的助手。
            请只输出一个 JSON 对象，不要输出多余文字，格式为：
            {
              "title": "字符串，书签标题",
              "description": "字符串，摘要描述，不超过 80 个中文字符",
              "tags": ["tag1", "tag2", ...]  // 可选，0~5 个短标签
            }
            tags 应该是简短的中文或英文关键词，例如 ["AI", "生产力", "Swift"]，不要包含空字符串或重复项。
            """
        let userContent = """
        URL: \(url)

        原始标题: \(originalTitle)
        原始描述: \(originalDesc)

        HTML 内容片段:
        \(htmlSnippet)
        """

        let body = ChatRequest(
            model: cfg.model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userContent),
            ],
            temperature: 0.3
        )

        guard let payload = try? JSONEncoder().encode(body) else {
            let msg = "[AI] encode request failed"
            NSLog("%@", msg)
            logLines.append("error = encode request failed")
            let log = logLines.joined(separator: "\n")
            storeLog(log)
            return nil
        }
        logLines.append("request_body.bytes = \(payload.count)")

        var request = URLRequest(url: cfg.apiURL, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !cfg.apiKey.isEmpty {
            request.setValue("Bearer \(cfg.apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            NSLog("[AI] HTTP %d, size: %d bytes", status, data.count)
            logLines.append("status = \(status)")
            logLines.append("response.bytes = \(data.count)")
            if let text = String(data: data.prefix(2048), encoding: .utf8) {
                logLines.append("response.preview = \(text)")
            }
            guard (200 ... 299).contains(status) else {
                logLines.append("error = non-2xx status")
                let log = logLines.joined(separator: "\n")
                storeLog(log)
                return nil
            }

            struct ChatResponse: Decodable {
                struct Choice: Decodable {
                    struct Message: Decodable {
                        let role: String
                        let content: String
                    }
                    let message: Message
                }
                let choices: [Choice]
            }

            guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data),
                let content = decoded.choices.first?.message.content
            else {
                let msg = "[AI] decode chat response failed"
                NSLog("%@", msg)
                logLines.append("error = decode chat response failed")
                let log = logLines.joined(separator: "\n")
                storeLog(log)
                return nil
            }

            logLines.append("raw_message = \(content)")

            struct Parsed: Decodable {
                let title: String?
                let description: String?
                let tags: [String]?
            }

            let parsed: Parsed?
            if let jsonData = content.data(using: .utf8) {
                parsed = try? JSONDecoder().decode(Parsed.self, from: jsonData)
            } else {
                parsed = nil
            }

            guard let parsed else {
                logLines.append("error = message is not valid JSON")
                let log = logLines.joined(separator: "\n")
                storeLog(log)
                return nil
            }

            logLines.append("decoded.title = \(parsed.title ?? "nil")")
            logLines.append("decoded.description.length = \(parsed.description?.count ?? 0)")
            logLines.append("decoded.tags.count = \(parsed.tags?.count ?? 0)")
            let log = logLines.joined(separator: "\n")
            storeLog(log)
            return AITitleDescription(title: parsed.title, desc: parsed.description, tags: parsed.tags)
        } catch {
            NSLog("[AI] request error: %@", error.localizedDescription)
            logLines.append("error = \(error.localizedDescription)")
            let log = logLines.joined(separator: "\n")
            storeLog(log)
            return nil
        }
    }

    func refineSnippet(
        content: String,
        originalTitle: String,
        originalDesc: String
    ) async -> AITitleDescription? {
        var logLines: [String] = []
        logLines.append("AI snippet request started")
        logLines.append("content.length = \(content.count)")
        logLines.append("original_title = \(originalTitle)")
        logLines.append("original_description = \(originalDesc)")

        guard let cfg = AIConfig.load() else {
            logLines.append("config = missing or disabled (ai.enabled=false / invalid URL / empty model)")
            let log = logLines.joined(separator: "\n")
            storeLog(log)
            return nil
        }
        logLines.append("apiURL = \(cfg.apiURL.absoluteString)")
        logLines.append("apiKey.present = \(!cfg.apiKey.isEmpty)")
        logLines.append("model = \(cfg.model)")

        struct ChatRequest: Encodable {
            struct Message: Encodable {
                let role: String
                let content: String
            }
            let model: String
            let messages: [Message]
            let temperature: Double
        }

        let systemPrompt =
            """
            你是一个为稍后阅读应用生成中文标题、简介和标签的助手。
            请根据提供的文本片段，生成简洁的标题和描述。
            只输出一个 JSON 对象，不要输出多余文字，格式为：
            {
              "title": "字符串，书签标题",
              "description": "字符串，摘要描述，不超过 80 个中文字符",
              "tags": ["tag1", "tag2", ...]  // 可选，0~5 个短标签
            }
            tags 应该是简短的中文或英文关键词，例如 ["AI", "生产力", "Swift"]，不要包含空字符串或重复项。
            """
        let userContent = """
            原始标题: \(originalTitle)
            原始描述: \(originalDesc)

            文本片段内容:
            \(content.prefix(4000))
            """

        let body = ChatRequest(
            model: cfg.model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userContent),
            ],
            temperature: 0.3
        )

        guard let payload = try? JSONEncoder().encode(body) else {
            let msg = "[AI] encode request failed"
            NSLog("%@", msg)
            logLines.append("error = encode request failed")
            let log = logLines.joined(separator: "\n")
            storeLog(log)
            return nil
        }
        logLines.append("request_body.bytes = \(payload.count)")

        var request = URLRequest(url: cfg.apiURL, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !cfg.apiKey.isEmpty {
            request.setValue("Bearer \(cfg.apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            NSLog("[AI] HTTP %d, size: %d bytes", status, data.count)
            logLines.append("status = \(status)")
            logLines.append("response.bytes = \(data.count)")
            if let text = String(data: data.prefix(2048), encoding: .utf8) {
                logLines.append("response.preview = \(text)")
            }
            guard (200 ... 299).contains(status) else {
                logLines.append("error = non-2xx status")
                let log = logLines.joined(separator: "\n")
                storeLog(log)
                return nil
            }

            struct ChatResponse: Decodable {
                struct Choice: Decodable {
                    struct Message: Decodable {
                        let role: String
                        let content: String
                    }
                    let message: Message
                }
                let choices: [Choice]
            }

            guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data),
                let content = decoded.choices.first?.message.content
            else {
                let msg = "[AI] decode chat response failed"
                NSLog("%@", msg)
                logLines.append("error = decode chat response failed")
                let log = logLines.joined(separator: "\n")
                storeLog(log)
                return nil
            }

            logLines.append("raw_message = \(content)")

            struct Parsed: Decodable {
                let title: String?
                let description: String?
                let tags: [String]?
            }

            let parsed: Parsed?
            if let jsonData = content.data(using: .utf8) {
                parsed = try? JSONDecoder().decode(Parsed.self, from: jsonData)
            } else {
                parsed = nil
            }

            guard let parsed else {
                logLines.append("error = message is not valid JSON")
                let log = logLines.joined(separator: "\n")
                storeLog(log)
                return nil
            }

            logLines.append("decoded.title = \(parsed.title ?? "nil")")
            logLines.append("decoded.description.length = \(parsed.description?.count ?? 0)")
            logLines.append("decoded.tags.count = \(parsed.tags?.count ?? 0)")
            let log = logLines.joined(separator: "\n")
            storeLog(log)
            return AITitleDescription(title: parsed.title, desc: parsed.description, tags: parsed.tags)
        } catch {
            NSLog("[AI] request error: %@", error.localizedDescription)
            logLines.append("error = \(error.localizedDescription)")
            let log = logLines.joined(separator: "\n")
            storeLog(log)
            return nil
        }
    }
}

