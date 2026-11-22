import SwiftUI

struct Leftover: Sendable, Hashable { let url: URL; let size: Int64 }

struct InstalledApp: Identifiable, Sendable, Hashable {
    let url: URL
    let name: String
    let bundleID: String
    let size: Int64
    let lastUsed: Date?
    let leftovers: [Leftover]
    let removable: Bool
    var id: URL { url }
    var totalSize: Int64 { size + leftovers.reduce(0) { $0 + $1.size } }
}

struct LaunchAgentItem: Identifiable, Sendable, Hashable {
    let url: URL
    let label: String
    let program: String
    var id: URL { url }
}

enum AppScanner {
    nonisolated static func scan() -> [InstalledApp] {
        let fm = FileManager.default
        let roots = [URL(fileURLWithPath: "/Applications"), Disk.home.appendingPathComponent("Applications")]
        let ownID = Bundle.main.bundleIdentifier ?? ""
        var apps: [InstalledApp] = []
        for root in roots {
            let urls = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for url in urls where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                      !id.hasPrefix("com.apple."), id != ownID else { continue }   // never Apple apps or ourselves
                let name = url.deletingPathExtension().lastPathComponent
                apps.append(InstalledApp(url: url, name: name, bundleID: id, size: Disk.size(of: url),
                                         lastUsed: lastUsed(url), leftovers: leftovers(name: name, id: id),
                                         removable: fm.isDeletableFile(atPath: url.path)))
            }
        }
        // Longest-unused first; never-used (nil) at the very top.
        return apps.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
    }

    private nonisolated static func lastUsed(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, "kMDItemLastUsedDate" as CFString) as? Date
    }

    private nonisolated static func leftovers(name: String, id: String) -> [Leftover] {
        let lib = Disk.home.appendingPathComponent("Library")
        let candidates = [
            "Application Support/\(id)", "Application Support/\(name)", "Caches/\(id)", "Caches/\(name)",
            "Preferences/\(id).plist", "Saved Application State/\(id).savedState", "Logs/\(name)",
            "HTTPStorages/\(id)", "WebKit/\(id)", "Containers/\(id)",
        ].map { lib.appendingPathComponent($0) }
        return candidates.compactMap { u in
            FileManager.default.fileExists(atPath: u.path) ? Leftover(url: u, size: Disk.size(of: u)) : nil
        }
    }

    nonisolated static func launchAgents() -> [LaunchAgentItem] {
        let dir = Disk.home.appendingPathComponent("Library/LaunchAgents")
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "plist" }.compactMap { u in
            guard let d = NSDictionary(contentsOf: u) as? [String: Any] else { return nil }
            let label = d["Label"] as? String ?? u.deletingPathExtension().lastPathComponent
            let prog = (d["ProgramArguments"] as? [String])?.first ?? d["Program"] as? String ?? ""
            return LaunchAgentItem(url: u, label: label, program: prog)
        }.sorted { $0.label < $1.label }
    }
}

@MainActor
final class AppsModel: ObservableObject {
    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var agents: [LaunchAgentItem] = []
    @Published var selection: URL?
    @Published private(set) var isBusy = false
    @Published private(set) var status = ""

    var selectedApp: InstalledApp? { apps.first { $0.url == selection } }

    func scan() {
        isBusy = true; status = "Scanning installed apps…"
        Task {
            let (a, l) = await Task.detached { (AppScanner.scan(), AppScanner.launchAgents()) }.value
            apps = a; agents = l; isBusy = false
            status = "\(a.count) third-party apps"
        }
    }

    func uninstall(_ app: InstalledApp) {
        let list = ([app.url.lastPathComponent] + app.leftovers.map { Disk.pretty($0.url) }).joined(separator: "\n")
        guard confirm("Move \(app.name) to the Trash?",
                      "Frees \(Disk.format(app.totalSize)). Moving to the Trash is reversible.\n\n\(list)",
                      button: "Move to Trash") else { return }
        var urls = app.leftovers.map(\.url)
        if app.removable { urls.insert(app.url, at: 0) }
        let r = Disk.moveToTrash(urls)
        status = "Moved \(r.trashed) items to the Trash" + (r.failed > 0 ? " · \(r.failed) failed" : "")
        apps.removeAll { $0.url == app.url }
        selection = nil
    }

    func remove(_ agent: LaunchAgentItem) {
        guard confirm("Stop and remove “\(agent.label)”?",
                      "This background item runs automatically at login. Its file moves to the Trash, so you can restore it.\n\n\(agent.program)",
                      button: "Remove") else { return }
        Task {
            _ = try? await Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())", agent.url.path])
            _ = Disk.moveToTrash([agent.url])
            agents.removeAll { $0.url == agent.url }
            status = "Removed \(agent.label)"
        }
    }
}

struct AppsView: View {
    @StateObject private var model = AppsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Third-party apps, least recently used first. Apple's built-in apps can't be removed and aren't listed.")
                .font(.callout).foregroundStyle(.secondary)
            List(selection: $model.selection) {
                Section("Apps") {
                    ForEach(model.apps) { app in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(app.name)
                                Text(app.lastUsed.map { "Last used \($0.formatted(.relative(presentation: .named)))" } ?? "No usage recorded")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Disk.format(app.totalSize)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .tag(app.url)
                    }
                }
                if !model.agents.isEmpty {
                    Section("Background items that start at login") {
                        ForEach(model.agents) { a in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(a.label).lineLimit(1)
                                    Text(a.program).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Button("Remove") { model.remove(a) }
                            }
                        }
                    }
                }
            }
            HStack {
                if let app = model.selectedApp {
                    Text(app.removable ? "\(app.name) + \(app.leftovers.count) leftover folders · \(Disk.format(app.totalSize))"
                                       : "\(app.name) needs an administrator to remove. Drag it to the Trash yourself.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text(model.status).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button("Move to Trash…") { if let a = model.selectedApp { model.uninstall(a) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedApp?.removable != true)
            }
        }
        .padding(16)
        .onAppear { if model.apps.isEmpty { model.scan() } }
    }
}
