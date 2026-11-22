import AppKit
import ApplicationServices

enum WindowLayout: Sendable, Hashable {
    case leftHalf, rightHalf, topHalf, bottomHalf, topLeft, topRight, bottomLeft, bottomRight
    case leftThird, centerThird, rightThird, maximize, center

    func frame(in area: CGRect) -> CGRect {
        switch self {
        case .leftHalf:  CGRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height)
        case .rightHalf: CGRect(x: area.midX, y: area.minY, width: area.width / 2, height: area.height)
        case .topHalf:    CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height / 2)
        case .bottomHalf: CGRect(x: area.minX, y: area.midY, width: area.width, height: area.height / 2)
        case .topLeft:     CGRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height / 2)
        case .topRight:    CGRect(x: area.midX, y: area.minY, width: area.width / 2, height: area.height / 2)
        case .bottomLeft:  CGRect(x: area.minX, y: area.midY, width: area.width / 2, height: area.height / 2)
        case .bottomRight: CGRect(x: area.midX, y: area.midY, width: area.width / 2, height: area.height / 2)
        case .leftThird:   CGRect(x: area.minX, y: area.minY, width: area.width / 3, height: area.height)
        case .centerThird: CGRect(x: area.minX + area.width / 3, y: area.minY, width: area.width / 3, height: area.height)
        case .rightThird:  CGRect(x: area.minX + area.width * 2 / 3, y: area.minY, width: area.width / 3, height: area.height)
        case .maximize:  area
        case .center:
            CGRect(x: area.minX + area.width * 0.15, y: area.minY + area.height * 0.1,
                   width: area.width * 0.7, height: area.height * 0.8)
        }
    }
}

/// Moves the focused window of the frontmost app via AX. AX uses a top-left origin in
/// global display coordinates, whereas NSScreen uses bottom-left, so we convert.
@MainActor
enum WindowManager {
    static func apply(_ layout: WindowLayout) {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }

        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return }
        let window = ref as! AXUIElement

        guard let screen = screenContaining(window) else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let vf = screen.visibleFrame
        let area = CGRect(x: vf.minX, y: primaryHeight - vf.maxY, width: vf.width, height: vf.height)
        var target = layout.frame(in: area)

        // Set size, then position, then size again: some apps clamp size before the move lands.
        setSize(window, target.size)
        setPosition(window, target.origin)
        setSize(window, target.size)
    }

    private static func screenContaining(_ window: AXUIElement) -> NSScreen? {
        var ref: CFTypeRef?
        var p = CGPoint.zero
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &ref) == .success, let ref {
            AXValueGetValue(ref as! AXValue, .cgPoint, &p)
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoa = CGPoint(x: p.x + 20, y: primaryHeight - p.y - 20)
        return NSScreen.screens.first { $0.frame.contains(cocoa) } ?? NSScreen.main
    }

    private static func setSize(_ el: AXUIElement, _ size: CGSize) {
        var s = size
        if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v) }
    }

    private static func setPosition(_ el: AXUIElement, _ point: CGPoint) {
        var p = point
        if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v) }
    }
}
