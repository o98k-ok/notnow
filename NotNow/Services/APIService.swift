import Foundation

struct APIResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: String
    let duration: TimeInterval
}

enum APIService {
    private struct KeyValue: Decodable {
        let key: String
        let value: String
        let enabled: Bool?
    }

    struct ParsedCURLRequest {
        let method: String
        let url: String
        let headers: [(key: String, value: String)]
        let queryParams: [(key: String, value: String)]
        let body: String?
        let bodyType: String
    }

    static func parseKeyValues(_ json: String?) -> [(key: String, value: String)] {
        guard let json, let data = json.data(using: .utf8),
              let items = try? JSONDecoder().decode([KeyValue].self, from: data)
        else { return [] }
        return items
            .filter { $0.enabled ?? true }
            .map { (key: $0.key, value: $0.value) }
    }

    /// Pretty-print JSON string. Returns nil if input is not valid JSON.
    static func formatJSON(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let result = String(data: pretty, encoding: .utf8)
        else { return nil }
        return result
    }

    static func parseCURL(_ raw: String) -> ParsedCURLRequest? {
        let tokens = tokenizeShellArguments(raw)
        guard !tokens.isEmpty else { return nil }

        var startIndex = 0
        if isCurlCommandToken(tokens[0]) {
            startIndex = 1
        }
        if startIndex >= tokens.count { return nil }

        var method: String?
        var didSetMethodExplicitly = false
        var urlToken: String?
        var headers: [(key: String, value: String)] = []
        var bodyParts: [String] = []

        var i = startIndex
        while i < tokens.count {
            let token = tokens[i]

            if token == "-X" || token == "--request" {
                if i + 1 < tokens.count {
                    method = tokens[i + 1].uppercased()
                    didSetMethodExplicitly = true
                    i += 2
                    continue
                }
            } else if token.hasPrefix("-X"), token.count > 2 {
                method = String(token.dropFirst(2)).uppercased()
                didSetMethodExplicitly = true
                i += 1
                continue
            } else if token.hasPrefix("--request=") {
                method = String(token.dropFirst("--request=".count)).uppercased()
                didSetMethodExplicitly = true
                i += 1
                continue
            } else if token == "--url" {
                if i + 1 < tokens.count {
                    urlToken = tokens[i + 1]
                    i += 2
                    continue
                }
            } else if token.hasPrefix("--url=") {
                urlToken = String(token.dropFirst("--url=".count))
                i += 1
                continue
            } else if token == "-H" || token == "--header" {
                if i + 1 < tokens.count {
                    if let parsed = parseHeader(tokens[i + 1]) {
                        headers.append(parsed)
                    }
                    i += 2
                    continue
                }
            } else if token.hasPrefix("--header=") {
                if let parsed = parseHeader(String(token.dropFirst("--header=".count))) {
                    headers.append(parsed)
                }
                i += 1
                continue
            } else if token == "-d" || token == "--data" || token == "--data-raw" {
                if i + 1 < tokens.count {
                    bodyParts.append(tokens[i + 1])
                    i += 2
                    continue
                }
            } else if token.hasPrefix("--data=") {
                bodyParts.append(String(token.dropFirst("--data=".count)))
                i += 1
                continue
            } else if token.hasPrefix("--data-raw=") {
                bodyParts.append(String(token.dropFirst("--data-raw=".count)))
                i += 1
                continue
            }

            if token.hasPrefix("-") {
                i += 1
                continue
            }

            if urlToken == nil {
                urlToken = token
            }
            i += 1
        }

        guard let rawURL = urlToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty else {
            return nil
        }

        var queryParams: [(key: String, value: String)] = []
        var normalizedURL = rawURL
        if let components = URLComponents(string: rawURL) {
            queryParams = (components.queryItems ?? []).map { (key: $0.name, value: $0.value ?? "") }
            var base = components
            base.query = nil
            if let baseURL = base.string, !baseURL.isEmpty {
                normalizedURL = baseURL
            }
        }

        let body = bodyParts.isEmpty ? nil : bodyParts.joined(separator: "&")
        let resolvedMethod: String = {
            if let method { return method }
            if body != nil && !didSetMethodExplicitly { return "POST" }
            return "GET"
        }()

        return ParsedCURLRequest(
            method: resolvedMethod,
            url: normalizedURL,
            headers: headers,
            queryParams: queryParams,
            body: body,
            bodyType: inferBodyType(headers: headers, hasBody: body != nil)
        )
    }

