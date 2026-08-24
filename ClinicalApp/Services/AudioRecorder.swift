import AVFoundation
import Combine
import UIKit

/// Singleton segmented recorder. An encounter is an ordered list of segment
/// files (encounter_<id>_seg1.m4a, _seg2.m4a, ...). A phone call, Siri, or a
/// route loss finalizes the current segment; recording resumes into a NEW
/// segment when the interruption ends. On stop, all segments are merged into
/// one encounter_<id>.m4a via AVMutableComposition, so everything downstream
/// (upload, transcription) sees a single file exactly as before.
@MainActor
final class AudioRecorder: ObservableObject {
    static let shared = AudioRecorder()

    // MARK: - Published state (drives UI)
    @Published var isRecording = false          // encounter in progress (spans segments)
    @Published var isPaused = false             // paused (manual OR interruption)
    @Published var interruptionPause = false    // paused specifically by call/Siri/route loss
    @Published var resumedBanner = false        // transient "Recording resumed"
    @Published var isFinalizing = false         // merging segments after stop
    @Published var elapsed: Int = 0
    @Published var metering: Float = -160
    @Published var recordingStopped = false     // unrecoverable death — UI must show it

    // MARK: - Private
    private var recorder: AVAudioRecorder?
    private var delegate: RecorderDelegate?
    private var timer: Timer?
    private var meterTimer: Timer?
    private var startTime: Date?
    private var accumulated: TimeInterval = 0
    private var encounterId = ""
    private(set) var segmentURLs: [URL] = []
    private var segmentIndex = 0
    private var autoRecoveries = 0
    private let maxAutoRecoveries = 5
    // True when the doctor had deliberately paused before a call arrived —
    // in that case the end of the call must restore the pause, not resume audio.
    private var wasManuallyPausedBeforeInterruption = false

    var fileURL: URL? { recorder?.url }

