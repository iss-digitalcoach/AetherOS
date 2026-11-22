import SwiftUI
import Observation

@MainActor @Observable
final class HUDViewModel {
    enum Mode { case search, ai, convert }

    struct PendingApproval { let tool: String; let summary: String }

    var query = "" { didSet { if query != oldValue { querySearch() } } }
    private(set) var results: [SearchItem] = []
    var selection = 0
    private(set) var mode: Mode = .search

    // AI
    private(set) var aiText = ""
    private(set) var toolLog: [String] = []
    private(set) var isStreaming = false
    private(set) var errorMessage: String?
    private(set) var pendingApproval: PendingApproval?

    // File conversion ring
    private(set) var convertFiles: [URL] = []
    private(set) var conversions: [Conversion] = []
    private(set) var conversionStates: [String: ConversionState] = [:]
    var conversionSelection = 0
    private(set) var conversionStatus: String?
    private(set) var lastOutputs: [URL] = []

    // Notch presentation
    var notchExpanded = false
    /// True while the launcher is on screen; the glass shader pauses otherwise (saves battery).
    var isVisible = false
    var notch = NotchMetrics(width: 190, height: 30)

    private(set) var context = SystemContext()

    let services: Services
    let voice = VoiceInput()
    private let router: QueryRouter
    private var searchTask: Task<Void, Never>?
    private var aiTask: Task<Void, Never>?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    private var indexed = false

    init(services: Services) {
        self.services = services
        self.router = QueryRouter(services: services)
        voice.onPartial = { [weak self] text in self?.query = text }
        voice.onSilence = { [weak self] text in
            guard let self, services.settings.voiceAutoAsk else { return }
            ask(text)
        }
    }

    func begin(with context: SystemContext) {
        self.context = context
        cancelWork()
        query = ""
        aiText = ""; toolLog = []; errorMessage = nil
        conversionStates = [:]; conversionStatus = nil; lastOutputs = []; conversionSelection = 0

        let files = services.settings.conversionsEnabled ? context.selectedFiles : []
        let options = ConversionCatalog.options(for: files)
        if files.isEmpty || options.isEmpty {
            convertFiles = []; conversions = []
            mode = .search
        } else {
            convertFiles = files; conversions = options
            mode = .convert
        }

        Task {
            if !indexed { await services.index.rebuild(); indexed = true }
            await services.index.setDynamic(Self.runningAppItems())
            results = await router.results(for: "")
            selection = 0
        }
    }

    func toggleVoice() { Task { await voice.toggle() } }

    func cancelWork() {
        voice.stop()
        searchTask?.cancel(); aiTask?.cancel()
        resolveApproval(false)
        isStreaming = false
    }

    private static func runningAppItems() -> [SearchItem] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .compactMap { app in
                guard let name = app.localizedName else { return nil }
                return SearchItem(id: "quit-\(app.processIdentifier)", title: "Quit \(name)",
                                  subtitle: "Running app", symbol: "xmark.circle", action: .quitApp(app.processIdentifier))
            }
    }

    // MARK: Search

    private func querySearch() {
        if mode != .search { mode = .search; aiText = ""; errorMessage = nil }
        searchTask?.cancel()
        let q = query
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(q.isEmpty ? 0 : 40))   // debounce shell-backed queries
            guard !Task.isCancelled else { return }
            let r = await router.results(for: q)
            guard !Task.isCancelled else { return }
            results = r
            selection = 0
        }
    }

    func moveSelection(_ delta: Int) {
        switch mode {
        case .convert:
            guard !conversions.isEmpty else { return }
            conversionSelection = (conversionSelection + delta + conversions.count) % conversions.count
        case .search:
            guard !results.isEmpty else { return }
            selection = (selection + delta + results.count) % results.count
        case .ai: break
        }
    }

    /// Return key.
    func submit(dismiss: () -> Void) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if mode == .convert { runConversion(conversionSelection); return }
        if trimmed.hasPrefix("?") {
            ask(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            return
        }
        guard results.indices.contains(selection) else {
            if !trimmed.isEmpty { ask(trimmed) }
            return
        }
        let item = results[selection]
        switch item.action {
        case .askAI:
            // "Ask Aether: foo" rows carry the query; the bare command uses whatever is typed.
            ask(trimmed.isEmpty ? "Summarize what I have selected." : trimmed)
        default:
            switch item.action {
            case .launchApp, .snap, .system, .openSettings, .openOptimizer: services.recordUse(item.id)
            default: break
            }
            dismiss()
            services.perform(item.action)
        }
    }

    // MARK: Conversions

    func runConversion(_ i: Int) {
        guard conversions.indices.contains(i) else { return }
        let conv = conversions[i]
        if conversionStates[conv.id] == .running { return }
        conversionStates[conv.id] = .running
        conversionStatus = nil
        let files = convertFiles
        Task {
            do {
                let outs = try await conv.run(files)
                conversionStates[conv.id] = .done
                lastOutputs = outs
                conversionStatus = outs.isEmpty ? "\(conv.title) — done"
                    : outs.count == 1 ? "Saved \(outs[0].lastPathComponent)" : "Saved \(outs.count) files"
            } catch {
                conversionStates[conv.id] = .failed(error.localizedDescription)
                conversionStatus = error.localizedDescription
            }
        }
    }

    func revealLastOutput() {
        guard !lastOutputs.isEmpty else { return }
        services.perform(.revealFile(lastOutputs[0]))
    }

    // MARK: AI

    func ask(_ prompt: String) {
        guard !prompt.isEmpty else { return }
        searchTask?.cancel()
        aiTask?.cancel()
        mode = .ai
        aiText = ""; toolLog = []; errorMessage = nil
        isStreaming = true
        let ctx = context
        let config = services.settings.agentConfig
        aiTask = Task {
            let stream = services.agent.respond(to: prompt, context: ctx, config: config) { [weak self] name, summary in
                await self?.requestApproval(tool: name, summary: summary) ?? false
            }
            do {
                for try await event in stream {
                    switch event {
                    case .token(let t): aiText += t
                    case .toolStarted(_, let s): toolLog.append("▸ " + s)
                    case .toolFinished: break
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isStreaming = false
        }
    }

    private func requestApproval(tool: String, summary: String) async -> Bool {
        await withCheckedContinuation { cont in
            pendingApproval = .init(tool: tool, summary: summary)
            approvalContinuation = cont
        }
    }

    func resolveApproval(_ allow: Bool) {
        approvalContinuation?.resume(returning: allow)
        approvalContinuation = nil
        pendingApproval = nil
    }
}

struct NotchMetrics: Sendable, Equatable {
    var width: CGFloat
    var height: CGFloat

    /// Real notch size on notched MacBooks; a plausible pill on other displays.
    @MainActor static func forScreen(_ s: NSScreen) -> NotchMetrics {
        let inset = s.safeAreaInsets.top
        if inset > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            return NotchMetrics(width: s.frame.width - l.width - r.width, height: inset)
        }
        return NotchMetrics(width: 190, height: 30)
    }
}
