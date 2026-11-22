import SwiftUI
import AppKit
import Carbon.HIToolbox

@main
struct AetherOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("AetherOS", systemImage: "sparkle") {
            Button("Classic HUD") { delegate.toggle(.classic) }
            Button("Notch HUD") { delegate.toggle(.notch) }
            Divider()
            Button("Optimizer…") { delegate.services.openOptimizer() }
            Button("Settings…") { delegate.services.openSettings() }
                .keyboardShortcut(",")
            Button("Open Themes Folder") { NSWorkspace.shared.open(ThemeEngine.themesDirectory) }
            Divider()
            Button("Quit AetherOS") { NSApp.terminate(nil) }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let services = Services()
    private var huds: [HUDStyle: HUDController] = [:]
    private let hotkeys = HotkeyManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)          // no Dock icon, no menu bar takeover

        // ⌥Space opens the style chosen in Settings; ⌥⇧Space opens the other one.
        hotkeys.register(id: 1, keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak self] in
            guard let self else { return }
            toggle(services.settings.primaryStyle)
        }
        hotkeys.register(id: 2, keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey)) { [weak self] in
            guard let self else { return }
            toggle(services.settings.primaryStyle.other)
        }
        SystemContextFetcher.requestTrustIfNeeded()
    }

    func toggle(_ style: HUDStyle) {
        huds[style.other]?.hide()
        let hud = huds[style] ?? {
            let h = HUDController(style: style, services: services)
            huds[style] = h
            return h
        }()
        hud.toggle()
    }
}

/// Carbon hotkeys need no Accessibility permission and work while the app is inactive.
@MainActor
final class HotkeyManager {
    private var refs: [EventHotKeyRef?] = []
    private var handlerRef: EventHandlerRef?
    nonisolated(unsafe) private static var actions: [UInt32: @MainActor () -> Void] = [:]

    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
        Self.actions[id] = action
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let id = hk.id
                Task { @MainActor in HotkeyManager.actions[id]?() }
                return noErr
            }, 1, &spec, nil, &handlerRef)
        }
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x4145_5448) /* 'AETH' */, id: id)
        RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }
}
