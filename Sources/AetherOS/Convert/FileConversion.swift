import AppKit
import AVFoundation
import PDFKit
import UniformTypeIdentifiers

struct Conversion: Identifiable, Sendable {
    let id: String
    let title: String       // "Convert to PNG"
    let label: String       // short text on the ring button
    let symbol: String
    let run: @Sendable ([URL]) async throws -> [URL]
}

enum ConvertError: LocalizedError {
    case tool(String), unsupported
    var errorDescription: String? {
        switch self {
        case .tool(let m): m.isEmpty ? "The converter failed." : m
        case .unsupported: "This file can't be converted that way."
        }
    }
}

/// Everything here uses tools that ship with macOS (sips, textutil, afconvert, zip) or system
/// frameworks (AVFoundation, PDFKit), so nothing needs to be installed.
enum ConversionCatalog {
    private enum Kind { case image, pdf, document, audio, video, folder, other }

    private static let docExts: Set<String> = ["txt", "rtf", "rtfd", "html", "htm", "doc", "docx", "odt", "md", "webarchive"]

    static func options(for urls: [URL]) -> [Conversion] {
        guard let first = urls.first else { return [] }
        let kinds = Set(urls.map(kind(of:)))
        var out: [Conversion] = []
        if kinds.count == 1 {
            switch kinds.first! {
            case .image: out += imageOptions(excluding: first.pathExtension.lowercased())
            case .pdf: out += pdfOptions()
            case .document: out += documentOptions(excluding: first.pathExtension.lowercased())
            case .audio: out += audioOptions(excluding: first.pathExtension.lowercased())
            case .video: out += videoOptions()
            case .folder, .other: break
            }
        }
        if Set(urls.map { $0.deletingLastPathComponent().path }).count == 1 { out.append(zip) }
        out.append(copyPath)
        return out
    }

    private static func kind(of url: URL) -> Kind {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
           url.pathExtension.isEmpty || url.pathExtension == "app" { return .folder }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if docExts.contains(ext) { return .document }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return .other
    }

    // MARK: Image (sips)

    private static func imageOptions(excluding ext: String) -> [Conversion] {
        let formats: [(String, String, String)] = [   // sips name, extension, label
            ("png", "png", "PNG"), ("jpeg", "jpg", "JPG"), ("heic", "heic", "HEIC"),
            ("tiff", "tiff", "TIFF"), ("gif", "gif", "GIF"), ("pdf", "pdf", "PDF"),
        ]
        var list = formats.filter { $0.1 != ext && !($0.1 == "jpg" && ext == "jpeg") }.map { f in
            Conversion(id: "img-\(f.0)", title: "Convert to \(f.2)", label: f.2,
                       symbol: f.0 == "pdf" ? "doc.richtext" : "photo") { urls in
                try await each(urls, ext: f.1) { src, dst in
                    try await tool("/usr/bin/sips", ["-s", "format", f.0, src.path, "--out", dst.path])
                }
            }
        }
        list.append(Conversion(id: "img-small", title: "Compress (JPG 60%)", label: "Small", symbol: "arrow.down.right.and.arrow.up.left") { urls in
            try await each(urls, ext: "jpg", suffix: " small") { src, dst in
                try await tool("/usr/bin/sips", ["-s", "format", "jpeg", "-s", "formatOptions", "60", src.path, "--out", dst.path])
            }
        })
        return list
    }

    // MARK: PDF

    private static func pdfOptions() -> [Conversion] {
        [
            Conversion(id: "pdf-png", title: "First page as PNG", label: "PNG", symbol: "photo") { urls in
                try await each(urls, ext: "png") { src, dst in
                    try await tool("/usr/bin/sips", ["-s", "format", "png", src.path, "--out", dst.path])
                }
            },
            Conversion(id: "pdf-txt", title: "Extract text", label: "TXT", symbol: "text.alignleft") { urls in
                try await each(urls, ext: "txt") { src, dst in
                    guard let text = PDFDocument(url: src)?.string, !text.isEmpty else {
                        throw ConvertError.tool("No selectable text (scanned PDF?)")
                    }
                    try text.write(to: dst, atomically: true, encoding: .utf8)
                }
            },
        ]
    }

    // MARK: Documents (textutil)

    private static func documentOptions(excluding ext: String) -> [Conversion] {
        let formats: [(String, String)] = [("txt", "TXT"), ("rtf", "RTF"), ("html", "HTML"), ("docx", "DOCX")]
        return formats.filter { $0.0 != ext }.map { f in
            Conversion(id: "doc-\(f.0)", title: "Convert to \(f.1)", label: f.1, symbol: "doc.text") { urls in
                try await each(urls, ext: f.0) { src, dst in
                    try await tool("/usr/bin/textutil", ["-convert", f.0, src.path, "-output", dst.path])
                }
            }
        }
    }

