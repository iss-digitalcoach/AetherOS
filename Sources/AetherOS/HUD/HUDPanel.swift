import AppKit
import SwiftUI

/// Floating, non-activating panel: takes keyboard focus for typing but never makes
/// AetherOS the frontmost app, so the user's previous app (and its selection) stays intact.
final class HUDPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Default AppKit behaviour pushes borderless windows below the menu bar; the notch HUD
    /// must be allowed to sit flush with the top edge of the screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func cancelOperation(_ sender: Any?) { orderOut(sender) }
}

@MainActor
final class HUDController {
    let style: HUDStyle
    private let panel: HUDPanel
    private let model: HUDViewModel
    private let services: Services
    private let fetcher = SystemContextFetcher()
    private var resignObserver: NSObjectProtocol?
    private var isHiding = false
    private var generation = 0

    private static var size: NSSize { NSSize(width: HUDView.size.width, height: HUDView.size.height) }

    init(style: HUDStyle, services: Services) {
        self.style = style
        self.services = services
        self.model = HUDViewModel(services: services)
        self.panel = HUDPanel(contentRect: NSRect(origin: .zero, size: Self.size))

        let root = HUDView(model: model, style: style, onDismiss: { [weak self] in self?.hide() })
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: Self.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    var isVisible: Bool { panel.isVisible && !isHiding }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        generation += 1
        isHiding = false
        panel.appearance = style == .notch ? NSAppearance(named: .darkAqua) : services.settings.appearance.nsAppearance

        // Capture BEFORE we take key focus: AX/Finder selection belongs to the previous app.
        model.begin(with: fetcher.capture())
        model.isVisible = true

        switch style {
        case .classic: showClassic()
        case .notch: showNotch()
        }
    }

    func hide() {
        guard panel.isVisible, !isHiding else { return }
        isHiding = true
        model.cancelWork()
        let gen = generation

        switch style {
        case .classic:
            let end = scaled(panel.frame, by: 0.97, dy: -6)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrame(end, display: true)
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.finishHide(gen) }
            })
        case .notch:
            model.notchExpanded = false              // SwiftUI springs the shape back into the notch
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { [weak self] in
                self?.finishHide(gen)
            }
        }
    }

    private func finishHide(_ gen: Int) {
        guard gen == generation else { return }     // a newer show() superseded this hide
        panel.orderOut(nil)
        model.isVisible = false
        isHiding = false
    }

    // MARK: Presentations

    private func showClassic() {
        let target = classicFrame()
        panel.setFrame(scaled(target, by: 0.95, dy: -10), display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
    }

    private func showNotch() {
        let screen = currentScreen()
        model.notch = NotchMetrics.forScreen(screen)
        model.notchExpanded = false
        // Flush with the very top edge (frame, not visibleFrame), centered on the notch.
        let f = screen.frame
        panel.setFrame(NSRect(x: f.midX - Self.size.width / 2, y: f.maxY - Self.size.height,
                              width: Self.size.width, height: Self.size.height), display: true)
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [model] in model.notchExpanded = true }
    }

    // MARK: Geometry

    private func currentScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func classicFrame() -> NSRect {
        let frame = currentScreen().visibleFrame
        let origin = NSPoint(x: frame.midX - Self.size.width / 2,
                             y: frame.minY + frame.height * 0.62 - Self.size.height / 2)
        return NSRect(origin: origin, size: Self.size)
    }

    private func scaled(_ r: NSRect, by s: CGFloat, dy: CGFloat) -> NSRect {
        let w = r.width * s, h = r.height * s
        return NSRect(x: r.midX - w / 2, y: r.midY - h / 2 + dy, width: w, height: h)
    }
}