    static func execute(
        url urlString: String,
        method: String,
        headers headersJSON: String?,
        queryParams paramsJSON: String?,
        body: String?,
        bodyType: String?
    ) async -> APIResponse {
        let headers = parseKeyValues(headersJSON)
        let params = parseKeyValues(paramsJSON)

        guard var components = URLComponents(string: urlString) else {
            return APIResponse(statusCode: -1, headers: [:], body: "Invalid URL", duration: 0)
        }

        if !params.isEmpty {
            var existing = components.queryItems ?? []
            existing.append(contentsOf: params.map { URLQueryItem(name: $0.key, value: $0.value) })
            components.queryItems = existing
        }

        guard let url = components.url else {
            return APIResponse(statusCode: -1, headers: [:], body: "Invalid URL after adding query params", duration: 0)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.uppercased()

        for header in headers {
            request.setValue(header.value, forHTTPHeaderField: header.key)
        }

        if let body, !body.isEmpty, method.uppercased() != "GET" {
            request.httpBody = body.data(using: .utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil, let bodyType, !bodyType.isEmpty {
                request.setValue(bodyType, forHTTPHeaderField: "Content-Type")
            }
        }

        let start = CFAbsoluteTimeGetCurrent()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let duration = CFAbsoluteTimeGetCurrent() - start
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 0

            var responseHeaders: [String: String] = [:]
            if let allHeaders = httpResponse?.allHeaderFields as? [String: String] {
                responseHeaders = allHeaders
            }

            let responseBody = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) ?? ""

            return APIResponse(
                statusCode: statusCode,
                headers: responseHeaders,
                body: responseBody,
                duration: duration
            )
        } catch {
            let duration = CFAbsoluteTimeGetCurrent() - start
            return APIResponse(
                statusCode: -1,
                headers: [:],
                body: error.localizedDescription,
                duration: duration
            )
        }
    }

    static func generateCURL(
        url urlString: String,
        method: String,
        headers headersJSON: String?,
        queryParams paramsJSON: String?,
        body: String?,
        bodyType: String?
    ) -> String {
        let headers = parseKeyValues(headersJSON)
        let params = parseKeyValues(paramsJSON)

        var components = URLComponents(string: urlString)
        if !params.isEmpty {
            var existing = components?.queryItems ?? []
            existing.append(contentsOf: params.map { URLQueryItem(name: $0.key, value: $0.value) })
            components?.queryItems = existing
        }

        let finalURL = components?.url?.absoluteString ?? urlString

        var parts = ["curl"]

        let upperMethod = method.uppercased()
        if upperMethod != "GET" {
            parts.append("-X \(upperMethod)")
        }

        parts.append("'\(finalURL)'")

        for header in headers {
            parts.append("-H '\(header.key): \(header.value)'")
        }

        if let body, !body.isEmpty, upperMethod != "GET" {
            if let bodyType, !bodyType.isEmpty, !headers.contains(where: { $0.key.lowercased() == "content-type" }) {
                parts.append("-H 'Content-Type: \(bodyType)'")
            }
            let escaped = body.replacingOccurrences(of: "'", with: "'\\''")
            parts.append("-d '\(escaped)'")
        }

        return parts.joined(separator: " \\\n  ")
    }

    private static func isCurlCommandToken(_ token: String) -> Bool {
        let lower = token.lowercased()
        return lower == "curl" || lower.hasSuffix("/curl") || lower.hasSuffix("\\curl") || lower.hasSuffix("/curl.exe")
    }

    private static func parseHeader(_ raw: String) -> (key: String, value: String)? {
        guard let separatorIndex = raw.firstIndex(of: ":") else { return nil }
        let key = String(raw[..<separatorIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let valueStart = raw.index(after: separatorIndex)
        let value = String(raw[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return (key: key, value: value)
    }

    private static func inferBodyType(headers: [(key: String, value: String)], hasBody: Bool) -> String {
        guard hasBody else { return "none" }
        let contentType = headers.first { $0.key.lowercased() == "content-type" }?.value.lowercased() ?? ""
        if contentType.contains("application/json") {
            return "json"
        }
        if contentType.contains("application/x-www-form-urlencoded")
            || contentType.contains("multipart/form-data") {
            return "form"
        }
        return "text"
    }

    private static func tokenizeShellArguments(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false

        func flushCurrent() {
            guard !current.isEmpty else { return }
            tokens.append(current)
            current = ""
        }

        for ch in input {
            if escaping {
                if ch == "\n" || ch == "\r" {
                    escaping = false
                    continue
                }
                current.append(ch)
                escaping = false
                continue
            }

            if let activeQuote = quote {
                if ch == activeQuote {
                    quote = nil
                    continue
                }
                if activeQuote == "\"", ch == "\\" {
                    escaping = true
                    continue
                }
                current.append(ch)
                continue
            }

            if ch == "\\" {
                escaping = true
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
                continue
            }
            if ch.isWhitespace {
                flushCurrent()
                continue
            }
            current.append(ch)
        }

        if escaping {
            current.append("\\")
        }
        flushCurrent()
        return tokens
    }
}
