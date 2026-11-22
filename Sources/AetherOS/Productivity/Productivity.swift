import AppKit
import Foundation

enum SystemCommand: Sendable, Hashable {
    case sleepDisplay, toggleDarkMode, toggleCaffeinate, openNotes
}

/// Runs a command-line tool without blocking the main thread. Output goes through temp files
/// so large outputs can't deadlock on a full pipe buffer.
enum Shell {
    struct Output: Sendable { let status: Int32; let stdout: String; let stderr: String }

    static func run(_ exe: String, _ args: [String], cwd: URL? = nil) async throws -> Output {
        let tmp = FileManager.default.temporaryDirectory
        let outURL = tmp.appendingPathComponent("aether-\(UUID().uuidString).out")
        let errURL = tmp.appendingPathComponent("aether-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outURL); try? FileManager.default.removeItem(at: errURL) }

        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            p.currentDirectoryURL = cwd
            p.standardOutput = try? FileHandle(forWritingTo: outURL)
            p.standardError = try? FileHandle(forWritingTo: errURL)
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
        return Output(
            status: status,
            stdout: String(decoding: (try? Data(contentsOf: outURL)) ?? Data(), as: UTF8.self),
            stderr: String(decoding: (try? Data(contentsOf: errURL)) ?? Data(), as: UTF8.self))
    }
}

enum Productivity {
    static var notesURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AetherOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("notes.md")
    }

    static func appendNote(_ text: String) {
        let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.colon).dateTimeSeparator(.space))
        let line = "- [\(stamp)] \(text)\n"
        let url = notesURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Fires a system notification via osascript (works without a signed app bundle).
    static func startTimer(seconds: Int, label: String) {
        Task.detached {
            try? await Task.sleep(for: .seconds(seconds))
            NSSound.beep()
            let msg = label.isEmpty ? "Time's up" : label
            let safe = msg.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "'")
            _ = try? await Shell.run("/usr/bin/osascript", ["-e",
                "display notification \"\(safe)\" with title \"AetherOS Timer\" sound name \"Glass\""])
        }
    }

    /// "10m", "90s", "1h", "5 min" → seconds
    static func parseDuration(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard let m = t.firstMatch(of: /^(\d+(?:\.\d+)?)\s*(s|sec|secs|m|min|mins|h|hr|hrs)?$/),
              let n = Double(m.1) else { return nil }
        let unit = m.2.map(String.init) ?? "m"
        let mult: Double = unit.hasPrefix("h") ? 3600 : unit.hasPrefix("s") ? 1 : 60
        let secs = Int(n * mult)
        return secs > 0 ? secs : nil
    }
}

// MARK: - Calculator

/// Small recursive-descent evaluator. (NSExpression raises uncatchable ObjC exceptions on bad input.)
enum Calculator {
    static func evaluate(_ input: String) -> String? {
        let s = input.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: ",", with: "")
        let allowed = Set("0123456789.+-*/^()% ")
        guard s.allSatisfy({ allowed.contains($0) }),
              s.contains(where: \.isNumber),
              s.contains(where: { "+-*/^%".contains($0) }) else { return nil }
        var p = Parser(chars: Array(s.filter { $0 != " " }))
        guard let v = p.expr(), p.atEnd, v.isFinite else { return nil }
        if v == v.rounded(), abs(v) < 1e15 { return String(Int(v)) }
        return String(format: "%.10g", v)
    }

    private struct Parser {
        let chars: [Character]
        var i = 0
        init(chars: [Character]) { self.chars = chars }
        var atEnd: Bool { i >= chars.count }
        func peek() -> Character? { i < chars.count ? chars[i] : nil }

        mutating func expr() -> Double? {
            guard var l = term() else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                i += 1
                guard let r = term() else { return nil }
                l = c == "+" ? l + r : l - r
            }
            return l
        }
        mutating func term() -> Double? {
            guard var l = unary() else { return nil }
            while let c = peek(), c == "*" || c == "/" || c == "%" {
                i += 1
                guard let r = unary() else { return nil }
                switch c {
                case "*": l *= r
                case "/": l /= r
                default: l = l.truncatingRemainder(dividingBy: r)
                }
            }
            return l
        }
        mutating func unary() -> Double? {
            if peek() == "-" { i += 1; return unary().map { -$0 } }
            return power()
        }
        mutating func power() -> Double? {
            guard let b = atom() else { return nil }
            if peek() == "^" { i += 1; guard let e = unary() else { return nil }; return pow(b, e) }
            return b
        }
        mutating func atom() -> Double? {
            if peek() == "(" {
                i += 1
                guard let v = expr(), peek() == ")" else { return nil }
                i += 1
                return v
            }
            let start = i
            while let c = peek(), c.isNumber || c == "." { i += 1 }
            return i > start ? Double(String(chars[start..<i])) : nil
        }
    }
}

