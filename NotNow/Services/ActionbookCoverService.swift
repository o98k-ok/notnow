import Foundation
import AppKit

/// 使用 Actionbook 获取封面的服务
/// 作为 MetadataService 的降级方案，用于处理需要浏览器渲染的页面
/// 复用 Twitter Likes 导入的配置（actionbook.binPath）
actor ActionbookCoverService {
    static let shared = ActionbookCoverService()
    
    /// Actionbook 可执行文件路径（复用 Twitter Likes 配置）
    private var actionbookBinPath: String {
        UserDefaults.standard.string(forKey: "twitterLikes.binPath")?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "actionbook"
    }

    /// Actionbook 浏览器模式（复用 Twitter Likes 配置，默认 extension）
    private var browserMode: String {
        guard let mode = UserDefaults.standard.string(forKey: "twitterLikes.browserMode")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !mode.isEmpty else {
            return "extension"
        }
        return mode
    }
    
    /// 是否可用（有配置路径或系统能找到命令）
    private var isAvailable: Bool {
        !actionbookBinPath.isEmpty
    }
    
    /// 页面加载等待时间（秒）
    private let pageSettleSeconds: TimeInterval = 5
    
    // MARK: - Public Methods
    
    /// 自动降级获取：先 eval 提取，失败则截图
    func fetchCover(from urlString: String) async -> BookmarkMetadata {
        guard isAvailable else {
            NSLog("[Actionbook] not available")
            return BookmarkMetadata()
        }
        guard let url = URL(string: urlString) else {
            NSLog("[Actionbook] invalid URL: %@", urlString)
            return BookmarkMetadata()
        }
        
        // 第1步：尝试 eval 提取
        let evalResult = await performEvalFetch(url: url)
        if evalResult.imageData != nil {
            NSLog("[Actionbook] got cover via eval")
            return evalResult
        }
        
        // 第2步：截图兜底
        NSLog("[Actionbook] eval failed, trying screenshot...")
        return await performScreenshotFetch(url: url)
    }
    
    /// 仅使用 eval 提取元数据（不包含截图兜底）
    func fetchWithEval(from urlString: String) async -> BookmarkMetadata {
        guard isAvailable else {
            NSLog("[Actionbook] not available")
            return BookmarkMetadata()
        }
        guard let url = URL(string: urlString) else {
            NSLog("[Actionbook] invalid URL: %@", urlString)
            return BookmarkMetadata()
        }
        return await performEvalFetch(url: url)
    }
    
    /// 仅使用截图生成封面
    func fetchWithScreenshot(from urlString: String) async -> BookmarkMetadata {
        guard isAvailable else {
            NSLog("[Actionbook] not available")
            return BookmarkMetadata()
        }
        guard let url = URL(string: urlString) else {
            NSLog("[Actionbook] invalid URL: %@", urlString)
            return BookmarkMetadata()
        }
        return await performScreenshotFetch(url: url)
    }
    
    // MARK: - Private Methods
    
    /// 使用 Actionbook eval 提取页面元数据
    private func performEvalFetch(url: URL) async -> BookmarkMetadata {
        let script = createExtractScript()
        
        let commands = [
            buildCommand(args: ["browser", "open", url.absoluteString]),
            buildCommand(args: ["browser", "wait", "body", "--timeout", "10000"]),
            "sleep \(Int(pageSettleSeconds))",
            buildCommand(args: ["browser", "eval", script]),
            buildCommand(args: ["browser", "close"]),
        ]
        
        return await executeCommandChain(commands: commands, url: url)
    }
    
    /// 使用 Actionbook screenshot 生成封面（优先 AI 分析 HTML 确定核心区域）
    private func performScreenshotFetch(url: URL) async -> BookmarkMetadata {
        let tempDir = FileManager.default.temporaryDirectory
        let screenshotPath = tempDir.appendingPathComponent("notnow_cover_\(UUID().uuidString).png").path

        // 第1步：打开页面并获取结构
        let structureScript = createPageStructureScript()
        let openCommands = [
            buildCommand(args: ["browser", "open", url.absoluteString]),
            buildCommand(args: ["browser", "wait", "body", "--timeout", "10000"]),
            "sleep \(Int(pageSettleSeconds))",
            buildCommand(args: ["browser", "eval", structureScript]),
        ]
        let (structureOutput, openExit) = await runShellCommand(openCommands.joined(separator: " && "))

        var focusScript = createFocusScreenshotScript()
        if openExit == 0, !structureOutput.isEmpty {
            var pageStructure = structureOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if pageStructure.hasPrefix("\"") && pageStructure.hasSuffix("\"") {
                pageStructure = String(pageStructure.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\/", with: "/")
            }
            if let aiSelector = await AIService.shared.analyzeCoverRegion(pageStructure: pageStructure, url: url.absoluteString) {
                NSLog("[Actionbook] AI selected selector: %@", aiSelector)
                focusScript = createScrollToSelectorScript(selector: aiSelector)
            }
        }

        // 第2步：滚动到目标区域并截图
        let screenshotCommands = [
            buildCommand(args: ["browser", "eval", focusScript]),
            buildCommand(args: ["browser", "screenshot", screenshotPath]),
            buildCommand(args: ["browser", "close"]),
        ]
        let _ = await runShellCommand(screenshotCommands.joined(separator: " && "))

        guard let imageData = try? Data(contentsOf: URL(fileURLWithPath: screenshotPath)) else {
            NSLog("[Actionbook] screenshot failed")
            cleanupFile(at: screenshotPath)
            return BookmarkMetadata()
        }

        cleanupFile(at: screenshotPath)
        let processed = cropToOGImage(imageData) ?? cropScreenshotToWidth640(imageData) ?? imageData
        NSLog("[Actionbook] screenshot success, original=%d bytes, processed=%d bytes", imageData.count, processed.count)
        return BookmarkMetadata(imageData: processed)
    }
    
    /// 执行命令链并解析结果
    private func executeCommandChain(commands: [String], url: URL) async -> BookmarkMetadata {
        let command = commands.joined(separator: " && ")
        let (output, exitCode) = await runShellCommand(command)
        
        guard exitCode == 0, !output.isEmpty else {
            NSLog("[Actionbook] command failed or empty output")
            return BookmarkMetadata()
        }
        
        // 解析 JSON 输出
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            NSLog("[Actionbook] failed to parse JSON output")
            return BookmarkMetadata()
        }
        
        let title = json["title"] as? String
        let description = json["description"] as? String
        let imageURL = json["image_url"] as? String
        
        // 如果有图片 URL，尝试下载
        var imageData: Data?
        if let imageURL = imageURL, !imageURL.isEmpty {
            imageData = await downloadImage(from: imageURL)
        }
        
        return BookmarkMetadata(
            title: title,
            description: description,
            imageURL: imageURL,
            imageData: imageData
        )
    }
    
    /// 创建提取元数据的 JavaScript 脚本
    private func createExtractScript() -> String {
        let js = #"""
        (() => {
            const getMeta = (selectors) => {
                for (const sel of selectors) {
                    const el = document.querySelector(sel);
                    if (el) return el.content || el.href || el.src || '';
                }
                return '';
            };
            
            const title = getMeta([
                'meta[property="og:title"]',
                'meta[name="twitter:title"]',
                'meta[name="title"]'
            ]) || document.title || '';
            
            const description = getMeta([
                'meta[property="og:description"]',
                'meta[name="twitter:description"]',
                'meta[name="description"]'
            ]);
            
            const imageURL = getMeta([
                'meta[property="og:image:secure_url"]',
                'meta[property="og:image"]',
                'meta[name="twitter:image:src"]',
                'meta[name="twitter:image"]',
                'link[rel="image_src"]'
            ]);
            
            // 如果 meta 标签没找到，尝试找文章首图
            var articleImage = '';
            if (!imageURL) {
                const articleImg = document.querySelector('article img, .post img, .content img, main img');
                if (articleImg) {
                    articleImage = articleImg.src || '';
                }
            }
            
            return JSON.stringify({
                title: title.trim(),
                description: description.trim(),
                image_url: (imageURL || articleImage).trim()
            });
        })()
        """#
        
        // 转义引号，确保 shell 正确传递
        return js.replacingOccurrences(of: "\"", with: "\\\"")
    }
    
    /// 裁剪为 OG 封面比例（1.91:1），居中取景
    private func cropToOGImage(_ data: Data, targetWidth: CGFloat = 1200, targetHeight: CGFloat = 630) -> Data? {
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard width > 0, height > 0 else { return nil }

        let targetRatio = targetWidth / targetHeight
        let currentRatio = width / height
        let cropW: CGFloat
        let cropH: CGFloat
        if currentRatio > targetRatio {
            cropH = height
            cropW = height * targetRatio
        } else {
            cropW = width
            cropH = width / targetRatio
        }
        let originX = (width - cropW) / 2
        let originY = (height - cropH) / 2
        let cropRect = CGRect(x: originX, y: originY, width: cropW, height: cropH)

        guard let cropped = cgImage.cropping(to: cropRect) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cropped)
        rep.size = NSSize(width: cropW, height: cropH)
        return rep.representation(using: .png, properties: [:])
    }

    /// 将截图裁剪为水平居中、宽度不超过 640 的区域，避免整页视图导致内容过小
    private func cropScreenshotToWidth640(_ data: Data, targetWidth: CGFloat = 640) -> Data? {
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        
        // 宽度本身就不大，直接复用原图
        guard width > targetWidth, targetWidth > 0 else {
            return nil
        }
        
        // 水平居中裁剪到指定宽度，保留全部高度
        let newWidth = targetWidth
        let originX = (width - newWidth) / 2.0
        let cropRect = CGRect(x: originX, y: 0, width: newWidth, height: height)
        
        guard let cropped = cgImage.cropping(to: cropRect) else {
            return nil
        }
        
        let rep = NSBitmapImageRep(cgImage: cropped)
        rep.size = NSSize(width: newWidth, height: height)
        return rep.representation(using: .png, properties: [:])
    }

    /// 提取页面结构（供 AI 分析），返回 JSON
    private func createPageStructureScript() -> String {
        let js = #"""
        (() => {
            const vw = window.innerWidth || 1200;
            const vh = window.innerHeight || 800;
            const selectors = [
                'main', 'article', '[role="main"]', '.hero', '.banner', '.post',
                '.content', '#content', '.article', '.main-content', '.post-content',
                '.entry-content', '.article__body', '.page-content', 'header img',
                '.hero img', 'article img', 'main img', '.featured-image'
            ];
            const seen = new Set();
            const elements = [];
            for (const sel of selectors) {
                const el = document.querySelector(sel);
                if (!el || seen.has(el)) continue;
                const rect = el.getBoundingClientRect();
                const style = window.getComputedStyle(el);
                if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') continue;
                if (rect.width < 80 || rect.height < 80) continue;
                seen.add(el);
                const id = el.id ? '#' + el.id : '';
                const cls = el.className && typeof el.className === 'string' ? '.' + el.className.trim().split(/\s+/).filter(c => /^[a-zA-Z]/.test(c)).join('.') : '';
                let selector = el.tagName.toLowerCase() + (id || cls || '');
                if (selector.length > 80) selector = sel;
                elements.push({
                    selector: selector,
                    tag: el.tagName.toLowerCase(),
                    rect: { x: Math.round(rect.x), y: Math.round(rect.y), w: Math.round(rect.width), h: Math.round(rect.height) },
                    area: Math.round(rect.width * rect.height),
                    inView: rect.top < vh && rect.bottom > 0
                });
            }
            return JSON.stringify({ viewport: { w: vw, h: vh }, elements });
        })()
        """#
        return js.replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// 滚动到指定选择器对应的元素
    private func createScrollToSelectorScript(selector: String) -> String {
        let safe = selector.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        let js = #"""
        (() => {
            try {
                const el = document.querySelector("\#(safe)");
                if (el) {
                    el.scrollIntoView({ behavior: 'instant', block: 'start', inline: 'nearest' });
                    const r = el.getBoundingClientRect();
                    const targetY = Math.max(window.scrollY + r.top - 24, 0);
                    window.scrollTo(0, targetY);
                }
            } catch (e) {}
            return 'ok';
        })()
        """#
        return js.replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// 截图前把页面滚动到主内容区域，提高截图命中重点区域的概率（AI 未配置时的兜底）
    private func createFocusScreenshotScript() -> String {
        let js = #"""
        (() => {
            const selectors = [
                'main',
                'article',
                '[role="main"]',
                '.post',
                '.content',
                '#content',
                '.article',
                '.main-content'
            ];

            const viewportH = window.innerHeight || 800;
            const viewportW = window.innerWidth || 1200;

            const isVisible = (el) => {
                if (!el) return false;
                const rect = el.getBoundingClientRect();
                const style = window.getComputedStyle(el);
                if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return false;
                if (rect.width < 120 || rect.height < 120) return false;
                return true;
            };

            var best = null;
            var bestScore = -1;
            for (const sel of selectors) {
                const el = document.querySelector(sel);
                if (!isVisible(el)) continue;
                const r = el.getBoundingClientRect();
                const area = r.width * r.height;
                const widthScore = Math.min(r.width / Math.max(viewportW * 0.5, 1), 1.2);
                const topPenalty = Math.abs(r.top) / Math.max(viewportH, 1);
                const score = area * widthScore - topPenalty * 10000;
                if (score > bestScore) {
                    bestScore = score;
                    best = el;
                }
            }

            if (best) {
                best.scrollIntoView({ behavior: 'instant', block: 'start', inline: 'nearest' });
                const r = best.getBoundingClientRect();
                const targetY = Math.max(window.scrollY + r.top - 24, 0);
                window.scrollTo(0, targetY);
            } else {
                // 兜底：略过导航栏，停在首屏内容区域
                window.scrollTo(0, Math.max(Math.floor(viewportH * 0.18), 0));
            }
            return 'ok';
        })()
        """#
        return js.replacingOccurrences(of: "\"", with: "\\\"")
    }
    
    /// 构建 Actionbook 命令
    private func buildCommand(args: [String]) -> String {
        let escapedArgs = args.map { escapeShellArg($0) }.joined(separator: " ")
        return "\(escapeShellArg(actionbookBinPath)) --browser-mode \(browserMode) \(escapedArgs)"
    }
    
    /// 执行 shell 命令
    private func runShellCommand(_ command: String) async -> (output: String, exitCode: Int32) {
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", command]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            do {
                try process.run()
                process.waitUntilExit()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                
                continuation.resume(returning: (output, process.terminationStatus))
            } catch {
                NSLog("[Actionbook] shell error: %@", error.localizedDescription)
                continuation.resume(returning: ("", -1))
            }
        }
    }
    
    /// 下载图片
    private func downloadImage(from urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  data.count > 100 else {
                return nil
            }
            return data
        } catch {
            NSLog("[Actionbook] download image failed: %@", error.localizedDescription)
            return nil
        }
    }
    
    /// 清理临时文件
    private func cleanupFile(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
    
    /// 转义 shell 参数
    private func escapeShellArg(_ arg: String) -> String {
        // 使用单引号包裹，内部单引号用 '\'' 转义
        let escaped = arg.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
