import AVFoundation
import Speech
import Observation

/// On-device dictation. Audio never leaves the Mac: recognition is forced on-device, and if
/// the system can't do that for your language we say so rather than silently using Apple's servers.
@MainActor @Observable
final class VoiceInput {
    private(set) var isListening = false
    private(set) var error: String?

    /// Live transcript, called as words are recognised.
    @ObservationIgnored var onPartial: ((String) -> Void)?
    /// Called once when the user stops talking for a moment.
    @ObservationIgnored var onSilence: ((String) -> Void)?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    @ObservationIgnored private var lastText = ""
    @ObservationIgnored private let silenceDelay: Duration = .milliseconds(1600)

    func toggle() async {
        if isListening { stop() } else { await start() }
    }

    func start() async {
        guard !isListening else { return }
        error = nil
        guard await Self.requestSpeechAccess() else {
            error = "Speech recognition is not allowed. Enable it in System Settings → Privacy & Security."
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            error = "Microphone access is not allowed. Enable it in System Settings → Privacy & Security → Microphone."
            return
        }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            error = "Speech recognition isn't available right now."
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            error = "On-device dictation isn't available for your language. Enable Dictation in System Settings → Keyboard."
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        request = req
        lastText = ""

        let node = engine.inputNode
        Self.installTap(on: node, request: req)
        engine.prepare()
        do { try engine.start() } catch {
            self.error = "Couldn't start the microphone: \(error.localizedDescription)"
            node.removeTap(onBus: 0)
            request = nil
            return
        }

        task = recognizer.recognitionTask(with: req, resultHandler: Self.makeHandler(self))
        isListening = true
    }

    func stop() {
        guard isListening else { return }
        silenceTask?.cancel()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil; task = nil
        isListening = false
    }

    // MARK: Internals

    private func handle(text: String?, failed: Bool) {
        guard isListening else { return }
        if let text, !text.isEmpty {
            lastText = text
            onPartial?(text)
            silenceTask?.cancel()
            silenceTask = Task { [weak self] in
                try? await Task.sleep(for: self?.silenceDelay ?? .seconds(1.6))
                guard !Task.isCancelled, let self else { return }
                let final = lastText
                stop()
                onSilence?(final)
            }
        }
        if failed && lastText.isEmpty { stop() }
    }

    // These run on audio / recognition threads, so they must not inherit @MainActor isolation.
    nonisolated private static func installTap(on node: AVAudioInputNode, request: SFSpeechAudioBufferRecognitionRequest) {
        nonisolated(unsafe) let req = request
        node.installTap(onBus: 0, bufferSize: 1024, format: node.outputFormat(forBus: 0)) { buffer, _ in
            req.append(buffer)
        }
    }

    nonisolated private static func makeHandler(_ target: VoiceInput) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        return { [weak target] result, error in
            let text = result?.bestTranscription.formattedString
            let failed = error != nil
            Task { @MainActor in target?.handle(text: text, failed: failed) }
        }
    }

    private static func requestSpeechAccess() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }
}
