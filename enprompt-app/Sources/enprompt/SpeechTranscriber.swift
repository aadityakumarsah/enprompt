import AVFoundation
import Foundation
import Speech

/// On-device speech-to-text via Apple's Speech framework. Records from the
/// default input device while the user holds the Option key.
final class SpeechTranscriber {

    /// Live partial transcript while the user is still talking.
    var onPartial: ((String) -> Void)?

    /// Final transcript once the user releases the key.
    var onFinal: ((Result<String, Error>) -> Void)?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Monotonic session id: a recognition task finishing after a newer
    /// session started must be dropped, or its stale transcript would be
    /// delivered as if it belonged to the current session.
    private var session = 0

    var isRunning: Bool { engine.isRunning }

    func start() {
        guard !engine.isRunning else { return }
        session += 1
        let thisSession = session
        // A task from a previous session may still be finalizing after stop();
        // cancel it so its result can never leak into this session.
        task?.cancel()
        task = nil
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            onFinal?(.failure(NSError(
                domain: "enprompt.STT",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Speech recognizer unavailable on this Mac"]
            )))
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self, self.session == thisSession else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                if result.isFinal {
                    self.task = nil
                    self.onFinal?(.success(text))
                } else {
                    self.onPartial?(text)
                }
            } else if let error {
                self.task = nil
                self.onFinal?(.failure(error))
            }
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            onFinal?(.failure(error))
        }
    }

    func stop() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        // End audio and let the recognition task finish naturally: it must
        // deliver the final transcript. Cancelling it here would produce
        // "Recognition request was canceled" and lose the dictation.
        request?.endAudio()
        request = nil
    }

    static func requestPermissions() async -> (mic: Bool, speech: Bool) {
        let mic = await AVAudioApplication.requestRecordPermission()
        let speech: Bool = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        return (mic, speech)
    }
}