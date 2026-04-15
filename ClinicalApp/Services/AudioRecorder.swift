import AVFoundation

@MainActor
final class AudioRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var elapsed: Int = 0
    @Published var metering: Float = -160

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var meterTimer: Timer?
    private var startTime: Date?
    private var accumulated: TimeInterval = 0

    var fileURL: URL? { recorder?.url }

    func start() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("encounter_\(UUID().uuidString).m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
            AVEncoderBitRateKey: 128000,
        ]

        recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder?.isMeteringEnabled = true
        recorder?.record()

        isRecording = true
        isPaused = false
        elapsed = 0
        accumulated = 0
        startTime = Date()
        startTimers()
    }

    func pause() {
        recorder?.pause()
        isPaused = true
        if let s = startTime { accumulated += Date().timeIntervalSince(s) }
        stopTimers()
    }

    func resume() {
        recorder?.record()
        isPaused = false
        startTime = Date()
        startTimers()
    }

    func stop() -> URL? {
        stopTimers()
        let url = recorder?.url
        recorder?.stop()
        recorder = nil
        isRecording = false
        isPaused = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return url
    }

    func reset() {
        stopTimers()
        recorder?.stop()
        recorder = nil
        isRecording = false
        isPaused = false
        elapsed = 0
        metering = -160
    }

    private func startTimers() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let s = self.startTime else { return }
                self.elapsed = Int(self.accumulated + Date().timeIntervalSince(s))
            }
        }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.recorder?.updateMeters()
                self.metering = self.recorder?.averagePower(forChannel: 0) ?? -160
            }
        }
    }

    private func stopTimers() {
        timer?.invalidate(); timer = nil
        meterTimer?.invalidate(); meterTimer = nil
    }
}
