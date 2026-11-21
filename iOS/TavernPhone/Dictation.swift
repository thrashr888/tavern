import AVFoundation
import Speech
import SwiftUI

/// The composer's mic: on-device speech to text while it's on, with the words as they come.
@MainActor
final class Dictation: ObservableObject {
    @Published private(set) var listening = false
    @Published private(set) var text = ""
    @Published var error: String?

    private let recognizer = SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func toggle() {
        if listening { stop() } else { Task { await start() } }
    }

    private func start() async {
        error = nil
        let speech = await withCheckedContinuation { done in SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) } }
        guard speech == .authorized else { error = "Speech recognition is off for Tavern in Settings."; return }
        guard await AVAudioApplication.requestRecordPermission() else { error = "The microphone is off for Tavern in Settings."; return }
        guard let recognizer, recognizer.isAvailable else { error = "Dictation isn't available right now."; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            self.request = request
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in request.append(buffer) }
            engine.prepare()
            try engine.start()
            text = ""
            listening = true
            task = recognizer.recognitionTask(with: request) { [weak self] result, failure in
                Task { @MainActor in
                    guard let self else { return }
                    if let result { self.text = result.bestTranscription.formattedString }
                    if failure != nil || result?.isFinal == true { self.stop() }
                }
            }
        } catch {
            self.error = "Couldn't start dictation: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        guard listening || request != nil else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        listening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
