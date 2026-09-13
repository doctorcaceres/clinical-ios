import SwiftUI

struct RecordingView: View {
    @EnvironmentObject var app: AppState
    // SINGLETON — lives at app level, survives view recycles and backgrounding
    @ObservedObject private var rec = AudioRecorder.shared
    @State private var stopFailed = false
    let type: String

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ClinicalTitle().padding(.bottom, 32)

            // Badge
            badge
                .padding(.bottom, 28)

            recordingContent

            // Chat button for training mode (only when not recording)
            if type == "training" && !rec.isRecording {
                Button { app.push(.trainingChat) } label: {
                    Text("Chat")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: 0x888888))
                }
                .buttonStyle(PressStyle())
                .padding(.top, 16)
            }

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.bg.ignoresSafeArea())
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            // Only reset if we're entering fresh (not resuming an active recording)
            if !rec.isRecording { rec.reset() }
        }
        // Do NOT call rec.reset() on disappear — that would kill background recording.
        // Stop / Back buttons explicitly clean up.
    }

    // MARK: - Badge
    private var badge: some View {
        Text(badgeText)
            .font(.system(size: 11, weight: .medium))
            .tracking(1)
            .textCase(.uppercase)
            .foregroundColor(type == "training" ? C.warning : C.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(type == "training" ? C.warningBg : C.accentBg)
            .cornerRadius(12)
    }

    private var badgeText: String {
        switch type {
        case "training": return "Training"
        case "new": return "New Patient"
        default: return "Follow Up"
        }
    }

    // MARK: - Recording interface
    private var recordingContent: some View {
        VStack(spacing: 0) {
            // Timer
            Text(formatElapsed(rec.elapsed))
                .font(.system(size: 52, weight: .ultraLight))
                .monospacedDigit()
                .foregroundColor(rec.recordingStopped ? C.error : C.text)
                .opacity(rec.isPaused ? 0.5 : 1.0)
                .padding(.bottom, 8)

            // Status
            if rec.recordingStopped {
                // Recording died — UI must show this plainly
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(C.error)
                            .font(.system(size: 13))
                        Text("Recording stopped")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(C.error)
                    }
                    Text("The system interrupted recording. Tap stop to save what was captured.")
                        .font(.system(size: 12))
                        .foregroundColor(C.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(C.errorBg)
                .cornerRadius(12)
                .padding(.bottom, 24)
            } else if rec.interruptionPause {
                // Call/Siri took the mic — auto-resumes when it ends
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "phone.fill")
                            .foregroundColor(C.warning)
                            .font(.system(size: 13))
                        Text("Paused — call in progress")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(C.warning)
                    }
                    Text("Recording will resume automatically when the call ends. Nothing recorded so far is lost.")
                        .font(.system(size: 12))
                        .foregroundColor(C.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(C.warningBg)
                .cornerRadius(12)
                .padding(.bottom, 24)
            } else if rec.isRecording && !rec.isPaused {
                if rec.resumedBanner {
                    Text("Recording resumed")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(C.accent)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 16)
                        .background(C.accentBg)
                        .cornerRadius(10)
                        .padding(.bottom, 10)
                        .transition(.opacity)
                }
                HStack(spacing: 6) {
                    Circle().fill(C.error).frame(width: 8, height: 8)
                    Text("Recording...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(C.accent)
                }
                .padding(.bottom, 16)

                WaveformView(metering: rec.metering)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            } else if rec.isPaused {
                Text("PAUSED")
                    .font(.system(size: 13))
                    .tracking(2)
                    .foregroundColor(C.textDim)
                    .padding(.bottom, 40)
            } else {
                Spacer().frame(height: 64)
            }

            // Controls
            if !rec.isRecording {
                VStack(spacing: 12) {
                    RecordButton(isRecording: false) {
                        Task { try? await rec.start() }
                    }
                    Text(type == "training" ? "Dictate your style preferences" : "Tap to start recording")
                        .font(.system(size: 13))
                        .foregroundColor(C.textDim)
                    backButton.padding(.top, 8)
                }
            } else {
                HStack(spacing: 32) {
                    // Pause / Resume (disabled if recording is dead)
                    Button {
                        rec.isPaused ? rec.resume() : rec.pause()
                    } label: {
                        ZStack {
                            Circle().fill(Color(hex: 0x222222)).frame(width: 56, height: 56)
                            Image(systemName: rec.isPaused ? "play.fill" : "pause.fill")
                                .foregroundColor(C.text)
                                .font(.system(size: 18))
                        }
                    }
                    .buttonStyle(PressStyle())
                    .disabled(rec.recordingStopped)
                    .opacity(rec.recordingStopped ? 0.4 : 1.0)

                    // Stop
                    Button { handleStop() } label: {
                        ZStack {
                            Circle().fill(C.error).frame(width: 80, height: 80)
                            if rec.isFinalizing {
                                ProgressView().tint(.white)
                            } else {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.white.opacity(0.9))
                                    .frame(width: 22, height: 22)
                            }
                        }
                    }
                    .buttonStyle(PressStyle())
                    .disabled(rec.isFinalizing)
                }

                Text(statusHint)
                    .font(.system(size: 13))
                    .foregroundColor(rec.recordingStopped || stopFailed ? C.error : C.textDim)
                    .padding(.top, 12)
            }
        }
    }

    private var statusHint: String {
        if stopFailed { return "Could not save the recording — audio segments are kept on this phone" }
        if rec.isFinalizing { return "Finalizing recording..." }
        if rec.recordingStopped { return "Tap stop to save what was captured" }
        if rec.interruptionPause { return "Tap play to retry, or stop to save what you have" }
        if rec.isPaused { return "Resume or stop recording" }
        return type == "training" ? "Listening..." : "Recording encounter"
    }

    private func handleStop() {
        guard !rec.isFinalizing else { return }
        stopFailed = false
        let elapsed = rec.elapsed
        Task {
            guard let url = await rec.stop() else {
                // Merge failed or nothing captured — segments stay on disk
                stopFailed = true
                return
            }
            if type == "training" {
                app.push(.trainingProcessing(TrainingParams(
                    audioURL: url,
                    elapsed: elapsed
                )))
            } else {
                // Start upload + transcription IMMEDIATELY in the background —
                // it runs while the doctor is on the Instructions screen, so
                // dictating instructions hides the transcription wait entirely.
                app.startBackgroundTranscription(audioURL: url, durationSeconds: elapsed)
                app.push(.instructions(ProcessParams(
                    encounterType: type,
                    audioURL: url,
                    elapsed: elapsed,
                    instructions: nil
                )))
            }
        }
    }

    private var backButton: some View {
        Button {
            rec.reset()  // clean up if user bails before starting
            app.home()
        } label: {
            Text("Back")
                .font(.system(size: 14))
                .foregroundColor(C.textDim)
        }
        .buttonStyle(PressStyle())
    }
}
