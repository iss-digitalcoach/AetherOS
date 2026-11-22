import AppKit

/// Composition root: one instance of everything shared by both HUD styles and Settings.
@MainActor
final class Services {
    let settings = AppSettings()
    let themes = ThemeEngine()
    let index = SearchIndex()
    let clipboard = ClipboardHistory()
    let agent = LocalAIAgentService()
    private let settingsWindow = SettingsWindowController()
    private let optimizerWindow = OptimizerWindowController()
    private var caffeinate: Process?

    private var usage: [String: Int] = (UserDefaults.standard.dictionary(forKey: "usage") as? [String: Int]) ?? [:]

    init() {
        clipboard.isEnabled = settings.clipboardEnabled
        let u = usage
        Task { await index.setUsage(u) }
    }

    /// Remembers what you launch so it floats to the top next time.
    func recordUse(_ id: String) {
        usage[id, default: 0] += 1
        UserDefaults.standard.set(usage, forKey: "usage")
        let u = usage
        Task { await index.setUsage(u) }
    }

    func openSettings() { settingsWindow.show(services: self) }
    func openOptimizer(_ tab: OptimizerTab = .clean) { optimizerWindow.show(tab: tab) }

    var isCaffeinated: Bool { caffeinate?.isRunning == true }

    /// Executes a non-AI result. The caller dismisses the HUD first.
    func perform(_ action: SearchItem.Action) {
        switch action {
        case .launchApp(let url):
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        case .snap(let layout):
            WindowManager.apply(layout)
        case .openURL(let url):
            NSWorkspace.shared.open(url)
        case .copyText(let text):
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        case .openFile(let url):
            NSWorkspace.shared.open(url)
        case .revealFile(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .quitApp(let pid):
            NSRunningApplication(processIdentifier: pid)?.terminate()
        case .saveNote(let text):
            Productivity.appendNote(text)
        case .startTimer(let seconds, let label):
            Productivity.startTimer(seconds: seconds, label: label)
        case .openSettings:
            openSettings()
        case .openOptimizer(let tab):
            openOptimizer(tab)
        case .system(let cmd):
            run(cmd)
        case .askAI:
            break
        }
    }

    private func run(_ cmd: SystemCommand) {
        switch cmd {
        case .sleepDisplay:
            Task { _ = try? await Shell.run("/usr/bin/pmset", ["displaysleepnow"]) }
        case .toggleDarkMode:
            Task {
                _ = try? await Shell.run("/usr/bin/osascript", ["-e",
                    "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"])
            }
        case .toggleCaffeinate:
            if let p = caffeinate, p.isRunning { p.terminate(); caffeinate = nil }
            else {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
                p.arguments = ["-di"]            // keep display + system awake
                try? p.run()
                caffeinate = p
            }
        case .openNotes:
            NSWorkspace.shared.open(Productivity.notesURL)
        }
    }
}
