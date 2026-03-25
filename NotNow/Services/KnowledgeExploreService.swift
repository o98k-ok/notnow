import Foundation
import SwiftData

// MARK: - Output Types

enum ExploreCandidateSource: String, Sendable {
    /// Link extracted from a real recalled page (outbound link scraping)
    case outboundLink
    /// Candidate URL suggested by AI and verified via actual HTTP fetch
    case aiVerified
    /// AI-generated suggestion that could NOT be verified by a real fetch.
    /// Must be shown with lower visual weight and labeled as AI hypothesis.
    case aiHypothesis
}

struct ExploreCandidate: Sendable, Identifiable {
    let id: UUID
    let url: String
    let title: String
    let desc: String
    let reason: String
    let source: ExploreCandidateSource
    let seedBookmarkID: UUID?
    /// 0.0–1.0. Only meaningful for .aiHypothesis; source-based items are always 1.0
    let confidence: Double

    init(
        url: String, title: String, desc: String,
        reason: String, source: ExploreCandidateSource,
        seedBookmarkID: UUID? = nil,
        confidence: Double = 1.0
    ) {
        self.id = UUID()
        self.url = url
        self.title = title
        self.desc = desc
        self.reason = reason
        self.source = source
        self.seedBookmarkID = seedBookmarkID
        self.confidence = confidence
    }
}

// MARK: - Service

@MainActor
class KnowledgeExploreService {
    static let shared = KnowledgeExploreService()

    /// Expand recall results into verified external candidates.
    /// Priority:
    ///   1. Outbound links from real recalled pages (source-based, always first)
    ///   2. AI-suggested URLs that are verified by real HTTP fetch (source-based)
    ///   3. High-confidence AI hypotheses that failed verification (aiHypothesis, last)
    func explore(
        from recallResults: [RecallResult],
        seed: String,
        existingURLs: Set<String>,
        maxPerType: Int = 5
    ) async -> [ExploreCandidate] {
        guard !recallResults.isEmpty else { return [] }

        var seen = existingURLs
        var results: [ExploreCandidate] = []

        // Step 1: Outbound links from recalled pages (source-based)
        let outbound = await expandOutboundLinks(from: recallResults, existing: &seen, max: maxPerType)
        results.append(contentsOf: outbound)

        // Step 2: AI-suggested URLs → verify each with a real HTTP HEAD/fetch
        // Cap total at maxPerType to avoid noise
        let remaining = max(0, maxPerType - results.count)
        if remaining > 0 {
            let (verified, hypotheses) = await expandWithAIAndVerify(
                from: recallResults, seed: seed, existing: &seen, max: remaining
            )
            results.append(contentsOf: verified)   // source-based, verified
            results.append(contentsOf: hypotheses) // aiHypothesis, lower confidence
        }

        return results
    }

    // MARK: - Step 1: Outbound Links

    private func expandOutboundLinks(
        from results: [RecallResult],
        existing: inout Set<String>,
        max: Int
    ) async -> [ExploreCandidate] {
        let linkResults = results.filter { $0.url.hasPrefix("http") }.prefix(3)
        var candidates: [ExploreCandidate] = []

        for result in linkResults {
            guard candidates.count < max else { break }
            guard let html = await MetadataService.shared.fetchHTMLSnippet(from: result.url, maxLength: 8000) else { continue }
            let links = extractHrefLinks(from: html, baseURL: result.url)
            for link in links {
                guard candidates.count < max else { break }
                let key = link.url.lowercased()
                guard existing.insert(key).inserted else { continue }
                candidates.append(ExploreCandidate(
                    url: link.url,
                    title: link.text.isEmpty ? link.url : link.text,
                    desc: "",
                    reason: "来自「\(result.title.prefix(30))」的外链",
                    source: .outboundLink,
                    seedBookmarkID: result.bookmarkID,
                    confidence: 1.0
                ))
            }
        }
        return candidates
    }

    // MARK: - Step 2: AI Suggest → Verify

