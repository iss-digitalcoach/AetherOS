import SwiftUI
import Observation

struct HexColor: Codable, Sendable, Hashable {
    var hex: String

    init(_ hex: String) { self.hex = hex }
    init(from decoder: Decoder) throws { hex = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(hex)
    }

    var simd: SIMD3<Float> {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return SIMD3(1, 1, 1) }
        return SIMD3(Float((v >> 16) & 0xFF) / 255, Float((v >> 8) & 0xFF) / 255, Float(v & 0xFF) / 255)
    }
    var color: Color { let c = simd; return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z)) }
}

/// One look for one appearance. The theme picks dark or light from the system setting.
struct Palette: Codable, Sendable, Equatable {
    var accent: HexColor
    var tintColor: HexColor
    var tintOpacity: Double
    var glowColor: HexColor
    var glowIntensity: Double
    var grain: Double
    var specular: Double
}

/// Everything visual lives in one JSON file, so a theme is shareable and hot-swappable.
struct Theme: Codable, Sendable, Equatable, Identifiable {
    var name: String
    var cornerRadius: Double
    var dark: Palette
    var light: Palette

    var id: String { name }
    func palette(dark isDark: Bool) -> Palette { isDark ? dark : light }

    /// Monochrome: white-on-black glass in Dark Mode, black-on-white frost in Light Mode.
    static let aether = Theme(
        name: "Aether Mono",
        cornerRadius: 26,
        dark: Palette(accent: HexColor("#FFFFFF"), tintColor: HexColor("#0A0A0C"), tintOpacity: 0.30,
                      glowColor: HexColor("#FFFFFF"), glowIntensity: 0.35, grain: 0.05, specular: 0.9),
        light: Palette(accent: HexColor("#000000"), tintColor: HexColor("#FFFFFF"), tintOpacity: 0.42,
                       glowColor: HexColor("#FFFFFF"), glowIntensity: 0.5, grain: 0.035, specular: 0.7)
    )
}

/// Loads `~/Library/Application Support/AetherOS/Themes/*.json`, publishes the active theme,
/// and re-applies it whenever the file changes (no relaunch).
@MainActor @Observable
final class ThemeEngine {
    func reloadFromDisk() { reload() }

    private(set) var current: Theme = .aether
    private(set) var available: [Theme] = [.aether]

    static var themesDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AetherOS/Themes", isDirectory: true)
    }

    private var source: DispatchSourceFileSystemObject?
    private var activeName: String = UserDefaults.standard.string(forKey: "theme") ?? Theme.aether.name

    init() {
        let dir = Self.themesDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        seedDefaultsIfNeeded(in: dir)
        reload()
        watch(dir)
    }

    func select(_ name: String) {
        activeName = name
        UserDefaults.standard.set(name, forKey: "theme")
        reload()
    }

    var activeThemeName: String { current.name }

    private func seedDefaultsIfNeeded(in dir: URL) {
        let url = dir.appendingPathComponent("aether-mono.json")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(Theme.aether).write(to: url)
    }

    private func reload() {
        let dir = Self.themesDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        let themes = files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Theme.self, from: Data(contentsOf: $0)) }
        available = themes.isEmpty ? [.aether] : themes
        current = available.first { $0.name == activeName } ?? available[0]
    }

    private func watch(_ dir: URL) {
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }
}
