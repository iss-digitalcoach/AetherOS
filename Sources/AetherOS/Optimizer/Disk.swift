import SwiftUI

enum Disk {
    static let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func pretty(_ url: URL) -> String {
        url.path.replacingOccurrences(of: home.path, with: "~")
    }

    /// True only for paths strictly inside the home folder (symlinks resolved), never the home itself.
    static func isInsideHome(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(home.path + "/")
    }

    /// Recursive on-disk size. Synchronous on purpose: call from a detached task.
    nonisolated static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        if !isDir.boolValue {
            let v = try? url.resourceValues(forKeys: keys)
            return Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [],
                                     errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in en {
            guard let v = try? u.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Recoverable delete. Refuses anything outside the home folder.
    static func moveToTrash(_ urls: [URL]) -> (trashed: Int, failed: Int) {
        var ok = 0, bad = 0
        for u in urls {
            guard isInsideHome(u) || isDeletableApp(u) else { bad += 1; continue }
            do { try FileManager.default.trashItem(at: u, resultingItemURL: nil); ok += 1 } catch { bad += 1 }
        }
        return (ok, bad)
    }

    /// Apps in /Applications are only removable when the current user owns them.
    static func isDeletableApp(_ url: URL) -> Bool {
        url.pathExtension == "app" && FileManager.default.isDeletableFile(atPath: url.path)
    }

    static func uniqueURL(in dir: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var url = dir.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }
}

@MainActor
func confirm(_ title: String, _ message: String, button: String) -> Bool {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = message
    a.alertStyle = .warning
    a.addButton(withTitle: button)
    a.addButton(withTitle: "Cancel")
    NSApp.activate()
    return a.runModal() == .alertFirstButtonReturn
}

/// View-local helpers: selection sets bound to toggles.
@MainActor
func setBinding<T: Hashable>(_ set: Binding<Set<T>>, _ item: T) -> Binding<Bool> {
    Binding(get: { set.wrappedValue.contains(item) },
            set: { on in if on { set.wrappedValue.insert(item) } else { set.wrappedValue.remove(item) } })
}
