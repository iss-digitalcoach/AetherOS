import SwiftUI

struct CleanItem: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let url: URL
    let size: Int64
    let permanent: Bool      // emptied for good (Trash) vs. regenerable cache
    let inUse: Bool
}

enum CacheCleaner {
    private static var lib: URL { Disk.home.appendingPathComponent("Library") }
    private static var caches: URL { lib.appendingPathComponent("Caches") }
    private static var logs: URL { lib.appendingPathComponent("Logs") }
    private static var derived: URL { lib.appendingPathComponent("Developer/Xcode/DerivedData") }
    private static var npm: URL { Disk.home.appendingPathComponent(".npm/_cacache") }
    private static var trash: URL { Disk.home.appendingPathComponent(".Trash") }

    /// Only these roots may ever be emptied.
    private static var allowedRoots: [String] { [caches, logs, derived, npm, trash].map(\.path) }

    nonisolated static func scan(runningBundleIDs: Set<String>) -> [CleanItem] {
        var items: [CleanItem] = []
        let fm = FileManager.default
        let appCaches = (try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for dir in appCaches where !dir.lastPathComponent.hasPrefix("com.apple.") {
            let size = Disk.size(of: dir)
            guard size > 512_000 else { continue }
            let name = dir.lastPathComponent
            items.append(CleanItem(id: dir.path, title: name, detail: "App cache", url: dir, size: size,
                                   permanent: false, inUse: runningBundleIDs.contains(name)))
        }
        items.sort { $0.size > $1.size }
        items = Array(items.prefix(30))

        func add(_ id: String, _ title: String, _ detail: String, _ url: URL, permanent: Bool = false) {
            let s = Disk.size(of: url)
            if s > 0 { items.append(CleanItem(id: id, title: title, detail: detail, url: url, size: s, permanent: permanent, inUse: false)) }
        }
        add("logs", "App logs", "~/Library/Logs", logs)
        add("derived", "Xcode build files", "DerivedData · rebuilt automatically", derived)
        add("npm", "npm cache", "~/.npm/_cacache", npm)
        add("trash", "Empty the Trash", "Deletes everything in the Trash for good", trash, permanent: true)
        return items
    }

    /// Empties the *contents* of each item (the folder itself stays). Returns bytes actually freed.
    nonisolated static func clean(_ items: [CleanItem]) -> (freed: Int64, skipped: Int) {
        let fm = FileManager.default
        var freed: Int64 = 0, skipped = 0
        for item in items where !item.inUse {
            let path = item.url.resolvingSymlinksInPath().path
            guard allowedRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { skipped += 1; continue }
            let before = Disk.size(of: item.url)
            let children = (try? fm.contentsOfDirectory(at: item.url, includingPropertiesForKeys: nil, options: [])) ?? []
            for c in children {
                do { try fm.removeItem(at: c) } catch { skipped += 1 }
            }
            freed += max(0, before - Disk.size(of: item.url))
        }
        return (freed, skipped)
    }
}

@MainActor
final class CleanModel: ObservableObject {
    @Published private(set) var items: [CleanItem] = []
    @Published var selected: Set<String> = []
    @Published private(set) var isBusy = false
    @Published private(set) var status = ""

    var selectedBytes: Int64 { items.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size } }

    func scan() {
        isBusy = true; status = "Scanning…"
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        Task {
            let result = await Task.detached { CacheCleaner.scan(runningBundleIDs: running) }.value
            items = result
            selected = Set(result.filter { !$0.permanent && !$0.inUse }.map(\.id))   // Trash is opt-in
            isBusy = false
            status = result.isEmpty ? "Nothing to clean." : "\(Disk.format(result.reduce(0) { $0 + $1.size })) found"
        }
    }

    func clean() {
        let chosen = items.filter { selected.contains($0.id) && !$0.inUse }
        guard !chosen.isEmpty else { return }
        let permanent = chosen.contains { $0.permanent }
        guard confirm("Clean \(Disk.format(selectedBytes))?",
                      permanent ? "This includes emptying the Trash, which can't be undone. Caches are rebuilt by apps as needed."
                                : "These are temporary files that apps rebuild as needed. Apps may feel slightly slower the first time they open.",
                      button: "Clean") else { return }
        isBusy = true
        Task {
            let r = await Task.detached { CacheCleaner.clean(chosen) }.value
            isBusy = false
            scan()
            status = "Freed \(Disk.format(r.freed))" + (r.skipped > 0 ? " · \(r.skipped) protected items skipped" : "")
        }
    }
}

struct CleanView: View {
    @StateObject private var model = CleanModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Temporary files that are safe to remove. Apple's own caches are never touched.")
                .font(.callout).foregroundStyle(.secondary)
            if model.items.isEmpty {
                Spacer(); Text(model.status).foregroundStyle(.secondary).frame(maxWidth: .infinity); Spacer()
            } else {
                List(model.items) { item in
                    Toggle(isOn: setBinding($model.selected, item.id)) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.title).lineLimit(1)
                                Text(item.inUse ? "In use — quit the app first" : item.detail)
                                    .font(.footnote).foregroundStyle(item.permanent ? .orange : .secondary)
                            }
                            Spacer()
                            Text(Disk.format(item.size)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .disabled(item.inUse)
                }
            }
            HStack {
                Text(model.status).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button("Rescan") { model.scan() }.disabled(model.isBusy)
                Button("Clean \(Disk.format(model.selectedBytes))") { model.clean() }
                    .buttonStyle(.borderedProminent).disabled(model.selected.isEmpty || model.isBusy)
            }
        }
        .padding(16)
        .onAppear { if model.items.isEmpty { model.scan() } }
    }
}
