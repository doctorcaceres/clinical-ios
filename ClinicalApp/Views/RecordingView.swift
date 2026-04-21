import SwiftUI

struct RecordingView: View {
    @EnvironmentObject var app: AppState
    // SINGLETON — lives at app level, survives view recycles and backgrounding
    @ObservedObject private var rec = AudioRecorder.shared
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
            } else if rec.isRecording && !rec.isPaused {
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
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.9))
                                .frame(width: 22, height: 22)
                        }
                    }
                    .buttonStyle(PressStyle())
                }

                Text(statusHint)
                    .font(.system(size: 13))
                    .foregroundColor(rec.recordingStopped ? C.error : C.textDim)
                    .padding(.top, 12)
            }
        }
    }

    private var statusHint: String {
        if rec.recordingStopped { return "Tap stop to save what was captured" }
        if rec.isPaused { return "Resume or stop recording" }
        return type == "training" ? "Listening..." : "Recording encounter"
    }

    private func handleStop() {
        guard let url = rec.stop() else { return }
        if type == "training" {
            app.push(.trainingProcessing(TrainingParams(
                audioURL: url,
                elapsed: rec.elapsed
            )))
        } else {
            app.push(.processing(ProcessParams(
                encounterType: type,
                audioURL: url,
                elapsed: rec.elapsed,
                instructions: nil
            )))
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
    }
}
