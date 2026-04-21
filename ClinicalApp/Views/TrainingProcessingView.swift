import SwiftUI

/// Handles training mode audio: transcribes → extracts style rules → shows result → goes home.
struct TrainingProcessingView: View {
    @EnvironmentObject var app: AppState
    let params: TrainingParams

    @State private var stage: Stage = .uploading
    @State private var errorMsg = ""
    @State private var ruleCount = 0

    enum Stage { case uploading, transcribing, extracting, done, error }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ClinicalTitle().padding(.bottom, 40)

            Group {
                if stage == .done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(C.accent)
                } else if stage == .error {
                    Circle().fill(C.error).frame(width: 12, height: 12)
                } else {
                    ProgressView().tint(C.accent).scaleEffect(0.8)
                }
            }
            .padding(.bottom, 16)

            Text(stageMessage)
                .font(.system(size: 16))
                .foregroundColor(stage == .error ? C.error : (stage == .done ? C.accent : C.textSec))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            if stage == .done {
                Text("\(ruleCount) style rule\(ruleCount == 1 ? "" : "s") active")
                    .font(.system(size: 13))
                    .foregroundColor(C.textMuted)
                    .padding(.top, 8)
            }

            Spacer()

            // Back button visible during processing/error
            if stage != .done {
                Button {
                    app.home()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 14))
                        .foregroundColor(C.textDim)
                }
                .padding(.bottom, 40)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.bg.ignoresSafeArea())
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task { await process() }
    }

    private var stageMessage: String {
        switch stage {
        case .uploading: return "Uploading audio..."
        case .transcribing: return "Transcribing..."
        case .extracting: return "Extracting style rules..."
        case .done: return "Style updated"
        case .error: return "Error: \(errorMsg)"
        }
    }

    private func process() async {
        do {
            // 1. Transcribe audio
            stage = .uploading
            let transcript = try await APIService.transcribe(fileURL: params.audioURL)

            // 2. Extract style rules
            stage = .extracting
            // TODO: Replace with authenticated user_id
            let count = try await APIService.extractStyleRules(
                transcript: transcript,
                userId: app.userId,
                anthropicKey: app.anthropicKey
            )
            ruleCount = count

            // 3. Done — show success briefly then go home
            stage = .done
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            app.home()

        } catch {
            errorMsg = error.localizedDescription
            stage = .error
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            app.home()
        }
    }
}
