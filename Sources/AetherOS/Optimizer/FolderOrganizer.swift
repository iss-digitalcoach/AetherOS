import SwiftUI

enum FileCategory: String, CaseIterable, Sendable, Identifiable {
    case images = "Images", documents = "Documents", spreadsheets = "Spreadsheets", presentations = "Presentations"
    case video = "Video", audio = "Audio", archives = "Archives", installers = "Installers"
    case code = "Code", other = "Other"
    var id: String { rawValue }

    private static let map: [FileCategory: Set<String>] = [
        .images: ["png", "jpg", "jpeg", "gif", "heic", "tiff", "bmp", "webp", "svg", "raw", "cr2", "psd"],
        .documents: ["pdf", "doc", "docx", "txt", "rtf", "pages", "md", "odt", "epub"],
        .spreadsheets: ["xls", "xlsx", "csv", "numbers", "ods"],
        .presentations: ["ppt", "pptx", "key", "odp"],
        .video: ["mp4", "mov", "m4v", "avi", "mkv", "webm"],
        .audio: ["mp3", "wav", "aac", "m4a", "flac", "aiff", "ogg"],
        .archives: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"],
        .installers: ["dmg", "pkg", "iso", "mpkg"],
        .code: ["swift", "py", "js", "ts", "html", "css", "json", "xml", "sh", "java", "c", "cpp", "h", "go", "rs", "rb", "php", "yml", "yaml"],
    ]

    static func of(_ url: URL) -> FileCategory {
        let ext = url.pathExtension.lowercased()
        return map.first { $0.value.contains(ext) }?.key ?? .other
    }
}

struct PlannedMove: Identifiable, Sendable {
    let id = UUID()
    let source: URL
    let category: FileCategory
}

struct MoveRecord: Codable, Sendable { let from: String; let to: String }

enum FolderOrganizer {
    private static let partial: Set<String> = ["crdownload", "download", "part", "opdownload", "tmp"]
    private static let categoryNames = Set(FileCategory.allCases.map(\.rawValue))

    static var logURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AetherOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("organize-log.json")
    }

    static func isAllowed(_ folder: URL) -> Bool {
        Disk.isInsideHome(folder) && !folder.path.hasPrefix(Disk.home.path + "/Library")
    }

    /// Non-recursive. Skips hidden files, folders, app bundles, partial downloads and anything touched in the last 2 minutes.
    nonisolated static func plan(in folder: URL, includeOther: Bool) -> [PlannedMove] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let cutoff = Date().addingTimeInterval(-120)
        return items.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.isDirectory != true, v.isPackage != true,
                  !partial.contains(url.pathExtension.lowercased()),
                  (v.contentModificationDate ?? .distantPast) < cutoff else { return nil }
            let cat = FileCategory.of(url)
            if cat == .other && !includeOther { return nil }
            return PlannedMove(source: url, category: cat)
        }
    }

    static func apply(_ moves: [PlannedMove], in folder: URL) -> (moved: Int, failed: Int) {
        guard isAllowed(folder) else { return (0, moves.count) }
        let fm = FileManager.default
        var records: [MoveRecord] = []
        var failed = 0
        for m in moves {
            let destDir = folder.appendingPathComponent(m.category.rawValue, isDirectory: true)
            do {
                try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                let dest = Disk.uniqueURL(in: destDir, name: m.source.lastPathComponent)
                try fm.moveItem(at: m.source, to: dest)
                records.append(MoveRecord(from: m.source.path, to: dest.path))
            } catch { failed += 1 }
        }
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: logURL) }
        return (records.count, failed)
    }

    static var canUndo: Bool {
        guard let data = try? Data(contentsOf: logURL),
              let r = try? JSONDecoder().decode([MoveRecord].self, from: data) else { return false }
        return !r.isEmpty
    }

    /// Puts files from the most recent organize back where they were (never overwrites).
    static func undoLast() -> (restored: Int, failed: Int) {
        guard let data = try? Data(contentsOf: logURL),
              let records = try? JSONDecoder().decode([MoveRecord].self, from: data) else { return (0, 0) }
        let fm = FileManager.default
        var ok = 0, bad = 0
        for r in records {
            let from = URL(fileURLWithPath: r.from), to = URL(fileURLWithPath: r.to)
            guard Disk.isInsideHome(from), fm.fileExists(atPath: to.path), !fm.fileExists(atPath: from.path) else { bad += 1; continue }
            do { try fm.moveItem(at: to, to: from); ok += 1 } catch { bad += 1 }
        }
        // Remove category folders we created if they're now empty.
        for name in categoryNames {
            if let any = records.first {
                let dir = URL(fileURLWithPath: any.from).deletingLastPathComponent().appendingPathComponent(name)
                if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true { try? fm.removeItem(at: dir) }
            }
        }
        try? fm.removeItem(at: logURL)
        return (ok, bad)
    }
}

