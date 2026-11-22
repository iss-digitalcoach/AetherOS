import SwiftUI
import AppKit
import ServiceManagement

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(services: Services) {
        if window == nil {
            let host = NSHostingView(rootView: SettingsView(services: services))
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 460),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "AetherOS Settings"
            w.contentView = host
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

final class SettingsStatus: ObservableObject {
    @Published var models: [String] = []
    @Published var reachable: Bool?
    @Published var isLoading = false
}

struct SettingsView: View {
    let services: Services
    @StateObject private var status = SettingsStatus()
    @StateObject private var permissions = PermissionsModel()
    private var models: [String] { status.models }
    private var reachable: Bool? { status.reachable }
    private var isLoading: Bool { status.isLoading }

    var body: some View {
        @Bindable var settings = services.settings

        TabView {
            Form {
                Section("Model") {
                    Picker("Model", selection: $settings.model) {
                        ForEach(modelChoices, id: \.self) { Text($0).tag($0) }
                    }
                    HStack {
                        TextField("Custom model name", text: $settings.model)
                        Button { Task { await refreshModels() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Refresh installed models")
                    }
                    statusRow
                }
                Section("Server") {
                    TextField("Ollama URL", text: $settings.ollamaURL)
                        .onSubmit { Task { await refreshModels() } }
                    HStack {
                        Text("Temperature")
                        Slider(value: $settings.temperature, in: 0...1)
                        Text(settings.temperature, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit().frame(width: 40)
                    }
                }
                Text("Install models with:  ollama pull qwen2.5:7b").font(.footnote).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("AI", systemImage: "sparkles") }

            Form {
                Section("Theme") {
                    Picker("Theme", selection: Binding(
                        get: { services.themes.current.name },
                        set: { services.themes.select($0) })
                    ) {
                        ForEach(services.themes.available) { Text($0.name).tag($0.name) }
                    }
                    Picker("Appearance", selection: $settings.appearance) {
                        ForEach(AppearanceOverride.allCases) { Text($0.title).tag($0) }
                    }
                    HStack {
                        Button("Open Themes Folder") { NSWorkspace.shared.open(ThemeEngine.themesDirectory) }
                        Button("Reload") { services.themes.reloadFromDisk() }
                    }
                    Text("Drop a theme .json in the folder; it appears here instantly. Edits apply live.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Launcher") {
                    Picker("⌥ Space opens", selection: $settings.primaryStyle) {
                        ForEach(HUDStyle.allCases) { Text($0.title).tag($0) }
                    }
                    LabeledContent("⌥ ⇧ Space opens", value: settings.primaryStyle.other.title)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Appearance", systemImage: "circle.lefthalf.filled") }

            Form {
                Section("Tools") {
                    Toggle("Clipboard history (kept in memory only)", isOn: Binding(
                        get: { settings.clipboardEnabled },
                        set: { settings.clipboardEnabled = $0; services.clipboard.isEnabled = $0 }))
                    Toggle("File conversion ring when files are selected in Finder", isOn: $settings.conversionsEnabled)
                    Toggle("Eco mode: glass animation at 30 fps (saves battery)", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "ecoMode") },
                        set: { UserDefaults.standard.set($0, forKey: "ecoMode") }))
                    Button("Open Optimizer…") { services.openOptimizer() }
                    Toggle("Launch AetherOS at login", isOn: Binding(
                        get: { SMAppService.mainApp.status == .enabled },
                        set: { on in
                            // Only works from the packaged .app; silently ignored when run from Terminal.
                            try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        }))
                    Toggle("Voice: ask the AI automatically when I stop talking", isOn: $settings.voiceAutoAsk)
                    Toggle("Let the AI search the web (sends its search terms to DuckDuckGo)", isOn: $settings.webSearchEnabled)
                }
                Section("Permissions") {
                    permissionRow("Accessibility", .accessibility, detail: "Selected text and window snapping", pane: "Privacy_Accessibility")
                    permissionRow("Microphone", .microphone, detail: "Voice input (transcribed on-device)", pane: "Privacy_Microphone")
                    permissionRow("Speech Recognition", .speech, detail: "Voice input", pane: "Privacy_SpeechRecognition")
                    permissionRow("Automation (Finder)", .finder, detail: "Reads the Finder selection for the conversion ring", pane: "Privacy_Automation")
                }
                Section("Shortcuts") {
                    LabeledContent("Launcher", value: "⌥ Space  /  ⌥ ⇧ Space")
                    LabeledContent("Search prefixes", value: "clip · f · note · timer · g · ?")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 540, height: 460)
        .task { await refreshModels() }
    }

    private var modelChoices: [String] {
        let current = services.settings.model
        return models.contains(current) || current.isEmpty ? models : [current] + models
    }

    @ViewBuilder private var statusRow: some View {
        HStack(spacing: 6) {
            Circle().fill(reachable == true ? .green : reachable == false ? .red : .gray).frame(width: 8, height: 8)
            Text(reachable == true ? "Connected · \(models.count) model\(models.count == 1 ? "" : "s") installed"
                 : reachable == false ? "Can't reach the server. Is Ollama running?" : "Checking…")
                .font(.footnote).foregroundStyle(.secondary)
            if isLoading { ProgressView().controlSize(.mini) }
        }
    }

    private func permissionRow(_ title: String, _ kind: PermissionsModel.Kind, detail: String, pane: String) -> some View {
        let state = permissions.state(kind)
        return HStack {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : state == .denied ? "xmark.circle.fill" : "circle.dashed")
                .foregroundStyle(state == .granted ? .green : state == .denied ? .red : .secondary)
            VStack(alignment: .leading) {
                Text(title)
                Text(state == .denied ? "Turned off. Switch it on in System Settings."
                     : kind == .accessibility && state != .granted ? "Not active. If AetherOS is already switched on in System Settings, remove it with − and add it again, then restart AetherOS."
                     : detail)
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if state == .notDetermined {
                Button("Allow…") { permissions.request(kind) }
            } else {
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private func refreshModels() async {
        status.isLoading = true
        defer { status.isLoading = false }
        guard let url = URL(string: services.settings.ollamaURL) else { status.reachable = false; return }
        let list = await services.agent.installedModels(baseURL: url)
        status.models = list.sorted()
        status.reachable = !list.isEmpty
        if let first = list.first, !list.contains(services.settings.model) {
            // Keep the user's choice, but make sure there's something usable if they never set one.
            if services.settings.model.isEmpty { services.settings.model = first }
        }
    }
}
