import AppKit

struct SearchItem: Identifiable, Sendable, Hashable {
    enum Action: Sendable, Hashable {
        case launchApp(URL)
        case snap(WindowLayout)
        case askAI
        case openURL(URL)
        case copyText(String)
        case openFile(URL)
        case revealFile(URL)
        case quitApp(pid_t)
        case system(SystemCommand)
        case saveNote(String)
        case startTimer(seconds: Int, label: String)
        case openSettings
        case openOptimizer(OptimizerTab)
    }
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let action: Action
    var lowerTitle: [UInt8] { Array(title.lowercased().utf8) }
}

/// In-memory index. Titles are pre-lowercased UTF-8 byte arrays so a query scans thousands
/// of entries in well under a millisecond with no allocations in the hot loop.
actor SearchIndex {
    private struct Entry { let item: SearchItem; let key: [UInt8] }
    private var entries: [Entry] = []
    private var usage: [String: Int] = [:]
    private var dynamic: [Entry] = []      // e.g. "Quit Safari": refreshed every time the HUD opens

    init() {}

    func rebuild() async {
        var items: [SearchItem] = Self.builtins
        for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    NSHomeDirectory() + "/Applications"] {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? []
            for u in urls where u.pathExtension == "app" {
                items.append(SearchItem(id: u.path, title: u.deletingPathExtension().lastPathComponent,
                                        subtitle: "Application", symbol: "app.dashed", action: .launchApp(u)))
            }
        }
        entries = items.map { Entry(item: $0, key: $0.lowerTitle) }
    }

    func setUsage(_ u: [String: Int]) { usage = u }

    func setDynamic(_ items: [SearchItem]) {
        dynamic = items.map { Entry(item: $0, key: $0.lowerTitle) }
    }

    func search(_ query: String, limit: Int = 8) -> [SearchItem] {
        let q = Array(query.lowercased().utf8)
        guard !q.isEmpty else {
            // Most-used first; ties keep the built-in order.
            return Array(entries.sorted { (usage[$0.item.id] ?? 0) > (usage[$1.item.id] ?? 0) }.prefix(limit).map(\.item))
        }
        var scored: [(Int, SearchItem)] = []
        for e in entries + dynamic {
            if let s = Self.score(query: q, in: e.key) { scored.append((s + min(usage[e.item.id] ?? 0, 15) * 6, e.item)) }
        }
        scored.sort { $0.0 > $1.0 }
        return scored.prefix(limit).map(\.1)
    }

    /// Subsequence match with bonuses for consecutive runs, word starts and prefix hits.
    static func score(query q: [UInt8], in t: [UInt8]) -> Int? {
        var qi = 0, score = 0, run = 0
        var prev: UInt8 = 0x20
        for (ti, ch) in t.enumerated() where qi < q.count {
            if ch == q[qi] {
                run += 1
                score += 10 + run * 5
                if prev == 0x20 || prev == 0x2D || prev == 0x5F { score += 15 }
                if ti == 0 { score += 20 }
                qi += 1
            } else {
                run = 0
                score -= 1
            }
            prev = ch
        }
        return qi == q.count ? score - t.count : nil
    }

    private static func cmd(_ id: String, _ title: String, _ sub: String, _ symbol: String, _ action: SearchItem.Action) -> SearchItem {
        SearchItem(id: id, title: title, subtitle: sub, symbol: symbol, action: action)
    }

    private static let builtins: [SearchItem] = [
        cmd("ai", "Ask Aether", "Local AI · uses selected text", "sparkles", .askAI),
        cmd("settings", "AetherOS Settings", "Model, theme, HUD style", "gearshape", .openSettings),
        cmd("opt", "Optimizer", "Clean, organize, uninstall, battery", "wand.and.sparkles", .openOptimizer(.clean)),
        cmd("opt-org", "Organize a Folder", "Sort Downloads into Images, Documents…", "folder.badge.gearshape", .openOptimizer(.organize)),
        cmd("opt-clean", "Clean Caches", "Free space from temporary files", "sparkles", .openOptimizer(.clean)),
        cmd("opt-large", "Find Large Files", "Delete big files you don't need", "externaldrive", .openOptimizer(.large)),
        cmd("opt-apps", "Uninstall Apps", "Remove unused apps and leftovers", "app.badge.checkmark", .openOptimizer(.apps)),
        cmd("opt-batt", "Battery Saver", "Find what's draining your battery", "battery.75", .openOptimizer(.battery)),
        cmd("snap-l", "Snap Left Half", "Window", "rectangle.lefthalf.filled", .snap(.leftHalf)),
        cmd("snap-r", "Snap Right Half", "Window", "rectangle.righthalf.filled", .snap(.rightHalf)),
        cmd("snap-t", "Snap Top Half", "Window", "rectangle.tophalf.filled", .snap(.topHalf)),
        cmd("snap-b", "Snap Bottom Half", "Window", "rectangle.bottomhalf.filled", .snap(.bottomHalf)),
        cmd("snap-tl", "Snap Top Left", "Window · quarter", "rectangle.inset.topleading.filled", .snap(.topLeft)),
        cmd("snap-tr", "Snap Top Right", "Window · quarter", "rectangle.inset.toptrailing.filled", .snap(.topRight)),
        cmd("snap-bl", "Snap Bottom Left", "Window · quarter", "rectangle.inset.bottomleading.filled", .snap(.bottomLeft)),
        cmd("snap-br", "Snap Bottom Right", "Window · quarter", "rectangle.inset.bottomtrailing.filled", .snap(.bottomRight)),
        cmd("snap-1/3", "Snap Left Third", "Window", "rectangle.leadingthird.inset.filled", .snap(.leftThird)),
        cmd("snap-c3", "Snap Center Third", "Window", "rectangle.center.inset.filled", .snap(.centerThird)),
        cmd("snap-3/3", "Snap Right Third", "Window", "rectangle.trailingthird.inset.filled", .snap(.rightThird)),
        cmd("snap-f", "Maximize Window", "Window", "rectangle.fill", .snap(.maximize)),
        cmd("snap-c", "Center Window", "Window", "rectangle.center.inset.filled", .snap(.center)),
        cmd("sleep-display", "Sleep Display", "System", "moon.zzz", .system(.sleepDisplay)),
        cmd("dark-mode", "Toggle Dark Mode", "System · asks to control System Events", "circle.lefthalf.filled", .system(.toggleDarkMode)),
        cmd("caffeinate", "Keep Mac Awake (toggle)", "System · caffeinate", "cup.and.saucer", .system(.toggleCaffeinate)),
        cmd("notes", "Open Notes File", "Quick notes · type “note …” to add", "note.text", .system(.openNotes)),
    ]
}
