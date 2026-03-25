import SwiftData
import SwiftUI

/// Seed -> Recall -> Explore -> Distill -> Feedback
/// Single-entry sheet. Never auto-inserts anything into the library.
struct ExploreView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allBookmarks: [Bookmark]

    @State private var seed = ""
    @FocusState private var seedFocused: Bool

    @State private var phase: Phase = .idle
    @State private var recallResults: [RecallResult] = []
    @State private var distilledCandidates: [DistilledCandidate] = []
    @State private var pipelineTask: Task<Void, Never>?
    @State private var statusText = ""

    @State private var savedIDs: Set<UUID> = []
    @State private var skippedIDs: Set<UUID> = []

    private enum Phase { case idle, running, done }

    var body: some View {
        VStack(spacing: 0) {
            exploreHeader
            seedInputBar
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
            if !recallResults.isEmpty {
                recallSection
            }
            if !distilledCandidates.isEmpty {
                exploreSection
            }
            if phase == .idle && recallResults.isEmpty {
                emptyState
            }
        }
        .onDisappear { pipelineTask?.cancel() }
    }

    // MARK: - Header

    private var exploreHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.title3)
                .foregroundStyle(AppTheme.accent)
            Text("知识探索")
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            if phase == .running {
                ProgressView().controlSize(.small)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Seed Input

    private var seedInputBar: some View {
        HStack(spacing: 10) {
            TextField("输入文章 URL、关键词或问题…", text: $seed)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($seedFocused)
                .onSubmit { startPipeline() }

            Button {
                if phase == .running {
                    pipelineTask?.cancel()
                    phase = .idle
                    statusText = ""
                } else {
                    startPipeline()
                }
            } label: {
                Text(phase == .running ? "停止" : "探索")
                    .ghostButtonStyle()
            }
            .buttonStyle(.notNowPlainInteractive)
            .disabled(seed.trimmingCharacters(in: .whitespaces).isEmpty && phase != .running)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(AppTheme.bgInput)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppTheme.borderSubtle, lineWidth: 1))
    }

    // MARK: - Recall Section

    private var recallSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("已有知识匹配", icon: "books.vertical")
            ForEach(recallResults.prefix(8)) { result in
                RecallRow(result: result)
                    .padding(.horizontal, 20)
            }
        }
        .padding(.top, 16)
    }

    // MARK: - Explore Section

    private var exploreSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("探索候选内容", icon: "arrow.trianglehead.branch")
            ForEach(distilledCandidates.filter { !skippedIDs.contains($0.id) }) { candidate in
                DistilledCandidateRow(
                    candidate: candidate,
                    isSaved: savedIDs.contains(candidate.id),
                    onSave: { saveCandidate(candidate) },
                    onSkip: { skipCandidate(candidate) },
                    onCreateSnippet: { saveCandidate(candidate, kind: .snippet) },
                    onCreateTask: { saveCandidate(candidate, kind: .task) }
                )
                .padding(.horizontal, 20)
            }
        }
        .padding(.top, 16)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(AppTheme.textTertiary)
            Text("输入任意内容开始探索")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppTheme.textSecondary)
            .padding(.horizontal, 20)
    }

    // MARK: - Pipeline

    private func startPipeline() {
        pipelineTask?.cancel()
        let seedValue = seed.trimmingCharacters(in: .whitespaces)
        guard !seedValue.isEmpty else { return }

        recallResults = []
        distilledCandidates = []
        savedIDs = []
        skippedIDs = []
        phase = .running
        statusText = "召回中…"

        let ctx = modelContext
        let existingURLs = Set(allBookmarks.map { $0.url.lowercased() })

        pipelineTask = Task {
            // Step 0: If seed is a URL, prefetch page metadata for richer recall signal
            var recallSeed = seedValue
            if let parsedURL = URL(string: seedValue),
               parsedURL.scheme == "http" || parsedURL.scheme == "https" {
                await MainActor.run { statusText = "获取页面内容…" }
                let meta = await MetadataService.shared.fetch(from: seedValue, fetchImage: false)
                var parts: [String] = []
                if let t = meta.title, !t.isEmpty { parts.append(t) }
                if let d = meta.description, !d.isEmpty { parts.append(d) }
                if !parts.isEmpty { recallSeed = parts.joined(separator: " ") }
                guard !Task.isCancelled else { resetPhase(); return }
            }
            await MainActor.run { statusText = "召回中…" }

            // Step 1: Recall
            let recalled = await KnowledgeRecallService.shared.recall(
                seed: recallSeed, context: ctx, maxResults: 20
            )
            guard !Task.isCancelled else { resetPhase(); return }
            await MainActor.run {
                recallResults = recalled
                statusText = "探索扩散中…"
            }

            // Step 2: Explore
            let candidates = await KnowledgeExploreService.shared.explore(
                from: recalled,
                seed: seedValue,
                existingURLs: existingURLs,
                maxPerType: 5
            )
            guard !Task.isCancelled else { resetPhase(); return }
            await MainActor.run { statusText = "提炼中…" }

            // Step 3: Distill
            let distilled = await KnowledgeDistillService.shared.distill(
                candidates: candidates,
                recallContext: recalled
            )
            guard !Task.isCancelled else { resetPhase(); return }

            await MainActor.run {
                distilledCandidates = distilled
                phase = .done
                statusText = ""
            }
        }
    }

    private func resetPhase() {
        Task { @MainActor in
            phase = .idle
            statusText = ""
        }
    }

    private func saveCandidate(_ candidate: DistilledCandidate, kind: BookmarkKind = .link) {
        guard !savedIDs.contains(candidate.id) else { return }

        let bookmark = Bookmark(url: candidate.url, title: candidate.title, desc: candidate.summary)
        bookmark.bookmarkKind = kind
        if kind == .snippet {
            bookmark.snippetContent = candidate.summary
        }
        modelContext.insert(bookmark)
        do {
            try modelContext.save()
        } catch {
            modelContext.delete(bookmark)
            return
        }

        // Persist succeeded — update UI state and trigger side effects
        savedIDs.insert(candidate.id)

        if let seedID = candidate.seedBookmarkID {
            KnowledgeFeedbackService.shared.record(
                event: .save,
                bookmarkID: seedID,
                queryContext: seed,
                context: modelContext
            )
        }

        Task {
            await KnowledgeIndexService.shared.index(bookmark, context: modelContext)
        }

        NotificationCenter.default.postModelDataDidChange(kind: .bookmarkUpserted, bookmarkID: bookmark.id)
    }

    private func skipCandidate(_ candidate: DistilledCandidate) {
        skippedIDs.insert(candidate.id)
        if let seedID = candidate.seedBookmarkID {
            KnowledgeFeedbackService.shared.record(
                event: .skip,
                bookmarkID: seedID,
                queryContext: seed,
                context: modelContext
            )
        }
    }
}

