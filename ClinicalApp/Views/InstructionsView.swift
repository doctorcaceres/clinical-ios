import SwiftUI

/// Post-recording instructions capture. Shown after Stop for clinical
/// encounters. On Generate/Skip the encounter row is created (with
/// doctor_instructions — the same column the web app writes) and the
/// kill-proof BackgroundPipeline takes over; the app returns Home
/// immediately and the note finishes server-side no matter what the
/// phone does.
struct InstructionsView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var rec = AudioRecorder.shared
    let params: ProcessParams

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isTranscribing = false
    @State private var isSubmitting = false
    @State private var submitError = ""
    @State private var pulse = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Back — returns to the recording screen; the audio stays on disk.
            // Screen padding is 32; align the button's leading edge to 16pt.
            HStack {
                BackButton { dismiss() }
                    .disabled(isSubmitting)
                Spacer()
            }
            .padding(.horizontal, -16)

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

            if !submitError.isEmpty {
                Text(submitError)
                    .font(.system(size: 12))
                    .foregroundColor(C.error)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 10)
            }

            VStack(spacing: 10) {
                Button { submit(withInstructions: true) } label: {
                    HStack(spacing: 8) {
                        if isSubmitting { ProgressView().tint(C.bg).scaleEffect(0.8) }
                        Text("Generate Note")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(C.bg)
                    }
                    .frame(maxWidth: 300)
                    .padding(.vertical, 14)
                    .background(C.accent)
                    .cornerRadius(12)
                }
                .buttonStyle(PressStyle())
                .disabled(rec.isRecording || isTranscribing || isSubmitting)
                .opacity(rec.isRecording || isTranscribing || isSubmitting ? 0.5 : 1.0)

                Button { submit(withInstructions: false) } label: {
                    Text("Skip")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(C.textMuted)
                        .frame(maxWidth: 300)
                        .padding(.vertical, 13)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.borderPri, lineWidth: 1))
                }
                .buttonStyle(PressStyle())
                .disabled(rec.isRecording || isTranscribing || isSubmitting)
                .opacity(rec.isRecording || isTranscribing || isSubmitting ? 0.5 : 1.0)
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

    // MARK: - Hand off to the background pipeline and go home
    /// Creates the encounter row (so Recent Notes shows "Processing"
    /// immediately), enqueues the kill-proof background upload + server
    /// pipeline, then returns straight to Home with the banner. The note
    /// finishes even if the phone is locked or the app is gone.
    private func submit(withInstructions: Bool) {
        guard !isSubmitting else { return }
        isSubmitting = true
        submitError = ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = (withInstructions && !trimmed.isEmpty) ? trimmed : nil

        Task {
            do {
                let id = try await DB.shared.createEncounter(type: params.encounterType)
                var fields: [String: Any] = [
                    "elapsed": params.elapsed,
                    "status": "processing",
                ]
                if let inst = instructions { fields["doctor_instructions"] = inst }
                try await DB.shared.update(id: id, fields: fields)

                try await BackgroundPipeline.shared.submit(
                    encounterId: id,
                    encounterType: params.encounterType,
                    userId: app.userId,
                    audioURL: params.audioURL
                )

                app.pendingNoteId = id
                app.home()
            } catch {
                submitError = "Could not start: \(error.localizedDescription). Your recording is safe — try again."
                isSubmitting = false
            }
        }
    }
}
