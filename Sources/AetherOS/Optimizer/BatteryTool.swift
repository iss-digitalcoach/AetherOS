import SwiftUI

struct BatteryStatus: Sendable {
    var percent: Int?
    var state: String
    var remaining: String?
    var onBattery: Bool
    var hasBattery: Bool
}

struct BatteryHealth: Sendable {
    var cycles: String?
    var condition: String?
    var maxCapacity: String?
}

struct EnergyHog: Identifiable, Sendable {
    let appURL: URL
    let name: String
    let cpu: Double
    var id: URL { appURL }
}

enum BatteryTool {
    static func status() async -> BatteryStatus {
        let out = (try? await Shell.run("/usr/bin/pmset", ["-g", "batt"]))?.stdout ?? ""
        let hasBattery = out.contains("InternalBattery")
        let percent = out.firstMatch(of: /(\d+)%/).flatMap { Int($0.1) }
        let remaining = out.firstMatch(of: /(\d+:\d+) remaining/).map { String($0.1) }
        let state = ["discharging", "finishing charge", "charging", "charged", "AC attached"].first { out.contains($0) } ?? "unknown"
        return BatteryStatus(percent: percent, state: state, remaining: remaining,
                             onBattery: out.contains("'Battery Power'"), hasBattery: hasBattery)
    }

    static func health() async -> BatteryHealth {
        let out = (try? await Shell.run("/usr/sbin/system_profiler", ["SPPowerDataType"]))?.stdout ?? ""
        func value(_ key: String) -> String? {
            out.split(separator: "\n").first { $0.contains("\(key):") }
                .map { $0.split(separator: ":", maxSplits: 1).last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "" }
        }
        return BatteryHealth(cycles: value("Cycle Count"), condition: value("Condition"), maxCapacity: value("Maximum Capacity"))
    }

    /// Apps using the most CPU right now (helpers are rolled into their parent app).
    static func hogs() async -> [EnergyHog] {
        let out = (try? await Shell.run("/bin/ps", ["-Ao", "pcpu=,comm=", "-r"]))?.stdout ?? ""
        var totals: [String: Double] = [:]
        for line in out.split(separator: "\n").prefix(80) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "), let cpu = Double(trimmed[..<space]) else { continue }
            let path = String(trimmed[space...]).trimmingCharacters(in: .whitespaces)
            guard !path.hasPrefix("/System/"), let r = path.range(of: ".app") else { continue }
            totals[String(path[..<r.upperBound]), default: 0] += cpu
        }
        let own = Bundle.main.bundleURL.path
        return totals.filter { $0.value >= 1.0 && $0.key != own }
            .map { EnergyHog(appURL: URL(fileURLWithPath: $0.key), name: URL(fileURLWithPath: $0.key).deletingPathExtension().lastPathComponent, cpu: $0.value) }
            .sorted { $0.cpu > $1.cpu }.prefix(8).map { $0 }
    }

    @MainActor static func quit(_ hog: EnergyHog, force: Bool) {
        guard let id = Bundle(url: hog.appURL)?.bundleIdentifier else { return }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
            if force { _ = app.forceTerminate() } else { _ = app.terminate() }
        }
    }
}

@MainActor
final class BatteryModel: ObservableObject {
    @Published private(set) var status: BatteryStatus?
    @Published private(set) var health: BatteryHealth?
    @Published private(set) var hogs: [EnergyHog] = []
    private var timer: Timer?

    func start() {
        refresh()
        Task { health = await BatteryTool.health() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        Task {
            async let s = BatteryTool.status()
            async let h = BatteryTool.hogs()
            status = await s; hogs = await h
        }
    }
}

struct BatteryView: View {
    @StateObject private var model = BatteryModel()
    @AppStorage("ecoMode") private var ecoMode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            summary
            Divider()
            Text("Using the most CPU right now").font(.headline)
            if model.hogs.isEmpty {
                Text("Nothing is working hard. Your Mac is idle.").foregroundStyle(.secondary)
            } else {
                List(model.hogs) { hog in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: hog.appURL.path)).resizable().frame(width: 24, height: 24)
                        Text(hog.name)
                        Spacer()
                        Text("\(Int(hog.cpu))% CPU").monospacedDigit().foregroundStyle(.secondary)
                        Button("Quit") { BatteryTool.quit(hog, force: false) }
                        Button("Force") { BatteryTool.quit(hog, force: true) }.help("Force quit — unsaved work is lost")
                    }
                }
            }
            Divider()
            Toggle("AetherOS eco mode (glass animation at 30 fps)", isOn: $ecoMode)
            HStack {
                Button("Open Battery settings (Low Power Mode)") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
                }
                Button("Sleep display now") { Task { _ = try? await Shell.run("/usr/bin/pmset", ["displaysleepnow"]) } }
            }
            Text("Low Power Mode and screen brightness can only be changed by you in System Settings; macOS doesn't let apps toggle them without administrator rights.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(16)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    @ViewBuilder private var summary: some View {
        if let s = model.status, s.hasBattery {
            HStack(spacing: 18) {
                Image(systemName: s.onBattery ? "battery.50" : "battery.100.bolt").font(.system(size: 34))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(s.percent.map(String.init) ?? "–")% · \(s.state)").font(.title3.weight(.medium))
                    Text(s.remaining.map { "\($0) remaining" } ?? "Time estimate not available").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if let h = model.health {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Health: \(h.maxCapacity ?? h.condition ?? "–")")
                        Text("\(h.cycles ?? "–") charge cycles").foregroundStyle(.secondary)
                    }.font(.callout)
                }
            }
        } else {
            Label("No battery detected. This tab is most useful on a MacBook.", systemImage: "powerplug").foregroundStyle(.secondary)
        }
    }
}
