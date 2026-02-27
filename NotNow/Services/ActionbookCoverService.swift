import Foundation

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
    
    /// 使用 Actionbook screenshot 生成封面
    private func performScreenshotFetch(url: URL) async -> BookmarkMetadata {
        let tempDir = FileManager.default.temporaryDirectory
        let screenshotPath = tempDir.appendingPathComponent("notnow_cover_\(UUID().uuidString).png").path
        let focusScript = createFocusScreenshotScript()
        
        let commands = [
            buildCommand(args: ["browser", "open", url.absoluteString]),
            buildCommand(args: ["browser", "wait", "body", "--timeout", "10000"]),
            "sleep \(Int(pageSettleSeconds))",
            buildCommand(args: ["browser", "eval", focusScript]),
            buildCommand(args: ["browser", "screenshot", screenshotPath]),
            buildCommand(args: ["browser", "close"]),
        ]
        
        let _ = await runShellCommand(commands.joined(separator: " && "))
        
        guard let imageData = try? Data(contentsOf: URL(fileURLWithPath: screenshotPath)) else {
            NSLog("[Actionbook] screenshot failed")
            cleanupFile(at: screenshotPath)
            return BookmarkMetadata()
        }
        
        cleanupFile(at: screenshotPath)
        NSLog("[Actionbook] screenshot success, size: %d bytes", imageData.count)
        return BookmarkMetadata(imageData: imageData)
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

    /// 截图前把页面滚动到主内容区域，提高截图命中重点区域的概率
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