    private var docsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

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
                print("[AudioRecorder] MEDIA SERVICES RESET — attempting segment recovery")
                self?.attemptAutoRecovery(reason: "media services reset")
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
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.logLifecycle("ACTIVE")
                // Fallback resume: some interruptions never deliver .ended.
                // If we're interruption-paused and the app is active again, try.
                if self.isRecording && self.interruptionPause {
                    print("[AudioRecorder] didBecomeActive during interruption pause — trying resume")
                    self.attemptInterruptionResume()
                }
                // Verify recorder is still alive after plain backgrounding
                if self.isRecording && !self.isPaused && self.recorder?.isRecording == false {
                    self.attemptAutoRecovery(reason: "died while backgrounded")
                }
            }
        }
    }

    // MARK: - Start (new encounter)
    func start() async throws {
        print("[AudioRecorder] START requested")
        try activateSession()

        encounterId = UUID().uuidString
        segmentURLs = []
        segmentIndex = 0
        accumulated = 0
        elapsed = 0
        autoRecoveries = 0
        recordingStopped = false
        interruptionPause = false
        resumedBanner = false
        wasManuallyPausedBeforeInterruption = false

        try startNewSegment()

        isRecording = true
        isPaused = false
    }

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.defaultToSpeaker, .allowBluetooth]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        print("[AudioRecorder] Session active — route: \(session.currentRoute.inputs.map { $0.portName }.joined(separator: ","))")
    }

    /// Create and start the next segment file: encounter_<id>_seg<N>.m4a
    private func startNewSegment() throws {
        segmentIndex += 1
        let url = docsDir.appendingPathComponent("encounter_\(encounterId)_seg\(segmentIndex).m4a")

        // Speech-optimized: 16 kHz mono AAC at 32 kbps (~4 MB/hour)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        let r = try AVAudioRecorder(url: url, settings: settings)
        let del = RecorderDelegate { [weak self] in
            Task { @MainActor in self?.attemptAutoRecovery(reason: "delegate finished unsuccessfully") }
        } encodeError: { [weak self] err in
            Task { @MainActor in
                print("[AudioRecorder] Encode error: \(err?.localizedDescription ?? "nil")")
                self?.attemptAutoRecovery(reason: "encode error")
            }
        }
        r.delegate = del
        r.isMeteringEnabled = true
        guard r.record() else {
            throw NSError(domain: "AudioRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to start recording segment \(segmentIndex)"])
        }

        recorder = r
        delegate = del
        segmentURLs.append(url)
        startTime = Date()
        startTimers()
        print("[AudioRecorder] Segment \(segmentIndex) started: \(url.lastPathComponent)")
    }

    /// Cleanly stop the active recorder and bank its elapsed time.
    /// The segment file is finalized on disk and stays in segmentURLs.
    private func finalizeCurrentSegment() {
        stopTimers()
        if !isPaused, let s = startTime {
            accumulated += Date().timeIntervalSince(s)
        }
        startTime = nil
        recorder?.stop()      // finalizes the file header — safe, delegate fires with success
        recorder = nil
        delegate = nil
        if let last = segmentURLs.last,
           let attrs = try? FileManager.default.attributesOfItem(atPath: last.path),
           let size = attrs[.size] as? Int {
            print("[AudioRecorder] Segment \(segmentIndex) finalized: \(size) bytes")
        }
    }

    // MARK: - Manual pause / resume
    func pause() {
        guard !interruptionPause else { return }
        print("[AudioRecorder] Manual PAUSE at \(elapsed)s")
        if let s = startTime { accumulated += Date().timeIntervalSince(s) }
        startTime = nil
        recorder?.pause()
        isPaused = true
        stopTimers()
    }

    func resume() {
        if interruptionPause {
            // Manual retry while interruption-paused (e.g. user taps play mid-call)
            attemptInterruptionResume()
            return
        }
        print("[AudioRecorder] Manual RESUME at \(elapsed)s")
        if recorder == nil {
            // Segment was finalized while paused (call arrived mid-pause, or
            // recovery) — continue into a fresh segment.
            do {
                try activateSession()
                try startNewSegment()
                isPaused = false
            } catch {
                print("[AudioRecorder] Resume into new segment failed: \(error.localizedDescription)")
                markDead()
            }
            return
        }
        let ok = recorder?.record() ?? false
        if ok {
            startTime = Date()
            isPaused = false
            startTimers()
        } else {
            // Paused recorder died underneath us — recover into a new segment
            isPaused = false
            attemptAutoRecovery(reason: "manual resume failed")
        }
    }

    // MARK: - Interruption handling (phone calls, Siri, alarms)
    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            guard isRecording, !interruptionPause else { return }
            print("[AudioRecorder] INTERRUPTION BEGAN at \(elapsed)s — finalizing segment \(segmentIndex)")
            wasManuallyPausedBeforeInterruption = isPaused
            finalizeCurrentSegment()
            isPaused = true
            interruptionPause = true

        case .ended:
            print("[AudioRecorder] INTERRUPTION ENDED")
            guard isRecording, interruptionPause else { return }
            let optionsValue = (info[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                attemptInterruptionResume()
            } else {
                // No shouldResume hint — the didBecomeActive fallback will retry
                print("[AudioRecorder] No shouldResume option — waiting for app active")
            }

        @unknown default:
            break
        }
    }

    /// Reactivate the session and continue into a NEW segment file.
    /// Safe to call repeatedly — fails quietly while the call is still active,
    /// and the didBecomeActive fallback or a manual tap will retry.
    private func attemptInterruptionResume() {
        guard isRecording, interruptionPause else { return }
        if wasManuallyPausedBeforeInterruption {
            // The doctor had paused deliberately before the call — restore the
            // manual pause instead of resuming audio without consent. Their next
            // tap on play continues into a new segment (resume() handles nil recorder).
            interruptionPause = false
            wasManuallyPausedBeforeInterruption = false
            print("[AudioRecorder] Interruption over — restoring manual pause (no auto-resume)")
            return
        }
        do {
            try activateSession()
            try startNewSegment()
            isPaused = false
            interruptionPause = false
            showResumedBanner()
            print("[AudioRecorder] Resumed after interruption — now on segment \(segmentIndex)")
        } catch {
            print("[AudioRecorder] Resume attempt failed (will retry): \(error.localizedDescription)")
        }
    }

    private func showResumedBanner() {
        resumedBanner = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.resumedBanner = false
        }
    }

    // MARK: - Route change (AirPods/Bluetooth disconnect)
    private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs.map { $0.portName }.joined(separator: ",")
        print("[AudioRecorder] Route change reason=\(reason.rawValue), inputs now: \(inputs)")

        // AirPods died / Bluetooth dropped: iOS usually reroutes to the built-in
        // mic automatically. Verify shortly after; if the recorder stalled,
        // recover into a new segment on the built-in mic.
        if reason == .oldDeviceUnavailable, isRecording, !isPaused {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.isRecording, !self.isPaused else { return }
                if self.recorder?.isRecording != true {
                    self.attemptAutoRecovery(reason: "route lost (\(inputs.isEmpty ? "no input" : inputs))")
                }
            }
        }
    }

    // MARK: - Auto-recovery (silent death, encode error, route loss)
    private func attemptAutoRecovery(reason: String) {
        guard isRecording, !isPaused, !recordingStopped, !isFinalizing else { return }
        guard autoRecoveries < maxAutoRecoveries else {
            print("[AudioRecorder] Auto-recovery limit reached — marking stopped")
            markDead()
            return
        }
        autoRecoveries += 1
        print("[AudioRecorder] AUTO-RECOVERY \(autoRecoveries)/\(maxAutoRecoveries) (\(reason)) — new segment")
        finalizeCurrentSegment()
        do {
            try activateSession()
            try startNewSegment()
            isPaused = false
        } catch {
            print("[AudioRecorder] Auto-recovery failed: \(error.localizedDescription)")
            markDead()
        }
    }

    // MARK: - Stop: finalize + merge all segments into one file
    /// Returns the URL of the single merged encounter_<id>.m4a, or nil if
    /// nothing usable was captured. Segment files are deleted only after a
    /// successful merge; on failure they remain on disk for recovery.
    func stop() async -> URL? {
        guard isRecording, !isFinalizing else { return nil }
        print("[AudioRecorder] STOP at \(elapsed)s — \(segmentURLs.count) segment(s)")
        finalizeCurrentSegment()

        isFinalizing = true
        let merged = await mergeSegments()
        isFinalizing = false

        isRecording = false
        isPaused = false
        interruptionPause = false
        recordingStopped = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        if let merged = merged,
           let attrs = try? FileManager.default.attributesOfItem(atPath: merged.path),
           let size = attrs[.size] as? Int {
            print("[AudioRecorder] Merged file: \(merged.lastPathComponent), \(size) bytes (\(String(format: "%.2f", Double(size)/1_048_576)) MB)")
        } else if merged == nil {
            print("[AudioRecorder] MERGE FAILED — segments preserved on disk: \(segmentURLs.map { $0.lastPathComponent })")
        }
        return merged
    }

    /// Merge ordered segments into encounter_<id>.m4a.
    /// Single segment: plain file move (lossless, instant).
    /// Multiple: AVMutableComposition + AVAssetExportSession (AppleM4A).
    private func mergeSegments() async -> URL? {
        // Drop empty/failed segment files (e.g. a segment killed before any audio)
        let valid = segmentURLs.filter { url in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int else { return false }
            return size > 1024   // < 1 KB = header only, no audio
        }
        guard !valid.isEmpty else { return nil }

        let finalURL = docsDir.appendingPathComponent("encounter_\(encounterId).m4a")
        try? FileManager.default.removeItem(at: finalURL)

        // Header-only files (< 1 KB) contain no audio — safe to remove now
        let empties = segmentURLs.filter { !valid.contains($0) }
        for url in empties { try? FileManager.default.removeItem(at: url) }

        // Fast path: one segment — no re-encode needed
        if valid.count == 1 {
            do {
                try FileManager.default.moveItem(at: valid[0], to: finalURL)
                return finalURL
            } catch {
                print("[AudioRecorder] Single-segment move failed: \(error.localizedDescription)")
                return nil
            }
        }

        // Multi-segment: stitch with AVMutableComposition
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return nil
        }

        var cursor = CMTime.zero
        var insertedURLs: [URL] = []
        for url in valid {
            let asset = AVURLAsset(url: url)
            do {
                let duration = try await asset.load(.duration)
                guard duration.seconds > 0.05,
                      let aTrack = try await asset.loadTracks(withMediaType: .audio).first else {
                    print("[AudioRecorder] Skipping unusable segment (kept on disk): \(url.lastPathComponent)")
                    continue
                }
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: aTrack, at: cursor)
                cursor = CMTimeAdd(cursor, duration)
                insertedURLs.append(url)
            } catch {
                print("[AudioRecorder] Skipping segment \(url.lastPathComponent) (kept on disk): \(error.localizedDescription)")
            }
        }
        guard !insertedURLs.isEmpty else { return nil }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            return nil
        }
        export.outputURL = finalURL
        export.outputFileType = .m4a

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }

        guard export.status == .completed else {
            print("[AudioRecorder] Export failed: \(export.error?.localizedDescription ?? "status \(export.status.rawValue)")")
            return nil
        }

        print("[AudioRecorder] Merged \(insertedURLs.count) segments, total \(String(format: "%.1f", cursor.seconds))s")
        // Delete ONLY the segments that made it into the merge. A corrupt-but-
        // nonempty segment that was skipped stays on disk for manual recovery.
        for url in insertedURLs { try? FileManager.default.removeItem(at: url) }
        return finalURL
    }

    /// Full state reset. Stops any active recording WITHOUT merging.
    /// Segment files are left on disk (recovery philosophy — never silently
    /// destroy audio; orphans can be cleaned up after successful encounters).
    func reset() {
        print("[AudioRecorder] RESET")
        stopTimers()
        recorder?.stop()
        recorder = nil
        delegate = nil
        isRecording = false
        isPaused = false
        interruptionPause = false
        resumedBanner = false
        isFinalizing = false
        recordingStopped = false
        wasManuallyPausedBeforeInterruption = false
        elapsed = 0
        metering = -160
        accumulated = 0
        startTime = nil
        segmentURLs = []
        segmentIndex = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Helpers
    private func markDead() {
        stopTimers()
        recordingStopped = true
        // Keep isRecording = true so the doctor sees the error state and can
        // tap stop to salvage every finalized segment.
    }

    private func logLifecycle(_ event: String) {
        let actual = recorder?.isRecording ?? false
        print("[AudioRecorder] \(event) — isRecording=\(isRecording) isPaused=\(isPaused) interruption=\(interruptionPause) seg=\(segmentIndex) elapsed=\(elapsed)s recorder.isRecording=\(actual)")
    }

    private func startTimers() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let s = self.startTime else { return }
                self.elapsed = Int(self.accumulated + Date().timeIntervalSince(s))
                // Sanity: recorder thinks it stopped but we think we're recording
                if self.isRecording && !self.isPaused, let r = self.recorder, !r.isRecording {
                    print("[AudioRecorder] Silent death detected at \(self.elapsed)s")
                    self.attemptAutoRecovery(reason: "silent death")
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
