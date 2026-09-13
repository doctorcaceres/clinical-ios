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
    @State private var streamBuffer = ""
    @State private var streamedSections: [StreamedSection] = []

    enum Stage { case uploading, transcribing, generating, done, error }

    struct StreamedSection: Identifiable, Equatable {
        let id: String        // section title
        var text: String
        var complete: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            if stage == .generating && !streamedSections.isEmpty {
                liveNoteView
            } else {
                classicStatusView
            }

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

                if stage != .done && stage != .generating {
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
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.bg.ignoresSafeArea())
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .onAppear {
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

    // MARK: - Classic centered status (upload / transcribe / error / done)
    private var classicStatusView: some View {
        VStack(spacing: 0) {
            Spacer()
            ClinicalTitle().padding(.bottom, 40)

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
            .padding(.bottom, 16)

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
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Live streaming note
    private var liveNoteView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ProgressView().tint(C.accent).scaleEffect(0.7)
                Text("Writing your note...")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(C.accent)
            }
            .padding(.top, 24)
            .padding(.bottom, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(streamedSections) { section in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(section.id.uppercased())
                                    .font(.system(size: 11, weight: .semibold))
                                    .tracking(1)
                                    .foregroundColor(C.accent)
                                Text(section.text + (section.complete ? "" : " ▍"))
                                    .font(.system(size: 14))
                                    .foregroundColor(C.textSec)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(section.id)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
                .onChange(of: streamedSections) { sections in
                    if let last = sections.last {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }

    private var stageMessage: String {
        switch stage {
        case .uploading:    return "Uploading audio..."
        case .transcribing: return "Transcribing..."
        case .generating:   return "Writing your note..."
        case .done:         return "Done. Opening your note..."
        case .error:        return "Upload failed.\n\(errorMsg)"
        }
    }

    private func process() async {
        attempts += 1
        errorMsg = ""

        do {
            // 1+2. Transcript: prefer the background task started at Stop —
            // it has been uploading/transcribing while the doctor was on the
            // Instructions screen. Fall back to our own pipeline on retry.
            let transcript: String
            if let cached = transcriptCached {
                print("[ProcessingView] Using cached transcript (\(cached.count) chars)")
                transcript = cached
            } else if params.audioURL.path == "/dev/null" {
                transcript = demoTranscript
                transcriptCached = transcript
            } else if let bg = app.takeBackgroundTranscription(for: params.audioURL) {
                stage = .transcribing
                do {
                    transcript = try await bg.value
                    transcriptCached = transcript
                    print("[ProcessingView] Background transcription ready (\(transcript.count) chars)")
                } catch {
                    print("[ProcessingView] Background transcription failed (\(error.localizedDescription)) — running own pipeline")
                    transcript = try await ownTranscription()
                }
            } else {
                transcript = try await ownTranscription()
            }

            // 3. Create encounter (first successful pass only; reuse on retry)
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

            // 4. Generate note — STREAMING primary, blocking fallback
            stage = .generating
            streamBuffer = ""
            streamedSections = []
            do {
                try await APIService.generateNoteStream(
                    encounterId: id,
                    encounterType: params.encounterType,
                    userId: app.userId
                ) { delta in
                    streamBuffer += delta
                    streamedSections = Self.parsePartialNoteJSON(streamBuffer)
                }
            } catch {
                print("[ProcessingView] Stream failed (\(error.localizedDescription)) — falling back to blocking generation")
                streamedSections = []
                try await APIService.generateNote(
                    encounterId: id,
                    encounterType: params.encounterType,
                    userId: app.userId
                )
            }

            // 5. Note saved end-to-end — clean up audio, open the note.
            cleanupAudio()
            stage = .done
            app.pendingNoteId = nil

            if let enc = try? await DB.shared.encounter(id: id), enc.hasNote {
                app.path = NavigationPath([Route.noteReview(enc)])
            } else {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                app.home()
            }

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

    /// Own upload + transcribe pipeline (retry path, or when no background task exists).
    private func ownTranscription() async throws -> String {
        if uploadedAudioURL == nil {
            stage = .uploading
            uploadedAudioURL = try await APIService.uploadAudioToStorage(fileURL: params.audioURL)
        }
        stage = .transcribing
        guard let audioURL = uploadedAudioURL else {
            throw ClinicalError.server("Upload URL missing — cannot transcribe")
        }
        let t = try await APIService.transcribeFromURL(audioURL, durationSeconds: params.elapsed)
        transcriptCached = t
        return t
    }

    // MARK: - Incremental JSON section parser
    /// Extracts ("Section Title", partial-or-complete text) pairs from a
    /// partial JSON object stream like {"Chief Concern": "...", "HPI": "...
    /// Tolerates a leading code fence or preamble before the first brace.
    static func parsePartialNoteJSON(_ raw: String) -> [StreamedSection] {
        var s = raw
        if let braceIdx = s.firstIndex(of: "{") {
            s = String(s[braceIdx...])
        } else {
            return []
        }

        var result: [StreamedSection] = []
        let chars = Array(s)
        var i = 1  // skip opening brace

        func skipFiller() {
            while i < chars.count, " \n\r\t,}".contains(chars[i]) { i += 1 }
        }
        func parseString() -> (value: String, closed: Bool) {
            var out = ""
            while i < chars.count {
                let c = chars[i]
                if c == "\\", i + 1 < chars.count {
                    let n = chars[i + 1]
                    switch n {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": break
                    default: out.append(n)   // \" \\ \/ etc.
                    }
                    i += 2
                    continue
                }
                if c == "\"" { i += 1; return (out, true) }
                out.append(c)
                i += 1
            }
            return (out, false)
        }

        while true {
            skipFiller()
            guard i < chars.count, chars[i] == "\"" else { break }
            i += 1
            let key = parseString()
            guard key.closed else { break }              // key still streaming — ignore until complete
            skipFiller()
            guard i < chars.count, chars[i] == ":" else {
                result.append(StreamedSection(id: key.value, text: "", complete: false))
                break
            }
            i += 1
            skipFiller()
            guard i < chars.count, chars[i] == "\"" else {
                result.append(StreamedSection(id: key.value, text: "", complete: false))
                break
            }
            i += 1
            let val = parseString()
            result.append(StreamedSection(id: key.value, text: val.value, complete: val.closed))
            if !val.closed { break }
        }
        return result
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
