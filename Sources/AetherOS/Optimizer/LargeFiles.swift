import SwiftUI

struct BigFile: Identifiable, Sendable, Hashable {
    let url: URL
    let size: Int64
    let modified: Date?
    let accessed: Date?
    var id: URL { url }
}

enum LargeFileScanner {
    static var roots: [URL] {
        ["Downloads", "Desktop", "Documents", "Movies"].map { Disk.home.appendingPathComponent($0) }
    }

    /// Files ≥ minBytes in the user's main folders, optionally only ones not opened since `notOpenedSince`.
    nonisolated static func scan(minBytes: Int64, notOpenedSince: Date?, limit: Int = 200) -> [BigFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .contentAccessDateKey]
        var found: [BigFile] = []
        var visited = 0
        for root in roots {
            guard let en = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in en {
                visited += 1
                if visited > 400_000 || Task.isCancelled { return found.sorted { $0.size > $1.size } }
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                let size = Int64(v.totalFileAllocatedSize ?? 0)
                guard size >= minBytes else { continue }
                let accessed = v.contentAccessDate ?? v.contentModificationDate
                if let cutoff = notOpenedSince, let a = accessed, a > cutoff { continue }
                found.append(BigFile(url: url, size: size, modified: v.contentModificationDate, accessed: accessed))
            }
        }
        return Array(found.sorted { $0.size > $1.size }.prefix(limit))
    }
}

@MainActor
final class LargeFilesModel: ObservableObject {
    @Published var minMB: Double = 100
    @Published var onlyOld = false
    @Published private(set) var files: [BigFile] = []
    @Published var selected: Set<URL> = []
    @Published private(set) var isBusy = false
    @Published private(set) var status = ""
    private var scanTask: Task<Void, Never>?

    var selectedBytes: Int64 { files.filter { selected.contains($0.url) }.reduce(0) { $0 + $1.size } }

    func scan() {
        scanTask?.cancel()
        isBusy = true; status = "Scanning Downloads, Desktop, Documents and Movies…"
        let min = Int64(minMB) * 1_000_000
        let cutoff: Date? = onlyOld ? Calendar.current.date(byAdding: .year, value: -1, to: .now) : nil
        scanTask = Task {
            let result = await Task.detached { LargeFileScanner.scan(minBytes: min, notOpenedSince: cutoff) }.value
            guard !Task.isCancelled else { return }
            files = result; selected = []; isBusy = false
            status = result.isEmpty ? "No files that big." : "\(result.count) files · \(Disk.format(result.reduce(0) { $0 + $1.size }))"
        }
    }

    func trashSelected() {
        let chosen = files.filter { selected.contains($0.url) }.map(\.url)
        guard !chosen.isEmpty,
              confirm("Move \(chosen.count) file\(chosen.count == 1 ? "" : "s") to the Trash?",
                      "\(Disk.format(selectedBytes)) will move to the Trash. You can put them back from there until you empty it.",
                      button: "Move to Trash") else { return }
        let r = Disk.moveToTrash(chosen)
        status = "Moved \(r.trashed) to the Trash" + (r.failed > 0 ? " · \(r.failed) failed" : "")
        files.removeAll { selected.contains($0.url) }
        selected = []
    }
}

struct LargeFilesView: View {
    @StateObject private var model = LargeFilesModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Bigger than")
                Slider(value: $model.minMB, in: 25...2000, step: 25).frame(maxWidth: 200)
                Text("\(Int(model.minMB)) MB").monospacedDigit().frame(width: 70, alignment: .leading)
                Toggle("Not opened in a year", isOn: $model.onlyOld)
                Spacer()
                Button("Scan") { model.scan() }.disabled(model.isBusy)
            }
            if model.files.isEmpty {
                Spacer(); Text(model.status).foregroundStyle(.secondary).frame(maxWidth: .infinity); Spacer()
            } else {
                List(model.files) { f in
                    Toggle(isOn: setBinding($model.selected, f.url)) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(f.url.lastPathComponent).lineLimit(1)
                                Text("\(Disk.pretty(f.url.deletingLastPathComponent())) · opened \(f.accessed?.formatted(.relative(presentation: .named)) ?? "unknown")")
                                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(Disk.format(f.size)).monospacedDigit().foregroundStyle(.secondary)
                            Button { NSWorkspace.shared.activateFileViewerSelecting([f.url]) } label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(.plain).help("Show in Finder")
                        }
                    }
                }
            }
            HStack {
                Text(model.status).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button("Move \(Disk.format(model.selectedBytes)) to Trash") { model.trashSelected() }
                    .buttonStyle(.borderedProminent).disabled(model.selected.isEmpty)
            }
        }
        .padding(16)
        .onAppear { if model.files.isEmpty && !model.isBusy { model.scan() } }
    }
}
