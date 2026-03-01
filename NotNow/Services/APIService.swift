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
}
