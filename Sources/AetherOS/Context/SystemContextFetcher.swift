import AppKit
import ApplicationServices

/// Snapshot of what the user was looking at when the HUD was summoned.
struct SystemContext: Sendable, Equatable {
    var appName: String?
    var bundleID: String?
    var windowTitle: String?
    var selectedText: String?
    var focusedValue: String?      // truncated contents of the focused text field/area
    var filePaths: [String] = []
    var selectedFiles: [URL] = []   // Finder selection

    var isEmpty: Bool { selectedText == nil && focusedValue == nil && filePaths.isEmpty && appName == nil }

    /// Rendered into the model's system prompt. Kept small and clearly delimited.
    func promptBlock() -> String {
        var lines = ["<system_context>"]
        if let appName { lines.append("active_app: \(appName)") }
        if let windowTitle, !windowTitle.isEmpty { lines.append("window: \(windowTitle)") }
        if let selectedText, !selectedText.isEmpty { lines.append("selected_text:\n\(selectedText)") }
        else if let focusedValue, !focusedValue.isEmpty { lines.append("focused_field_text:\n\(focusedValue)") }
        if !filePaths.isEmpty { lines.append("files:\n" + filePaths.joined(separator: "\n")) }
        lines.append("</system_context>")
        return lines.joined(separator: "\n")
    }
}

/// Reads context from whichever app is frontmost using the Accessibility API.
/// Requires the user to grant Accessibility permission (System Settings ▸ Privacy & Security).
struct SystemContextFetcher: Sendable {
    static let maxChars = 8_000

    static func requestTrustIfNeeded() {
        // Literal value of kAXTrustedCheckOptionPrompt (the global is not Swift 6 concurrency-safe).
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Call this *before* the HUD takes key focus. Synchronous and bounded by an AX timeout.
    func capture() -> SystemContext {
        var ctx = SystemContext()
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return ctx }
        ctx.appName = app.localizedName
        ctx.bundleID = app.bundleIdentifier
        if app.bundleIdentifier == "com.apple.finder" {
            ctx.selectedFiles = finderSelection()
            ctx.filePaths += ctx.selectedFiles.map(\.path)
        }
        guard Self.isTrusted else { return ctx }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)   // a hung app must not freeze the HUD

        if let window: AXUIElement = attribute(appElement, kAXFocusedWindowAttribute) {
            ctx.windowTitle = attribute(window, kAXTitleAttribute)
            if let doc: String = attribute(window, kAXDocumentAttribute), let url = URL(string: doc), url.isFileURL {
                ctx.filePaths.append(url.path)
            }
        }

        if let focused: AXUIElement = attribute(appElement, kAXFocusedUIElementAttribute) {
            if let sel: String = attribute(focused, kAXSelectedTextAttribute), !sel.isEmpty {
                ctx.selectedText = String(sel.prefix(Self.maxChars))
            } else if let value: String = attribute(focused, kAXValueAttribute), !isSecure(focused) {
                ctx.focusedValue = String(value.prefix(Self.maxChars))
            }
        }
        return ctx
    }

    /// Finder has no AX selection API worth using, so ask it directly. First use shows the
    /// system "wants to control Finder" prompt (Automation permission).
    private func finderSelection() -> [URL] {
        let source = """
        with timeout of 2 seconds
            tell application "Finder"
                set sel to selection as alias list
                set out to {}
                repeat with f in sel
                    set end of out to POSIX path of f
                end repeat
                set AppleScript's text item delimiters to linefeed
                return out as text
            end tell
        end timeout
        """
        var error: NSDictionary?
        guard let text = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue else { return [] }
        return text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }

    // MARK: AX helpers

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value else { return nil }
        if T.self == AXUIElement.self {
            return CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! T) : nil
        }
        return value as? T
    }

    /// Never read password fields.
    private func isSecure(_ element: AXUIElement) -> Bool {
        let subrole: String? = attribute(element, kAXSubroleAttribute)
        return subrole == (kAXSecureTextFieldSubrole as String)
    }
}
