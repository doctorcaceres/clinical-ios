import SwiftUI

/// Post-recording instructions capture — parity with the web app's
/// InstructionsScreen. Shown between Stop and Processing for clinical
/// encounters. While the doctor dictates or types here, the main encounter
/// audio is ALREADY uploading + transcribing in the background
/// (AppState.startBackgroundTranscription), so this screen hides that wait.
///
/// Instructions travel in ProcessParams.instructions → the encounters row's
/// doctor_instructions column — the exact field the web app uses — so
/// generate-note and the learning pipeline behave identically.
struct InstructionsView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var rec = AudioRecorder.shared
    let params: ProcessParams

    @State private var text = ""
    @State private var isTranscribing = false
    @State private var pulse = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("RECORDING COMPLETE")
                .font(.system(size: 11, weight: .medium))
                .tracking(1.5)
                .foregroundColor(C.accent)
                .padding(.bottom, 10)

            Text("Instructions for this note (optional)")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(C.text)
                .multilineTextAlignment(.center)
                .padding(.bottom, 6)

            Text("Dictate or type anything the note should include\nthat wasn't said during the visit.")
                .font(.system(size: 13))
                .foregroundColor(C.textMuted)
                .multilineTextAlignment(.center)
                .padding(.bottom, 24)

            // Text field + mic
            HStack(alignment: .bottom, spacing: 10) {
                TextField("e.g. Include the school accommodation letter...", text: $text, axis: .vertical)
                    .font(.system(size: 15))
                    .foregroundColor(C.text)
                    .focused($fieldFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .background(Color(hex: 0x1A1A1A))
                    .cornerRadius(12)
                    .lineLimit(2...8)

                micButton
            }
            .frame(maxWidth: 340)
            .padding(.bottom, 8)

            if rec.isRecording {
                Text("Recording instructions... tap stop when done")
                    .font(.system(size: 12))
                    .foregroundColor(C.error)
            } else if isTranscribing {
                Text("Transcribing your instructions...")
                    .font(.system(size: 12))
                    .foregroundColor(C.textMuted)
            }

            Spacer()

            VStack(spacing: 10) {
                Button { generate() } label: {
                    Text("Generate Note")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(C.bg)
                        .frame(maxWidth: 300)
                        .padding(.vertical, 14)
                        .background(C.accent)
                        .cornerRadius(12)
                }
                .buttonStyle(PressStyle())
                .disabled(rec.isRecording || isTranscribing)
                .opacity(rec.isRecording || isTranscribing ? 0.5 : 1.0)

                Button { skip() } label: {
                    Text("Skip")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(C.textMuted)
                        .frame(maxWidth: 300)
                        .padding(.vertical, 13)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.borderPri, lineWidth: 1))
                }
                .buttonStyle(PressStyle())
                .disabled(rec.isRecording || isTranscribing)
                .opacity(rec.isRecording || isTranscribing ? 0.5 : 1.0)
            }
            .padding(.bottom, 40)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.bg.ignoresSafeArea())
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
    }

    // MARK: - Mic (same pattern as Training Chat dictation)
    private var micButton: some View {
        Button { toggleMic() } label: {
            ZStack {
                if rec.isRecording {
                    Circle()
                        .fill(C.accent.opacity(0.25))
                        .frame(width: 46, height: 46)
                        .scaleEffect(pulse ? 1.3 : 0.85)
                        .opacity(pulse ? 0.3 : 0.7)
                }
                Circle()
                    .fill(rec.isRecording ? C.accent.opacity(0.15) : Color(hex: 0x1A1A1A))
                    .frame(width: 44, height: 44)
                if isTranscribing {
                    ProgressView().tint(C.accent).scaleEffect(0.7)
                } else {
                    Image(systemName: rec.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(C.accent)
                }
            }
            .frame(width: 46, height: 46)
        }
        .buttonStyle(PressStyle())
        .disabled(isTranscribing)
        .onChange(of: rec.isRecording) { recording in
            if recording {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { pulse = false }
            }
        }
    }

    private func toggleMic() {
        if rec.isRecording {
            isTranscribing = true
            Task {
                guard let url = await rec.stop() else {
                    isTranscribing = false
                    return
                }
                do {
                    let raw = try await APIService.transcribe(fileURL: url)
                    let cleaned = stripSpeakerLabels(raw)
                    text = text.isEmpty ? cleaned : text.trimmingCharacters(in: .whitespaces) + " " + cleaned
                } catch {
                    print("[Instructions] Dictation transcribe failed: \(error.localizedDescription)")
                }
                try? FileManager.default.removeItem(at: url)
                isTranscribing = false
            }
        } else {
            fieldFocused = false
            Task { try? await rec.start() }
        }
    }

    // MARK: - Continue to processing
    private func generate() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        app.push(.processing(ProcessParams(
            encounterType: params.encounterType,
            audioURL: params.audioURL,
            elapsed: params.elapsed,
            instructions: trimmed.isEmpty ? nil : trimmed
        )))
    }

    private func skip() {
        app.push(.processing(ProcessParams(
            encounterType: params.encounterType,
            audioURL: params.audioURL,
            elapsed: params.elapsed,
            instructions: nil
        )))
    }
}
