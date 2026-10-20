import AVFoundation
import Foundation
import Observation
import Speech

/// In-app dictation with the Speech framework. Records only while the capture screen
/// is open and the user hasn't stopped it; no background recording (FR-01).
@MainActor
@Observable
final class SpeechTranscriber {
    enum State: Equatable {
        case idle
        case requestingPermission
        case listening
        case stopped
        /// Speech can't be used; the keyboard is offered instead.
        case unavailable(String)
        /// Something interrupted recording; any text so far is kept.
        case interrupted(String)
    }

    private(set) var state: State = .idle
    var transcript = ""
    private(set) var levels: [CGFloat] = Array(repeating: 0.05, count: 32)
    private(set) var isOnDevice = false

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var autoStop: Task<Void, Never>?
    /// Hard cap so a forgotten capture never keeps the microphone open.
    static let maxDuration: Duration = .seconds(90)

    var isListening: Bool { state == .listening }

    func start(locale: Locale = .current) async {
        guard state != .listening else { return }
        state = .requestingPermission

        let speechStatus = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speechStatus == .authorized else {
            state = .unavailable("Speech recognition is off for Promise Tracker. You can type instead, or turn it on in Settings.")
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .unavailable("Microphone access is off for Promise Tracker. You can type instead, or turn it on in Settings.")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            state = .unavailable("Speech recognition isn’t available for your language right now. You can type instead.")
            return
        }
        self.recognizer = recognizer

        do {
            try beginSession(with: recognizer)
            state = .listening
            autoStop = Task { [weak self] in
                try? await Task.sleep(for: Self.maxDuration)
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        } catch {
            teardown()
            state = .unavailable("Couldn’t start the microphone (\(error.localizedDescription)). You can type instead.")
        }
    }

    private func beginSession(with recognizer: SFSpeechRecognizer) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        isOnDevice = recognizer.supportsOnDeviceRecognition
        if isOnDevice { request.requiresOnDeviceRecognition = true }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let level = Self.rms(buffer)
            Task { @MainActor [weak self] in self?.push(level: level) }
        }
        engine.prepare()
        try engine.start()

        let prefix = transcript.isEmpty ? "" : transcript + " "
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let text { self.transcript = prefix + text }
                if let error, self.state == .listening, !isFinal {
                    self.teardown()
                    self.state = self.transcript.isEmpty
                        ? .unavailable("Didn’t catch that (\(error.localizedDescription)). Try again or type instead.")
                        : .interrupted("Recording stopped early. Your words so far are kept.")
                } else if isFinal, self.state == .listening {
                    self.teardown()
                    self.state = .stopped
                }
            }
        }
    }

    func stop() {
        guard state == .listening else { return }
        request?.endAudio()
        teardown()
        state = .stopped
    }

    /// Discards everything (used by Cancel).
    func reset() {
        teardown()
        transcript = ""
        state = .idle
    }

    private func teardown() {
        autoStop?.cancel()
        autoStop = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        task?.finish()
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        levels = levels.map { _ in 0.05 }
    }

    private func push(level: CGFloat) {
        levels.removeFirst()
        levels.append(level)
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(n))
        // Map roughly -50…0 dB to 0…1.
        let db = 20 * log10(max(rms, 0.000_01))
        return CGFloat(max(0.05, min(1, (db + 50) / 50)))
    }

    static var speechAuthorization: SFSpeechRecognizerAuthorizationStatus { SFSpeechRecognizer.authorizationStatus() }
    static var microphoneGranted: Bool { AVAudioApplication.shared.recordPermission == .granted }
    static var microphoneDenied: Bool { AVAudioApplication.shared.recordPermission == .denied }
    static var supportsOnDevice: Bool { SFSpeechRecognizer()?.supportsOnDeviceRecognition ?? false }
}