// MARK: - Unit conversion ("10 km to mi", "72 f in c")

enum UnitConverter {
    private static let table: [String: Dimension] = [
        "mm": UnitLength.millimeters, "cm": UnitLength.centimeters, "m": UnitLength.meters, "km": UnitLength.kilometers,
        "in": UnitLength.inches, "ft": UnitLength.feet, "yd": UnitLength.yards, "mi": UnitLength.miles,
        "g": UnitMass.grams, "kg": UnitMass.kilograms, "lb": UnitMass.pounds, "oz": UnitMass.ounces,
        "c": UnitTemperature.celsius, "f": UnitTemperature.fahrenheit, "k": UnitTemperature.kelvin,
        "ml": UnitVolume.milliliters, "l": UnitVolume.liters, "gal": UnitVolume.gallons, "cup": UnitVolume.cups,
        "kmh": UnitSpeed.kilometersPerHour, "mph": UnitSpeed.milesPerHour, "ms": UnitSpeed.metersPerSecond,
        "mb": UnitInformationStorage.megabytes, "gb": UnitInformationStorage.gigabytes, "tb": UnitInformationStorage.terabytes,
        "sec": UnitDuration.seconds, "min": UnitDuration.minutes, "hr": UnitDuration.hours,
    ]

    static func convert(_ input: String) -> String? {
        let t = input.lowercased().replacingOccurrences(of: "°", with: "")
        guard let m = t.firstMatch(of: /^\s*(-?\d+(?:\.\d+)?)\s*([a-z]+)\s+(?:to|in)\s+([a-z]+)\s*$/),
              let value = Double(m.1),
              let from = table[String(m.2)], let to = table[String(m.3)],
              type(of: from) == type(of: to) else { return nil }
        let out = Measurement(value: value, unit: from).converted(to: to).value
        let formatted = out.formatted(.number.precision(.significantDigits(1...6)))
        return "\(formatted) \(m.3)"
    }
}

// MARK: - Clipboard history

@MainActor @Observable
final class ClipboardHistory {
    struct Entry: Identifiable, Hashable, Sendable {
        let id = UUID()
        let text: String
        let date: Date
    }

    private(set) var entries: [Entry] = []
    var isEnabled = false { didSet { isEnabled ? start() : stop() } }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastChange = NSPasteboard.general.changeCount

    /// Pasteboard types that password managers and apps mark as secret / temporary.
    private static let skipTypes: [NSPasteboard.PasteboardType] = [
        .init("org.nspasteboard.ConcealedType"), .init("org.nspasteboard.TransientType"),
        .init("org.nspasteboard.AutoGeneratedType"), .init("com.agilebits.onepassword"),
    ]

    private func start() {
        guard timer == nil else { return }
        lastChange = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func stop() { timer?.invalidate(); timer = nil; entries.removeAll() }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        let types = pb.types ?? []
        guard !types.contains(where: Self.skipTypes.contains),
              let raw = pb.string(forType: .string) else { return }
        let text = String(raw.prefix(5_000))
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        entries.removeAll { $0.text == text }
        entries.insert(Entry(text: text, date: .now), at: 0)
        if entries.count > 100 { entries.removeLast(entries.count - 100) }
    }
}
