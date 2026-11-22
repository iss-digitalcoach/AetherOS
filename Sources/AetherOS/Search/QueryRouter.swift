import AppKit

/// Turns what the user typed into result rows: calculator, unit conversion, clipboard, file
/// search, notes, timers and web search first, then fuzzy app/command search.
@MainActor
struct QueryRouter {
    let services: Services

    func results(for raw: String) async -> [SearchItem] {
        let q = raw.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return await services.index.search("") }
        let lower = q.lowercased()

        if let rest = after(lower, q, ["clip", "cb"]) {
            guard services.settings.clipboardEnabled else {
                return [row("clip-off", "Clipboard history is off", "Turn it on in Settings ▸ Tools", "doc.on.clipboard", .openSettings)]
            }
            let hits = services.clipboard.entries.filter { rest.isEmpty || $0.text.localizedCaseInsensitiveContains(rest) }
            return hits.prefix(10).map { e in
                let line = e.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? e.text
                return row("clip-\(e.id)", String(line.prefix(80)),
                           "Clipboard · \(e.date.formatted(.relative(presentation: .named))) · ↩ copies", "doc.on.clipboard", .copyText(e.text))
            }
        }

        if let rest = after(lower, q, ["f", "find"]), rest.count >= 2 {
            return await fileSearch(rest)
        }

        if let rest = after(lower, q, ["note", "n"]), !rest.isEmpty {
            return [row("note", "Save note: \(rest)", "Appends to notes.md", "note.text.badge.plus", .saveNote(rest))]
        }

        if let rest = after(lower, q, ["timer"]) {
            let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
            if let first = parts.first, let secs = Productivity.parseDuration(first) {
                let label = parts.count > 1 ? parts[1] : ""
                return [row("timer", "Timer: \(first)\(label.isEmpty ? "" : " · \(label)")", "Notifies you when it ends", "timer", .startTimer(seconds: secs, label: label))]
            }
            return [row("timer-help", "timer 10m  ·  timer 90s tea  ·  timer 1h", "Type a duration", "timer", .askAI)]
        }

        if let rest = after(lower, q, ["g", "web", "google"]), !rest.isEmpty { return [webRow(rest)] }

        var out: [SearchItem] = []
        if let r = Calculator.evaluate(q) {
            out.append(row("calc", "= \(r)", "Calculator · ↩ copies the result", "equal.circle", .copyText(r)))
        } else if let r = UnitConverter.convert(q) {
            out.append(row("unit", "= \(r)", "Unit conversion · ↩ copies the result", "ruler", .copyText(r)))
        }
        out += await services.index.search(q)
        out.append(webRow(q))
        out.append(row("ask-\(q)", "Ask Aether: \(q)", "Local AI", "sparkles", .askAI))
        return out
    }

    // MARK: Helpers

    /// "clip foo" → "foo". Also matches the bare keyword ("clip" → "").
    private func after(_ lower: String, _ original: String, _ keys: [String]) -> String? {
        for k in keys {
            if lower == k { return "" }
            if lower.hasPrefix(k + " ") { return String(original.dropFirst(k.count + 1)).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    private func webRow(_ query: String) -> SearchItem {
        var c = URLComponents(string: "https://duckduckgo.com/")!
        c.queryItems = [URLQueryItem(name: "q", value: query)]
        return row("web", "Search the web for “\(query)”", "Opens your default browser", "globe", .openURL(c.url!))
    }

    private func fileSearch(_ name: String) async -> [SearchItem] {
        guard let r = try? await Shell.run("/usr/bin/mdfind", ["-onlyin", NSHomeDirectory(), "-name", name]) else { return [] }
        return r.stdout.split(separator: "\n").prefix(40)
            .filter { !$0.contains("/Library/") && !$0.contains("/.") }
            .prefix(8)
            .map { path in
                let url = URL(fileURLWithPath: String(path))
                return row("file-\(path)", url.lastPathComponent,
                           url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                           "doc", .openFile(url))
            }
    }

    private func row(_ id: String, _ title: String, _ sub: String, _ symbol: String, _ action: SearchItem.Action) -> SearchItem {
        SearchItem(id: id, title: title, subtitle: sub, symbol: symbol, action: action)
    }
}
