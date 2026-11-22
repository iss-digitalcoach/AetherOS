import AppKit
import AVFoundation
import Speech
import CoreServices

enum PermissionState: Equatable { case granted, denied, notDetermined }

/// macOS only lists an app under Privacy & Security *after* it has asked. These helpers make the
/// asking explicit (Settings → Tools → "Allow…") instead of waiting for a feature to trigger it.
@MainActor
final class PermissionsModel: ObservableObject {
    @Published var accessibility: PermissionState = .notDetermined
    @Published var microphone: PermissionState = .notDetermined
    @Published var speech: PermissionState = .notDetermined
    @Published var finder: PermissionState = .notDetermined
    private var observer: NSObjectProtocol?

    init() {
        refresh()
        // Re-check when the user comes back from System Settings.
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }

    func refresh() {
        accessibility = SystemContextFetcher.isTrusted ? .granted : .notDetermined
        microphone = Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
        speech = Self.map(SFSpeechRecognizer.authorizationStatus())
        Task { finder = await Self.finderStatus(prompt: false) }
    }

    func request(_ kind: Kind) {
        Task {
            switch kind {
            case .accessibility: SystemContextFetcher.requestTrustIfNeeded()
            case .microphone: _ = await AVCaptureDevice.requestAccess(for: .audio)
            case .speech: _ = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
            case .finder: finder = await Self.finderStatus(prompt: true)
            }
            refresh()
        }
    }

    enum Kind { case accessibility, microphone, speech, finder }

    func state(_ kind: Kind) -> PermissionState {
        switch kind {
        case .accessibility: accessibility
        case .microphone: microphone
        case .speech: speech
        case .finder: finder
        }
    }

    // MARK: Helpers

    private static func map(_ s: AVAuthorizationStatus) -> PermissionState {
        switch s { case .authorized: .granted; case .notDetermined: .notDetermined; default: .denied }
    }

    private static func map(_ s: SFSpeechRecognizerAuthorizationStatus) -> PermissionState {
        switch s { case .authorized: .granted; case .notDetermined: .notDetermined; default: .denied }
    }

    /// Asks macOS whether we may script Finder; with `prompt` it shows the system dialog.
    private static func finderStatus(prompt: Bool) async -> PermissionState {
        await Task.detached {
            let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
            // '****' wildcard class/id = "any event"
            let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, 0x2A2A_2A2A, 0x2A2A_2A2A, prompt)
            switch status {
            case noErr: return .granted
            case OSStatus(-1743): return .denied              // errAEEventNotPermitted
            default: return .notDetermined                    // -1744 would need consent, -600 Finder not running
            }
        }.value
    }
}
