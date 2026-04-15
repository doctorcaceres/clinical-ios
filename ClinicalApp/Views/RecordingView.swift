import SwiftUI

struct RecordingView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var rec = AudioRecorder()
    let type: String

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ClinicalTitle().padding(.bottom, 32)

            // Badge
            badge
                .padding(.bottom, 28)

            if type == "training" && !rec.isRecording {
                trainingContent
            } else {
                recordingContent
            }

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.bg.ignoresSafeArea())
        .navigationBarHidden(true)
        .onDisappear { rec.reset() }
    }

    // MARK: - Badge
    private var badge: some View {
        Text(type == "training" ? "Training Mode" : (type == "new" ? "New Patient" : "Follow Up"))
            .font(.system(size: 11, weight: .medium))
            .tracking(1)
            .textCase(.uppercase)
            .foregroundColor(type == "training" ? C.warning : C.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(type == "training" ? C.warningBg : C.accentBg)
            .cornerRadius(12)
    }

    // MARK: - Training mode
    private var trainingContent: some View {
        VStack(spacing: 20) {
            Text("Tap to generate a note from demo data")
                .font(.system(size: 15))
                .foregroundColor(C.textMuted)

            Button {
                app.push(.processing(ProcessParams(
                    encounterType: "new",
                    audioURL: URL(fileURLWithPath: "/dev/null"),
                    elapsed: 0,
                    instructions: nil
                )))
            } label: {
                Text("Generate Demo Note")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(C.bg)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 32)
                    .background(C.warning)
                    .cornerRadius(12)
            }
            .buttonStyle(PressStyle())

            backButton
        }
    }

    // MARK: - Recording interface
    private var recordingContent: some View {
        VStack(spacing: 0) {
            // Timer
            Text(formatElapsed(rec.elapsed))
                .font(.system(size: 52, weight: .ultraLight))
                .monospacedDigit()
                .foregroundColor(C.text)
                .opacity(rec.isPaused ? 0.5 : 1.0)
                .padding(.bottom, 8)

            // Status
            if rec.isRecording && !rec.isPaused {
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
                    Text("Tap to start recording")
                        .font(.system(size: 13))
                        .foregroundColor(C.textDim)
                    backButton.padding(.top, 8)
                }
            } else {
                HStack(spacing: 32) {
                    // Pause / Resume
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

                    // Stop
                    Button {
                        guard let url = rec.stop() else { return }
                        app.push(.processing(ProcessParams(
                            encounterType: type,
                            audioURL: url,
                            elapsed: rec.elapsed,
                            instructions: nil
                        )))
                    } label: {
                        ZStack {
                            Circle().fill(C.error).frame(width: 80, height: 80)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.9))
                                .frame(width: 22, height: 22)
                        }
                    }
                    .buttonStyle(PressStyle())
                }

                Text(rec.isPaused ? "Resume or stop recording" : "Recording encounter")
                    .font(.system(size: 13))
                    .foregroundColor(C.textDim)
                    .padding(.top, 12)
            }
        }
    }

    private var backButton: some View {
        Button { app.home() } label: {
            Text("Back")
                .font(.system(size: 14))
                .foregroundColor(C.textDim)
        }
    }
}