// MARK: - Row Views

private struct RecallRow: View {
    let result: RecallResult

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(result.title.isEmpty ? result.url : result.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                if !result.reason.isEmpty {
                    Text(result.reason)
                        .font(.caption)
                        .foregroundStyle(AppTheme.textTertiary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if !result.tags.isEmpty {
                Text(result.tags.prefix(2).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(AppTheme.bgInput)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct DistilledCandidateRow: View {
    let candidate: DistilledCandidate
    let isSaved: Bool
    let onSave: () -> Void
    let onSkip: () -> Void
    let onCreateSnippet: () -> Void
    let onCreateTask: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(2)
                    if !candidate.summary.isEmpty {
                        Text(candidate.summary)
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(3)
                    }
                    if !candidate.reason.isEmpty {
                        Text(candidate.reason)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                sourceTag
            }

            if !isSaved {
                HStack(spacing: 8) {
                    Button("保存", action: onSave)
                        .ghostButtonStyle()
                        .buttonStyle(.notNowPlainInteractive)
                    if candidate.suggestedAction == .createSnippet {
                        Button("存为 Snippet", action: onCreateSnippet)
                            .ghostButtonStyle()
                            .buttonStyle(.notNowPlainInteractive)
                    }
                    if candidate.suggestedAction == .createTask {
                        Button("存为 Task", action: onCreateTask)
                            .ghostButtonStyle()
                            .buttonStyle(.notNowPlainInteractive)
                    }
                    Spacer()
                    Button("跳过", action: onSkip)
                        .font(.caption)
                        .foregroundStyle(AppTheme.textTertiary)
                        .buttonStyle(.plain)
                }
            } else {
                Label("已保存", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(12)
        .background(AppTheme.bgInput)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppTheme.borderSubtle, lineWidth: 1))
    }

    private var sourceTag: some View {
        let (label, color): (String, Color) = switch candidate.source {
        case .outboundLink:  ("外链", .blue)
        case .aiVerified:    ("AI 验证", .green)
        case .aiHypothesis:  ("AI 推测", .orange)
        }
        return Text(label)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