@MainActor
final class OrganizeModel: ObservableObject {
    @Published var folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? Disk.home
    @Published var includeOther = false
    @Published private(set) var plan: [PlannedMove] = []
    @Published private(set) var status = ""
    @Published private(set) var isBusy = false
    @Published private(set) var canUndo = FolderOrganizer.canUndo

    var groups: [(category: FileCategory, files: [PlannedMove])] {
        Dictionary(grouping: plan, by: \.category)
            .map { (category: $0.key, files: $0.value.sorted { $0.source.lastPathComponent < $1.source.lastPathComponent }) }
            .sorted { $0.category.rawValue < $1.category.rawValue }
    }

    func choose() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.directoryURL = folder; p.prompt = "Choose"
        NSApp.activate()
        if p.runModal() == .OK, let url = p.url { folder = url; scan() }
    }

    func scan() {
        guard FolderOrganizer.isAllowed(folder) else { status = "Choose a folder inside your home folder (not Library)."; plan = []; return }
        isBusy = true; status = "Scanning…"
        let f = folder, other = includeOther
        Task {
            let result = await Task.detached { FolderOrganizer.plan(in: f, includeOther: other) }.value
            plan = result; isBusy = false
            status = result.isEmpty ? "Nothing to organize here." : "\(result.count) files can be sorted into \(Set(result.map(\.category)).count) folders."
        }
    }

    func apply() {
        guard !plan.isEmpty,
              confirm("Organize \(plan.count) files in \(Disk.pretty(folder))?",
                      "Files move into subfolders like Images and Documents. Nothing is deleted or overwritten, and you can undo this.",
                      button: "Organize") else { return }
        let moves = plan, f = folder
        isBusy = true
        Task {
            let r = await Task.detached { FolderOrganizer.apply(moves, in: f) }.value
            canUndo = FolderOrganizer.canUndo
            isBusy = false
            scan()
            status = "Moved \(r.moved) files" + (r.failed > 0 ? " · \(r.failed) skipped" : "")
        }
    }

    func undo() {
        isBusy = true
        Task {
            let r = await Task.detached { FolderOrganizer.undoLast() }.value
            canUndo = FolderOrganizer.canUndo
            isBusy = false
            scan()
            status = "Restored \(r.restored) files" + (r.failed > 0 ? " · \(r.failed) couldn't be restored" : "")
        }
    }
}

struct OrganizeView: View {
    @StateObject private var model = OrganizeModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(Disk.pretty(model.folder)).font(.headline)
                Spacer()
                Button("Choose…") { model.choose() }
                Button("Rescan") { model.scan() }
            }
            Toggle("Also move unrecognised files into “Other”", isOn: $model.includeOther)
                .onChange(of: model.includeOther) { _, _ in model.scan() }
            if model.plan.isEmpty {
                Spacer()
                Text(model.status).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(model.groups, id: \.category) { g in
                        DisclosureGroup("\(g.category.rawValue)  ·  \(g.files.count)") {
                            ForEach(g.files) { Text($0.source.lastPathComponent).lineLimit(1).font(.callout) }
                        }
                    }
                }
            }
            HStack {
                if !model.plan.isEmpty { Text(model.status).font(.footnote).foregroundStyle(.secondary) }
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button("Undo last") { model.undo() }.disabled(!model.canUndo || model.isBusy)
                Button("Organize \(model.plan.count) files") { model.apply() }
                    .buttonStyle(.borderedProminent).disabled(model.plan.isEmpty || model.isBusy)
            }
        }
        .padding(16)
        .onAppear { model.scan() }
    }
}
