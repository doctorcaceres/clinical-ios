import SwiftUI

struct ProcessingView: View {
    @EnvironmentObject var app: AppState
    let params: ProcessParams

    @State private var stage: Stage = .uploading
    @State private var errorMsg = ""
    @State private var encounterId: String?
    @State private var uploadedAudioURL: String?
    @State private var transcriptCached: String?
    @State private var attempts: Int = 0
    @State private var hasStarted = false
    @State private var fileSizeMB: Double = 0

    enum Stage { case uploading, transcribing, generating, done, error }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ClinicalTitle().padding(.bottom, 40)

            statusIcon.padding(.bottom, 16)

            Text(stageMessage)
                .font(.system(size: 16))
                .foregroundColor(stage == .error ? C.error : C.textSec)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .padding(.horizontal, 16)

            if stage == .uploading || stage == .transcribing {
                Text(String(format: "%.2f MB audio", fileSizeMB))
                    .font(.system(size: 12))
                    .foregroundColor(C.textDark)
                    .padding(.top, 8)
            }

            if stage == .error {
                VStack(spacing: 6) {
                    Text("Recording is saved on this phone.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(C.accent)
                        .padding(.top, 16)
                    Text(String(format: "%.2f MB", fileSizeMB))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(C.text)
                    Text(params.audioURL.lastPathComponent)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(C.textDim)
                        .padding(.horizontal, 24)
                        .multilineTextAlignment(.center)
                    if attempts > 1 {
                        Text("Attempts: \(attempts)")
                            .font(.system(size: 11))
                            .foregroundColor(C.textMuted)
                    }
                }
            }

            Spacer()

            // Action buttons
            VStack(spacing: 10) {
                if stage == .error {
                    Button {
                        Task { await process() }
                    } label: {
                        Text("Tap to retry")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(C.bg)
                            .frame(maxWidth: 300)
                            .padding(.vertical, 14)
                            .background(C.accent)
                            .cornerRadius(12)
                    }
                    .buttonStyle(PressStyle())
                }

                if stage != .done {
                    Button {
                        if let id = encounterId { app.pendingNoteId = id }
                        app.home()
                    } label: {
                        Text(stage == .error ? "Save for later" : "Next Patient")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(C.text)
                            .frame(maxWidth: 300)
                            .padding(.vertical, 14)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.borderPri, lineWidth: 2))
                    }
                    .buttonStyle(PressStyle())
                }
            }
            .padding(.bottom, 40)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.bg.ignoresSafeArea())
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            // Read file size up front so it's displayable on error
            if params.audioURL.path != "/dev/null",
               let attrs = try? FileManager.default.attributesOfItem(atPath: params.audioURL.path),
               let size = attrs[.size] as? Int {
                fileSizeMB = Double(size) / 1_048_576
            }
        }
        .task {
            if !hasStarted {
                hasStarted = true
                await process()
            }
        }
    }

    private var statusIcon: some View {
        Group {
            if stage == .done {
                Circle().fill(C.accent).frame(width: 12, height: 12)
            } else if stage == .error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(C.error)
            } else {
                ProgressView().tint(C.accent).scaleEffect(0.8)
            }
        }
    }

    private var stageMessage: String {
        switch stage {
        case .uploading:    return "Uploading audio..."
        case .transcribing: return "Transcribing..."
        case .generating:   return "Writing your note..."
        case .done:         return "Done. Check Recent Notes."
        case .error:        return "Upload failed.\n\(errorMsg)"
        }
    }

    private func process() async {
        attempts += 1
        errorMsg = ""

        do {
            // 1. Upload to Supabase Storage — skip if already uploaded on a prior attempt
            if uploadedAudioURL == nil && params.audioURL.path != "/dev/null" {
                stage = .uploading
                uploadedAudioURL = try await APIService.uploadAudioToStorage(fileURL: params.audioURL)
            }

            // 2. Transcribe — skip if we already have a transcript cached
            let transcript: String
            if let cached = transcriptCached {
                print("[ProcessingView] Using cached transcript (\(cached.count) chars)")
                transcript = cached
            } else if params.audioURL.path == "/dev/null" {
                transcript = demoTranscript
                transcriptCached = transcript
            } else {
                stage = .transcribing
                guard let audioURL = uploadedAudioURL else {
                    throw ClinicalError.server("Upload URL missing — cannot transcribe")
                }
                transcript = try await APIService.transcribeFromURL(audioURL, durationSeconds: params.elapsed)
                transcriptCached = transcript
            }

            // 3. Create encounter (only on first successful pass; reuse on retry)
            stage = .generating
            let id: String
            if let existing = encounterId {
                id = existing
            } else {
                id = try await DB.shared.createEncounter(type: params.encounterType)
                encounterId = id
                var fields: [String: Any] = [
                    "transcript": transcript,
                    "elapsed": params.elapsed,
                    "status": "processing",
                ]
                if let inst = params.instructions { fields["doctor_instructions"] = inst }
                try await DB.shared.update(id: id, fields: fields)
            }

            // 4. Generate note
            try await APIService.generateNote(
                encounterId: id,
                encounterType: params.encounterType,
                anthropicKey: app.anthropicKey,
                userId: app.userId
            )

            // 5. Note saved end-to-end. Now safe to delete both the local file
            //    and the Supabase Storage copy.
            cleanupAudio()

            stage = .done
            app.pendingNoteId = nil
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            app.home()

        } catch let nsError as NSError {
            errorMsg = "\(nsError.localizedDescription) [\(nsError.domain) \(nsError.code)]"
            print("[ProcessingView] FAILED on attempt \(attempts): \(errorMsg)")
            stage = .error
        } catch {
            errorMsg = error.localizedDescription
            print("[ProcessingView] FAILED on attempt \(attempts): \(errorMsg)")
            stage = .error
        }
    }

    private func cleanupAudio() {
        let url = params.audioURL
        if url.path == "/dev/null" { return }

        // Local file only. The Storage copy was already deleted server-side
        // immediately after Deepgram returned the transcript (zero retention).
        do {
            try FileManager.default.removeItem(at: url)
            print("[ProcessingView] Deleted local audio: \(url.lastPathComponent)")
        } catch {
            print("[ProcessingView] Could not delete local audio (non-fatal): \(error.localizedDescription)")
        }
    }

    private var demoTranscript: String {
        "Speaker 0: Good morning. Why are you being referred to neurology?\nSpeaker 1: His pediatrician referred us because of episodes that look like seizures.\nSpeaker 0: Tell me about them.\nSpeaker 1: First one three months ago, watching TV, eyes rolled back, arms stiff, shaking for a minute. We called 911. Took him to Sinai, CT normal.\nSpeaker 0: More episodes since?\nSpeaker 1: Three more. Last two started with right hand twitching then spread to whole body.\nSpeaker 0: After episodes how is he?\nSpeaker 1: Confused for 10 minutes then sleeps for an hour.\nSpeaker 0: Born full term?\nSpeaker 1: Yes, 40 weeks, normal delivery.\nSpeaker 0: Development on time?\nSpeaker 1: Yes. Walked at 13 months, talking at 12. Good student, 4th grade, As and Bs at Bellview Elementary.\nSpeaker 0: Family history of seizures?\nSpeaker 1: My brother had seizures as a teenager. My mom had some when young.\nSpeaker 0: Medications?\nSpeaker 1: None.\nSpeaker 0: Who does he live with?\nSpeaker 1: Me, dad, and older sister.\nSpeaker 0: Let me examine him. Exam is normal, neurological exam non-focal.\nSpeaker 0: So let me tell you what I think. Four seizures in three months, last two starting on the right side. With family history, this raises concern for genetic epilepsy. I want an EEG, MRI, start Oxcarbazepine, and send genetic testing. Follow up in 6 weeks."
    }
}
