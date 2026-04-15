import SwiftUI

struct ProcessingView: View {
    @EnvironmentObject var app: AppState
    let params: ProcessParams

    @State private var stage: Stage = .uploading
    @State private var errorMsg = ""
    @State private var encounterId: String?

    enum Stage { case uploading, transcribing, generating, done, error }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ClinicalTitle().padding(.bottom, 40)

            Group {
                if stage == .done {
                    Circle().fill(C.accent).frame(width: 12, height: 12)
                } else if stage == .error {
                    Circle().fill(C.error).frame(width: 12, height: 12)
                } else {
                    ProgressView().tint(C.accent).scaleEffect(0.8)
                }
            }
            .padding(.bottom, 16)

            Text(stageMessage)
                .font(.system(size: 16))
                .foregroundColor(stage == .error ? C.error : C.textSec)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            if stage == .uploading {
                Text("Uploading audio to server...")
                    .font(.system(size: 12))
                    .foregroundColor(C.textDark)
                    .padding(.top, 8)
            }

            Spacer()

            // "Next Patient" — visible immediately (spec requirement)
            if stage != .done {
                Button {
                    if let id = encounterId { app.pendingNoteId = id }
                    app.home()
                } label: {
                    Text("Next Patient")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(C.text)
                        .frame(maxWidth: 300)
                        .padding(.vertical, 14)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.borderPri, lineWidth: 2))
                }
                .buttonStyle(PressStyle())
                .padding(.bottom, 40)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.bg.ignoresSafeArea())
        .navigationBarHidden(true)
        .task { await process() }
    }

    private var stageMessage: String {
        switch stage {
        case .uploading: return "Uploading audio..."
        case .transcribing: return "Transcribing..."
        case .generating: return "Writing your note..."
        case .done: return "Done! Check Recent Notes."
        case .error: return "Error: \(errorMsg)"
        }
    }

    private func process() async {
        do {
            // 1. Transcribe
            stage = .uploading
            let transcript: String
            if params.audioURL.path == "/dev/null" {
                transcript = demoTranscript
            } else {
                transcript = try await APIService.transcribe(fileURL: params.audioURL)
            }

            // 2. Create encounter in Supabase
            stage = .generating
            let type = params.encounterType  // already "new" or "followup"
            let id = try await DB.shared.createEncounter(type: type)
            encounterId = id

            var fields: [String: Any] = [
                "transcript": transcript,
                "elapsed": params.elapsed,
                "status": "processing",
            ]
            if let inst = params.instructions { fields["doctor_instructions"] = inst }
            try await DB.shared.update(id: id, fields: fields)

            // 3. Generate note (separate call — doesn't risk transcription timeout)
            try? await APIService.generateNote(
                encounterId: id,
                encounterType: type,
                anthropicKey: app.anthropicKey
            )

            stage = .done
            app.pendingNoteId = nil

            try? await Task.sleep(nanoseconds: 2_000_000_000)
            app.home()

        } catch let nsError as NSError {
            errorMsg = "\(nsError.localizedDescription)\nDomain: \(nsError.domain) Code: \(nsError.code)"
            stage = .error
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            app.home()
        } catch {
            errorMsg = error.localizedDescription
            stage = .error
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            app.home()
        }
    }

    private var demoTranscript: String {
        "Speaker 0: Good morning. Why are you being referred to neurology?\nSpeaker 1: His pediatrician referred us because of episodes that look like seizures.\nSpeaker 0: Tell me about them.\nSpeaker 1: First one three months ago, watching TV, eyes rolled back, arms stiff, shaking for a minute. We called 911. Took him to Sinai, CT normal.\nSpeaker 0: More episodes since?\nSpeaker 1: Three more. Last two started with right hand twitching then spread to whole body.\nSpeaker 0: After episodes how is he?\nSpeaker 1: Confused for 10 minutes then sleeps for an hour.\nSpeaker 0: Born full term?\nSpeaker 1: Yes, 40 weeks, normal delivery.\nSpeaker 0: Development on time?\nSpeaker 1: Yes. Walked at 13 months, talking at 12. Good student, 4th grade, As and Bs at Bellview Elementary.\nSpeaker 0: Family history of seizures?\nSpeaker 1: My brother had seizures as a teenager. My mom had some when young.\nSpeaker 0: Medications?\nSpeaker 1: None.\nSpeaker 0: Who does he live with?\nSpeaker 1: Me, dad, and older sister.\nSpeaker 0: Let me examine him. Exam is normal, neurological exam non-focal.\nSpeaker 0: So let me tell you what I think. Four seizures in three months, last two starting on the right side. With family history, this raises concern for genetic epilepsy. I want an EEG, MRI, start Oxcarbazepine, and send genetic testing. Follow up in 6 weeks."
    }
}