    /// Ask AI for candidate URLs, then verify each via HTTP.
    /// Verified ones become .aiVerified; unverifiable become .aiHypothesis.
    private func expandWithAIAndVerify(
        from results: [RecallResult],
        seed: String,
        existing: inout Set<String>,
        max: Int
    ) async -> (verified: [ExploreCandidate], hypotheses: [ExploreCandidate]) {
        guard AIConfig.load() != nil else { return ([], []) }

        // Build context from recall results
        let context = results.prefix(5).map {
            "- \($0.title): \($0.summary.prefix(80))"
        }.joined(separator: "\n")
        guard !context.isEmpty else { return ([], []) }

        let prompt = """
        用户当前输入：\(seed)

        用户已有相关知识条目：
        \(context)

        请基于以上内容，推荐最多 \(max) 条高质量的外部网络资源。
        要求：
        - 只推荐你非常有把握真实存在的 URL（如权威文档、知名项目、知名平台的固定页面）
        - 优先选择 github.com、官方文档站、知名技术博客等高可信度来源
        - 每条必须有明确推荐理由
        - 不确定的 URL 不要推荐，宁少勿多
        - confidence 字段：1.0 表示非常确定，0.7 表示有把握，低于 0.7 请不要输出

        只输出 JSON 数组，格式：
        [{"url": "https://...", "title": "...", "reason": "...", "confidence": 0.9}]
        不要输出 JSON 以外的任何内容。
        """

        guard let aiCandidates = await AIService.shared.suggestResources(prompt: prompt) else {
            return ([], [])
        }

        // Filter by confidence threshold and dedup
        let filtered = aiCandidates.filter { $0.confidence >= 0.7 }

        var verified: [ExploreCandidate] = []
        var hypotheses: [ExploreCandidate] = []

        for item in filtered {
            let key = item.url.lowercased()
            guard existing.insert(key).inserted else { continue }

            // Verify the URL actually resolves with a fast HEAD request
            let isReal = await verifyURLExists(item.url)

            if isReal {
                // Fetch real title/desc if we only have AI-generated ones
                let meta = await MetadataService.shared.fetch(from: item.url, fetchImage: false)
                verified.append(ExploreCandidate(
                    url: item.url,
                    title: meta.title ?? item.title,
                    desc: meta.description ?? "",
                    reason: item.reason,
                    source: .aiVerified,
                    confidence: 1.0
                ))
            } else {
                // Could not verify — label as hypothesis, only include if high confidence
                guard item.confidence >= 0.85 else { continue }
                hypotheses.append(ExploreCandidate(
                    url: item.url,
                    title: item.title,
                    desc: "",
                    reason: item.reason + "（AI 推测，未能验证）",
                    source: .aiHypothesis,
                    confidence: item.confidence
                ))
            }
        }

        return (verified, hypotheses)
    }

    // MARK: - URL Verification

    /// Fast HEAD request to check if URL actually resolves.
    private func verifyURLExists(_ urlString: String) async -> Bool {
        guard let url = URL(string: urlString),
              url.scheme == "https" || url.scheme == "http" else { return false }
        do {
            var request = URLRequest(url: url, timeoutInterval: 6)
            request.httpMethod = "HEAD"
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (200...399).contains(status)
        } catch {
            return false
        }
    }

    // MARK: - HTML Link Extraction

    private struct HrefLink {
        let url: String
        let text: String
    }

    private func extractHrefLinks(from html: String, baseURL: String) -> [HrefLink] {
        let base = URL(string: baseURL)
        let pattern = #"<a[^>]+href=["']([^"'#]+)["'][^>]*>([^<]*)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let nsHTML = html as NSString
        let fullRange = NSRange(location: 0, length: nsHTML.length)
        let matches = regex.matches(in: html, range: fullRange)

        var links: [HrefLink] = []
        var seen = Set<String>()
        links.reserveCapacity(min(matches.count, 30))

        for match in matches {
            guard match.numberOfRanges >= 3,
                  match.range(at: 1).location != NSNotFound,
                  match.range(at: 2).location != NSNotFound else { continue }

            let rawHref = nsHTML.substring(with: match.range(at: 1))
            let rawText = nsHTML.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)

            let resolvedURL: String
            if rawHref.hasPrefix("http://") || rawHref.hasPrefix("https://") {
                resolvedURL = rawHref
            } else if rawHref.hasPrefix("/"), let base {
                resolvedURL = (base.scheme ?? "https") + "://" + (base.host ?? "") + rawHref
            } else {
                continue
            }

            guard resolvedURL.hasPrefix("http"),
                  !resolvedURL.contains("#"),
                  let linkHost = URL(string: resolvedURL)?.host,
                  linkHost != base?.host else { continue }

            let key = resolvedURL.lowercased()
            if seen.insert(key).inserted {
                links.append(HrefLink(url: resolvedURL, text: rawText))
            }
        }
        return links
    }
}
