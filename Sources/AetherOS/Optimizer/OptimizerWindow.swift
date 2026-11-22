import SwiftUI

enum OptimizerTab: String, CaseIterable, Sendable, Hashable, Identifiable {
    case organize, clean, large, apps, battery
    var id: String { rawValue }
    var title: String {
        switch self {
        case .organize: "Organize"
        case .clean: "Clean"
        case .large: "Large Files"
        case .apps: "Apps"
        case .battery: "Battery"
        }
    }
    var symbol: String {
        switch self {
        case .organize: "folder.badge.gearshape"
        case .clean: "sparkles"
        case .large: "externaldrive"
        case .apps: "app.badge.checkmark"
        case .battery: "battery.75"
        }
    }
}

final class OptimizerSelection: ObservableObject {
    @Published var tab: OptimizerTab = .clean
}

@MainActor
final class OptimizerWindowController {
    private var window: NSWindow?
    private let selection = OptimizerSelection()

    func show(tab: OptimizerTab) {
        selection.tab = tab
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "AetherOS Optimizer"
            w.contentView = NSHostingView(rootView: OptimizerRoot(selection: selection))
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 560, height: 440)
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct OptimizerRoot: View {
    @ObservedObject var selection: OptimizerSelection

    var body: some View {
        TabView(selection: $selection.tab) {
            OrganizeView().tabItem { Label("Organize", systemImage: OptimizerTab.organize.symbol) }.tag(OptimizerTab.organize)
            CleanView().tabItem { Label("Clean", systemImage: OptimizerTab.clean.symbol) }.tag(OptimizerTab.clean)
            LargeFilesView().tabItem { Label("Large Files", systemImage: OptimizerTab.large.symbol) }.tag(OptimizerTab.large)
            AppsView().tabItem { Label("Apps", systemImage: OptimizerTab.apps.symbol) }.tag(OptimizerTab.apps)
            BatteryView().tabItem { Label("Battery", systemImage: OptimizerTab.battery.symbol) }.tag(OptimizerTab.battery)
        }
        .frame(minWidth: 560, minHeight: 440)
    }
}
