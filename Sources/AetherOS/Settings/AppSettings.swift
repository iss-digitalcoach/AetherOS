import SwiftUI
import Observation

enum HUDStyle: String, CaseIterable, Identifiable, Sendable {
    case classic, notch
    var id: String { rawValue }
    var title: String { self == .classic ? "Classic (centered)" : "Notch (drops from the top)" }
    var other: HUDStyle { self == .classic ? .notch : .classic }
}

enum AppearanceOverride: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor @Observable
final class AppSettings {
    @ObservationIgnored private let defaults = UserDefaults.standard

    var model: String { didSet { defaults.set(model, forKey: "model") } }
    var ollamaURL: String { didSet { defaults.set(ollamaURL, forKey: "ollamaURL") } }
    var temperature: Double { didSet { defaults.set(temperature, forKey: "temperature") } }
    /// Which HUD ⌥Space opens. The other one lives on ⌥⇧Space.
    var primaryStyle: HUDStyle { didSet { defaults.set(primaryStyle.rawValue, forKey: "primaryStyle") } }
    var appearance: AppearanceOverride { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    var clipboardEnabled: Bool { didSet { defaults.set(clipboardEnabled, forKey: "clipboardEnabled") } }
    var conversionsEnabled: Bool { didSet { defaults.set(conversionsEnabled, forKey: "conversionsEnabled") } }
    var voiceAutoAsk: Bool { didSet { defaults.set(voiceAutoAsk, forKey: "voiceAutoAsk") } }
    var webSearchEnabled: Bool { didSet { defaults.set(webSearchEnabled, forKey: "webSearchEnabled") } }

    init() {
        let d = UserDefaults.standard
        model = d.string(forKey: "model") ?? "qwen2.5:7b"
        ollamaURL = d.string(forKey: "ollamaURL") ?? "http://localhost:11434"
        temperature = d.object(forKey: "temperature") as? Double ?? 0.3
        primaryStyle = HUDStyle(rawValue: d.string(forKey: "primaryStyle") ?? "") ?? .classic
        appearance = AppearanceOverride(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        clipboardEnabled = d.object(forKey: "clipboardEnabled") as? Bool ?? true
        conversionsEnabled = d.object(forKey: "conversionsEnabled") as? Bool ?? true
        voiceAutoAsk = d.object(forKey: "voiceAutoAsk") as? Bool ?? true
        webSearchEnabled = d.object(forKey: "webSearchEnabled") as? Bool ?? true
    }

    var agentConfig: LocalAIAgentService.Config {
        var c = LocalAIAgentService.Config()
        if let url = URL(string: ollamaURL) { c.baseURL = url }
        c.model = model
        c.temperature = temperature
        c.webEnabled = webSearchEnabled
        return c
    }
}