    // MARK: Audio (afconvert)

    private static func audioOptions(excluding ext: String) -> [Conversion] {
        let formats: [(label: String, ext: String, args: [String])] = [
            ("M4A", "m4a", ["-f", "m4af", "-d", "aac"]),
            ("WAV", "wav", ["-f", "WAVE", "-d", "LEI16"]),
            ("AIFF", "aiff", ["-f", "AIFF", "-d", "BEI16"]),
            ("CAF", "caf", ["-f", "caff", "-d", "LEI16"]),
        ]
        return formats.filter { $0.ext != ext }.map { f in
            Conversion(id: "aud-\(f.ext)", title: "Convert to \(f.label)", label: f.label, symbol: "waveform") { urls in
                try await each(urls, ext: f.ext) { src, dst in
                    try await tool("/usr/bin/afconvert", f.args + [src.path, dst.path])
                }
            }
        }
    }

    // MARK: Video (AVFoundation)

    private static func videoOptions() -> [Conversion] {
        let presets: [(id: String, title: String, label: String, preset: String, type: AVFileType, ext: String, symbol: String, suffix: String)] = [
            ("vid-1080", "MP4 · 1080p", "1080p", AVAssetExportPreset1920x1080, .mp4, "mp4", "film", " 1080p"),
            ("vid-720", "MP4 · 720p (smaller)", "720p", AVAssetExportPreset1280x720, .mp4, "mp4", "film", " 720p"),
            ("vid-mov", "MOV · highest quality", "MOV", AVAssetExportPresetHighestQuality, .mov, "mov", "film.stack", " export"),
            ("vid-m4a", "Extract audio (M4A)", "Audio", AVAssetExportPresetAppleM4A, .m4a, "m4a", "waveform", ""),
        ]
        return presets.map { p in
            Conversion(id: p.id, title: p.title, label: p.label, symbol: p.symbol) { urls in
                var outs: [URL] = []
                for src in urls {
                    let dst = uniqueURL(for: src, ext: p.ext, suffix: p.suffix)
                    let session = AVAssetExportSession(asset: AVURLAsset(url: src), presetName: p.preset)
                    guard let session else { throw ConvertError.unsupported }
                    session.outputURL = dst
                    session.outputFileType = p.type
                    await session.export()
                    guard session.status == .completed else {
                        throw ConvertError.tool(session.error?.localizedDescription ?? "Export failed")
                    }
                    outs.append(dst)
                }
                return outs
            }
        }
    }

    // MARK: Universal

    private static let zip = Conversion(id: "zip", title: "Compress to ZIP", label: "ZIP", symbol: "doc.zipper") { urls in
        let dir = urls[0].deletingLastPathComponent()
        let base = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archive"
        let dst = uniqueURL(in: dir, base: base, ext: "zip")
        try await tool("/usr/bin/zip", ["-r", "-q", dst.path] + urls.map(\.lastPathComponent), cwd: dir)
        return [dst]
    }

    private static let copyPath = Conversion(id: "path", title: "Copy path", label: "Path", symbol: "link") { urls in
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        return []
    }

    // MARK: Helpers

    private static func each(
        _ urls: [URL], ext: String, suffix: String = "",
        _ work: @Sendable (URL, URL) async throws -> Void
    ) async throws -> [URL] {
        var outs: [URL] = []
        for src in urls {
            let dst = uniqueURL(for: src, ext: ext, suffix: suffix)
            try await work(src, dst)
            outs.append(dst)
        }
        return outs
    }

    private static func tool(_ exe: String, _ args: [String], cwd: URL? = nil) async throws {
        let r = try await Shell.run(exe, args, cwd: cwd)
        guard r.status == 0 else {
            throw ConvertError.tool(r.stderr.split(separator: "\n").first.map(String.init) ?? r.stdout)
        }
    }

    /// Never overwrites: "Photo.png", then "Photo 2.png", "Photo 3.png"…
    private static func uniqueURL(for src: URL, ext: String, suffix: String) -> URL {
        uniqueURL(in: src.deletingLastPathComponent(),
                  base: src.deletingPathExtension().lastPathComponent + suffix, ext: ext)
    }

    private static func uniqueURL(in dir: URL, base: String, ext: String) -> URL {
        var url = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }
}
