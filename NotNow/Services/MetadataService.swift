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
        // ========== 第1步：快速 HTTP 请求获取元数据 ==========
        let fastResult = await fetchFast(urlString: urlString, fetchImage: fetchImage)
        
        // 如果成功获取到封面图，直接返回
        if fastResult.imageData != nil {
            NSLog("[Meta] fast fetch got cover, returning")
            return fastResult
        }
        
        // 如果不需要获取图片，直接返回（标题/描述已拿到）
        if !fetchImage {
            return fastResult
        }
        
        // ========== 第2步：Actionbook 降级方案 ==========
        NSLog("[Meta] fast fetch no cover, trying Actionbook fallback...")
        let actionbookResult = await ActionbookCoverService.shared.fetchCover(from: urlString)
        
        // 合并结果：优先使用 fast 的 title/desc，actionbook 的 image
        return BookmarkMetadata(
            title: fastResult.title ?? actionbookResult.title,
            description: fastResult.description ?? actionbookResult.description,
            imageURL: actionbookResult.imageURL ?? fastResult.imageURL,
            imageData: actionbookResult.imageData ?? fastResult.imageData
        )
    }
    
    /// 快速 HTTP 请求获取元数据（原有逻辑）
    private func fetchFast(urlString: String, fetchImage: Bool) async -> BookmarkMetadata {
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

            NSLog("[Meta] fast result: title=%d, desc=%d, image=%d", title != nil ? 1 : 0, description != nil ? 1 : 0, imageData != nil ? 1 : 0)
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

struct AIRecommendationCandidate: Sendable {
    let url: String
    let title: String
    let desc: String
    let notes: String
    let tags: [String]
    let snippet: String
}

struct AIRecommendationResult: Sendable {
    let summary: String?
    let selectedURLs: [String]
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

    /// 根据 API 请求 URL / 方法 / Body 片段生成标题、描述和标签（用于 API 类型书签的 AI 打标）
    func refineAPI(
        url: String,
        method: String,
        bodySnippet: String?,
        originalTitle: String,
        originalDesc: String
    ) async -> AITitleDescription? {
        var logLines: [String] = []
        logLines.append("AI API refine started")
        logLines.append("url = \(url)")
        logLines.append("method = \(method)")

        guard let cfg = AIConfig.load() else {
            logLines.append("config = missing or disabled")
            storeLog(logLines.joined(separator: "\n"))
            return nil
        }

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
            用户保存了一个 API 请求（METHOD + URL，可选 Body），请根据请求用途生成标题、描述和标签。
            请只输出一个 JSON 对象，不要输出多余文字，格式为：
            {
              "title": "字符串，简洁的 API 用途标题",
              "description": "字符串，摘要描述，不超过 80 个中文字符",
              "tags": ["tag1", "tag2", ...]  // 可选，0~5 个短标签，如 API、REST、认证 等
            }
            tags 应是简短的中文或英文关键词，不要包含空字符串或重复项。
            """

        var userContent = "API 请求：\(method) \(url)\n\n当前标题：\(originalTitle)\n当前描述：\(originalDesc)"
        if let body = bodySnippet?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            let snippet = String(body.prefix(800))
            userContent = "API 请求：\(method) \(url)\n\nBody 片段：\n\(snippet)\n\n当前标题：\(originalTitle)\n当前描述：\(originalDesc)"
        }

        let body = ChatRequest(
            model: cfg.model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userContent),
            ],
            temperature: 0.3
        )

        guard let payload = try? JSONEncoder().encode(body) else {
            logLines.append("error = encode request failed")
            storeLog(logLines.joined(separator: "\n"))
            return nil
        }

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
            logLines.append("status = \(status)")
            guard (200 ... 299).contains(status) else {
                logLines.append("error = non-2xx status")
                storeLog(logLines.joined(separator: "\n"))
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
                logLines.append("error = decode chat response failed")
                storeLog(logLines.joined(separator: "\n"))
                return nil
            }

            struct Parsed: Decodable {
                let title: String?
                let description: String?
                let tags: [String]?
            }

            guard let jsonData = content.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode(Parsed.self, from: jsonData)
            else {
                logLines.append("error = message is not valid JSON")
                storeLog(logLines.joined(separator: "\n"))
                return nil
            }

            storeLog(logLines.joined(separator: "\n"))
            return AITitleDescription(title: parsed.title, desc: parsed.description, tags: parsed.tags)
        } catch {
            logLines.append("error = \(error.localizedDescription)")
            storeLog(logLines.joined(separator: "\n"))
            return nil
        }
    }

    func refineSnippet(
        content: String,
        originalTitle: String, originalDesc: String
    ) async -> AITitleDescription? {
        var logLines: [String] = []
        logLines.append("AI snippet request started")
        logLines.append("content.length = \(content.count)")

        guard let cfg = AIConfig.load() else {
            logLines.append("config = missing or disabled")
            storeLog(logLines.joined(separator: "\n"))
            return nil
        }

        let trimmedContent = String(content.prefix(4000))

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
            用户保存了一段 Markdown 文字片段，请根据内容生成标题、描述和标签。
            请只输出一个 JSON 对象，不要输出多余文字，格式为：
            {
              "title": "字符串，为片段起一个简洁的标题",
              "description": "字符串，摘要描述，不超过 80 个中文字符",
              "tags": ["tag1", "tag2", ...]  // 可选，0~5 个短标签
            }
            tags 应该是简短的中文或英文关键词，不要包含空字符串或重复项。
            """
        let userContent = """
        原始标题: \(originalTitle)
        原始描述: \(originalDesc)

        片段内容:
        \(trimmedContent)
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
            logLines.append("error = encode request failed")
            storeLog(logLines.joined(separator: "\n"))
            return nil
        }

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
            logLines.append("status = \(status)")
            guard (200 ... 299).contains(status) else {
                logLines.append("error = non-2xx status")
                storeLog(logLines.joined(separator: "\n"))
                return nil
            }

            struct ChatResponse: Decodable {
                struct Choice: Decodable {
                    struct Message: Decodable { let content: String }
                    let message: Message
                }
                let choices: [Choice]
            }

            guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data),
                let content = decoded.choices.first?.message.content
            else {
                logLines.append("error = decode chat response failed")
                storeLog(logLines.joined(separator: "\n"))
                return nil
            }

            struct Parsed: Decodable {
                let title: String?
                let description: String?
                let tags: [String]?
            }

            guard let jsonData = content.data(using: .utf8),
                let parsed = try? JSONDecoder().decode(Parsed.self, from: jsonData)
            else {
                logLines.append("error = message is not valid JSON")
                storeLog(logLines.joined(separator: "\n"))
                return nil
            }

            logLines.append("decoded.title = \(parsed.title ?? "nil")")
            logLines.append("decoded.tags.count = \(parsed.tags?.count ?? 0)")
            storeLog(logLines.joined(separator: "\n"))
            return AITitleDescription(title: parsed.title, desc: parsed.description, tags: parsed.tags)
        } catch {
            logLines.append("error = \(error.localizedDescription)")
            storeLog(logLines.joined(separator: "\n"))
            return nil
        }
    }

    func recommendBookmarks(
        query: String,
        candidates: [AIRecommendationCandidate],
        maxResults: Int
    ) async -> AIRecommendationResult? {
        guard let cfg = AIConfig.load() else { return nil }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, !candidates.isEmpty, maxResults > 0 else { return nil }

        struct PromptCandidate: Encodable {
            let url: String
            let title: String
            let desc: String
            let notes: String
            let tags: [String]
            let snippet: String
        }

        struct ChatRequest: Encodable {
            struct Message: Encodable {
                let role: String
                let content: String
            }
            let model: String
            let messages: [Message]
            let temperature: Double
        }

        func trim(_ text: String, max: Int) -> String {
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.count <= max { return cleaned }
            return String(cleaned.prefix(max))
        }

        let promptCandidates = candidates.map {
            PromptCandidate(
                url: trim($0.url, max: 220),
                title: trim($0.title, max: 120),
                desc: trim($0.desc, max: 180),
                notes: trim($0.notes, max: 180),
                tags: Array($0.tags.prefix(8)).map { trim($0, max: 24) },
                snippet: trim($0.snippet, max: 180)
            )
        }

        guard let candidatesJSON = try? String(
            data: JSONEncoder().encode(promptCandidates),
            encoding: .utf8
        ) else {
            return nil
        }

        let systemPrompt = """
        你是一个书签助手。请根据用户的自然语言意图，从候选书签中挑出最有价值的结果。
        规则：
        1) 只能从候选里选择，不能编造 URL。
        2) 返回数量不超过 max_results。
        3) 优先语义相关性、信息密度、可执行价值；避免重复主题。
        4) 只输出 JSON，不要额外文字，格式：
        {
          "summary": "一句中文摘要（可选）",
          "selected_urls": ["https://...", "..."]
        }
        """

        let userPrompt = """
        query: \(trimmedQuery)
        max_results: \(maxResults)
        candidates_json: \(candidatesJSON)
        """

        let body = ChatRequest(
            model: cfg.model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userPrompt)
            ],
            temperature: 0.2
        )

        guard let payload = try? JSONEncoder().encode(body) else { return nil }

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
            guard (200 ... 299).contains(status) else { return nil }

            struct ChatResponse: Decodable {
                struct Choice: Decodable {
                    struct Message: Decodable { let content: String }
                    let message: Message
                }
                let choices: [Choice]
            }
            guard
                let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data),
                let content = decoded.choices.first?.message.content
            else {
                return nil
            }

            struct Parsed: Decodable {
                let summary: String?
                let selected_urls: [String]?
            }
            guard
                let jsonData = content.data(using: .utf8),
                let parsed = try? JSONDecoder().decode(Parsed.self, from: jsonData),
                let urls = parsed.selected_urls
            else {
                return nil
            }

            var seen = Set<String>()
            let deduped = urls
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .filter { url in
                    let key = url.lowercased()
                    if seen.contains(key) { return false }
                    seen.insert(key)
                    return true
                }

            return AIRecommendationResult(
                summary: parsed.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
                selectedURLs: Array(deduped.prefix(maxResults))
            )
        } catch {
            return nil
        }
    }

    private func recommendationURLKey(_ rawURL: String) -> String {
        rawURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func stableDedupCandidates(_ candidates: [AIRecommendationCandidate]) -> [AIRecommendationCandidate] {
        var seen = Set<String>()
        var result: [AIRecommendationCandidate] = []
        result.reserveCapacity(candidates.count)
        for candidate in candidates {
            let key = recommendationURLKey(candidate.url)
            guard !key.isEmpty else { continue }
            if seen.insert(key).inserted {
                result.append(candidate)
            }
        }
        return result
    }

    private func chunkCandidates(_ candidates: [AIRecommendationCandidate], chunkSize: Int) -> [[AIRecommendationCandidate]] {
        guard chunkSize > 0, !candidates.isEmpty else { return [] }
        var chunks: [[AIRecommendationCandidate]] = []
        chunks.reserveCapacity((candidates.count + chunkSize - 1) / chunkSize)
        var index = 0
        while index < candidates.count {
            let end = min(index + chunkSize, candidates.count)
            chunks.append(Array(candidates[index..<end]))
            index = end
        }
        return chunks
    }

    private func shortlistCandidates(
        from chunk: [AIRecommendationCandidate],
        selectedURLs: [String],
        fallbackLimit: Int
    ) -> [AIRecommendationCandidate] {
        guard !chunk.isEmpty, fallbackLimit > 0 else { return [] }

        let byKey = Dictionary(grouping: chunk, by: { recommendationURLKey($0.url) })
        var selected: [AIRecommendationCandidate] = []
        selected.reserveCapacity(min(fallbackLimit, chunk.count))
        var seen = Set<String>()

        for url in selectedURLs {
            let key = recommendationURLKey(url)
            guard !key.isEmpty else { continue }
            guard let candidate = byKey[key]?.first else { continue }
            if seen.insert(key).inserted {
                selected.append(candidate)
                if selected.count >= fallbackLimit { return selected }
            }
        }

        for candidate in chunk {
            let key = recommendationURLKey(candidate.url)
            guard !key.isEmpty else { continue }
            if seen.insert(key).inserted {
                selected.append(candidate)
                if selected.count >= fallbackLimit { break }
            }
        }

        return selected
    }

    func recommendBookmarksTournament(
        query: String,
        candidates: [AIRecommendationCandidate],
        maxResults: Int,
        chunkSize: Int = 120,
        shortlistPerChunk: Int = 12,
        concurrency: Int = 3,
        onProgress: @Sendable @escaping (_ completed: Int, _ total: Int) -> Void = { _, _ in }
    ) async -> AIRecommendationResult? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, !candidates.isEmpty, maxResults > 0 else { return nil }

        let effectiveChunkSize = max(16, chunkSize)
        let effectiveShortlist = max(1, min(shortlistPerChunk, max(1, effectiveChunkSize / 2)))
        let effectiveConcurrency = max(1, concurrency)
        var current = stableDedupCandidates(candidates)
        var latestSummary: String?

        while current.count > effectiveChunkSize {
            guard !Task.isCancelled else { return nil }
            let chunks = chunkCandidates(current, chunkSize: effectiveChunkSize)
            let totalChunks = chunks.count
            guard totalChunks > 0 else { break }
            onProgress(0, totalChunks)

            var completedChunks = 0
            var selectedByChunk: [Int: [AIRecommendationCandidate]] = [:]
            selectedByChunk.reserveCapacity(totalChunks)

            var cursor = 0
            while cursor < totalChunks {
                let end = min(cursor + effectiveConcurrency, totalChunks)
                await withTaskGroup(of: (Int, [AIRecommendationCandidate], String?).self) { group in
                    for chunkIndex in cursor..<end {
                        let chunk = chunks[chunkIndex]
                        group.addTask {
                            let perChunkLimit = min(effectiveShortlist, chunk.count)
                            let result = await self.recommendBookmarks(
                                query: trimmedQuery,
                                candidates: chunk,
                                maxResults: perChunkLimit
                            )
                            let selected = await self.shortlistCandidates(
                                from: chunk,
                                selectedURLs: result?.selectedURLs ?? [],
                                fallbackLimit: perChunkLimit
                            )
                            return (chunkIndex, selected, result?.summary)
                        }
                    }

                    for await (chunkIndex, selected, summary) in group {
                        selectedByChunk[chunkIndex] = selected
                        if let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                            latestSummary = summary
                        }
                        completedChunks += 1
                        onProgress(completedChunks, totalChunks)
                    }
                }
                cursor = end
            }

            var nextRound: [AIRecommendationCandidate] = []
            nextRound.reserveCapacity(min(current.count, totalChunks * effectiveShortlist))
            for chunkIndex in 0..<totalChunks {
                if let selected = selectedByChunk[chunkIndex] {
                    nextRound.append(contentsOf: selected)
                }
            }

            let dedupedNext = stableDedupCandidates(nextRound)
            if dedupedNext.isEmpty { break }
            current = dedupedNext
        }

        guard !Task.isCancelled else { return nil }
        guard !current.isEmpty else { return nil }

        if let final = await recommendBookmarks(query: trimmedQuery, candidates: current, maxResults: maxResults) {
            return final
        }

        return AIRecommendationResult(
            summary: latestSummary,
            selectedURLs: Array(current.map(\.url).prefix(maxResults))
        )
    }

    /// 根据页面结构分析最佳 OG 封面区域，返回 CSS 选择器
    func analyzeCoverRegion(pageStructure: String, url: String) async -> String? {
        guard let cfg = AIConfig.load() else {
            NSLog("[AI] cover region: config missing")
            return nil
        }

        struct ChatRequest: Encodable {
            struct Message: Encodable {
                let role: String
                let content: String
            }
            let model: String
            let messages: [Message]
            let temperature: Double
        }

        let systemPrompt = """
        你是一个网页结构分析助手。根据页面 DOM 结构（包含元素选择器、位置和尺寸），选出最适合作为「链接封面图」的区域。
        要求：优先 hero/主图、文章首图、主内容区；避开导航栏、侧边栏、广告。
        目标比例约 1.91:1（如 1200×630）。
        请只输出一个 JSON 对象，不要其他文字：
        {"selector": "CSS选择器，如 main 或 .hero 或 article", "reason": "简要说明"}
        若无法确定，返回 {"selector": "body", "reason": "fallback"}。
        """

        let userContent = """
        URL: \(url)

        页面结构（JSON）:
        \(pageStructure)
        """

        let body = ChatRequest(
            model: cfg.model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userContent),
            ],
            temperature: 0.2
        )

        guard let payload = try? JSONEncoder().encode(body) else {
            NSLog("[AI] cover region: encode failed")
            return nil
        }

        var request = URLRequest(url: cfg.apiURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !cfg.apiKey.isEmpty {
            request.setValue("Bearer \(cfg.apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else {
                NSLog("[AI] cover region HTTP %d", status)
                return nil
            }

            struct ChatResponse: Decodable {
                struct Choice: Decodable {
                    struct Message: Decodable { let content: String }
                    let message: Message
                }
                let choices: [Choice]
            }

            guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data),
                  let content = decoded.choices.first?.message.content
            else {
                NSLog("[AI] cover region: decode failed")
                return nil
            }

            struct Parsed: Decodable {
                let selector: String?
                let reason: String?
            }

            guard let jsonData = content.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode(Parsed.self, from: jsonData),
                  let sel = parsed.selector?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sel.isEmpty
            else {
                NSLog("[AI] cover region: invalid JSON or empty selector")
                return nil
            }

            NSLog("[AI] cover region: selector=%@ reason=%@", sel, parsed.reason ?? "")
            return sel
        } catch {
            NSLog("[AI] cover region error: %@", error.localizedDescription)
            return nil
        }
    }
}
