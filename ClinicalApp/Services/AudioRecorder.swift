import AVFoundation
import UIKit

/// Singleton AVAudioRecorder wrapper. Lives at app level so it survives view
/// recycles, backgrounding, and navigation. Handles interruptions, route changes,
/// and surfaces actual recorder state so the UI can never lie about recording status.
@MainActor
final class AudioRecorder: ObservableObject {
    static let shared = AudioRecorder()

    // MARK: - Published state (drives UI)
    @Published var isRecording = false          // doctor's intent: recording active
    @Published var isPaused = false             // doctor's intent: paused
    @Published var elapsed: Int = 0
    @Published var metering: Float = -160
    @Published var recordingStopped = false     // true if recorder died unexpectedly

    // MARK: - Private
    private var recorder: AVAudioRecorder?
    private var delegate: RecorderDelegate?
    private var timer: Timer?
    private var meterTimer: Timer?
    private var startTime: Date?
    private var accumulated: TimeInterval = 0

    var fileURL: URL? { recorder?.url }

    // MARK: - Init / notifications
    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        }
        nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleRouteChange(note) }
        }
        nc.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                print("[AudioRecorder] MEDIA SERVICES RESET — recording lost!")
                self?.markDead()
            }
        }
        nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.logLifecycle("BACKGROUNDED") }
        }
        nc.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.logLifecycle("FOREGROUND")
                // Verify the recorder is still alive after backgrounding
                if self.isRecording && !self.isPaused && self.recorder?.isRecording == false {
                    print("[AudioRecorder] Recorder died while backgrounded — marking stopped")
                    self.markDead()
                }
            }
        }
    }

    // MARK: - Start
    func start() async throws {
        print("[AudioRecorder] START requested")

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.defaultToSpeaker, .allowBluetooth]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        print("[AudioRecorder] Session active — category: \(session.category.rawValue), mode: \(session.mode.rawValue), sampleRate: \(session.sampleRate)")
        print("[AudioRecorder] Current route: \(session.currentRoute.inputs.map { $0.portName }.joined(separator: ","))")

        // Use documents dir (permanent) not tmp (iOS may purge in background)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent("encounter_\(UUID().uuidString).m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
            AVEncoderBitRateKey: 128000,
        ]

        let r = try AVAudioRecorder(url: url, settings: settings)
        let del = RecorderDelegate { [weak self] in
            Task { @MainActor in
                print("[AudioRecorder] Delegate: finished recording (unexpected)")
                self?.markDead()
            }
        } encodeError: { [weak self] err in
            Task { @MainActor in
                print("[AudioRecorder] Delegate: encode error: \(err?.localizedDescription ?? "nil")")
                self?.markDead()
            }
        }
        r.delegate = del
        r.isMeteringEnabled = true
        let ok = r.record()
        print("[AudioRecorder] record() returned \(ok), url: \(url.lastPathComponent)")
        guard ok else { throw NSError(domain: "AudioRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to start recording"]) }

        recorder = r
        delegate = del
        isRecording = true
        isPaused = false
        recordingStopped = false
        elapsed = 0
        accumulated = 0
        startTime = Date()
        startTimers()
    }

    // MARK: - Pause / Resume
    func pause() {
        print("[AudioRecorder] PAUSE at \(elapsed)s")
        recorder?.pause()
        if let s = startTime { accumulated += Date().timeIntervalSince(s) }
        isPaused = true
        stopTimers()
    }

    func resume() {
        print("[AudioRecorder] RESUME at \(elapsed)s")
        let ok = recorder?.record() ?? false
        print("[AudioRecorder] resume record() returned \(ok)")
        startTime = Date()
        isPaused = false
        startTimers()
    }

    // MARK: - Stop
    @discardableResult
    func stop() -> URL? {
        print("[AudioRecorder] STOP at \(elapsed)s")
        stopTimers()
        let url = recorder?.url
        recorder?.stop()
        if let url = url {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int {
                print("[AudioRecorder] Final file size: \(size) bytes (\(String(format: "%.2f", Double(size)/1_048_576)) MB)")
            }
        }
        recorder = nil
        delegate = nil
        isRecording = false
        isPaused = false
        recordingStopped = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return url
    }

    /// Full state reset. Stops any active recording without returning the URL.
    func reset() {
        print("[AudioRecorder] RESET")
        stopTimers()
        recorder?.stop()
        recorder = nil
        delegate = nil
        isRecording = false
        isPaused = false
        recordingStopped = false
        elapsed = 0
        metering = -160
        accumulated = 0
        startTime = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Interruption handling (phone calls, Siri, alarms)
    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            print("[AudioRecorder] INTERRUPTION BEGAN — recorder auto-paused")
            if isRecording && !isPaused {
                if let s = startTime { accumulated += Date().timeIntervalSince(s) }
                isPaused = true
                stopTimers()
            }
        case .ended:
            print("[AudioRecorder] INTERRUPTION ENDED")
            guard let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) && isRecording {
                do {
                    try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
                    let ok = recorder?.record() ?? false
                    print("[AudioRecorder] Post-interruption resume: \(ok)")
                    if ok {
                        startTime = Date()
                        isPaused = false
                        startTimers()
                    } else {
                        markDead()
                    }
                } catch {
                    print("[AudioRecorder] Failed to reactivate session: \(error.localizedDescription)")
                    markDead()
                }
            }
        @unknown default:
            break
        }
    }

    // MARK: - Route change (headphones, bluetooth)
    private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs.map { $0.portName }.joined(separator: ",")
        print("[AudioRecorder] Route change reason=\(reason.rawValue), inputs=\(inputs)")
    }

    // MARK: - Helpers
    private func markDead() {
        stopTimers()
        recordingStopped = true
        // Keep isRecording = true so the doctor sees "Recording stopped" over the (now-stale) timer
    }

    private func logLifecycle(_ event: String) {
        let actual = recorder?.isRecording ?? false
        print("[AudioRecorder] \(event) — uiState isRecording=\(isRecording) isPaused=\(isPaused) elapsed=\(elapsed)s recorder.isRecording=\(actual)")
    }

    private func startTimers() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let s = self.startTime else { return }
                self.elapsed = Int(self.accumulated + Date().timeIntervalSince(s))
                // Sanity check: if we think we're recording but the recorder isn't, surface it
                if self.isRecording && !self.isPaused, let r = self.recorder, !r.isRecording {
                    print("[AudioRecorder] Silent death detected at \(self.elapsed)s")
                    self.markDead()
                }
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

// MARK: - Delegate bridge (AVAudioRecorderDelegate requires NSObject)
private final class RecorderDelegate: NSObject, AVAudioRecorderDelegate {
    let onFinish: () -> Void
    let onError: (Error?) -> Void
    init(onFinish: @escaping () -> Void, encodeError: @escaping (Error?) -> Void) {
        self.onFinish = onFinish
        self.onError = encodeError
    }
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag { onFinish() }
    }
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        onError(error)
    }
}
