import SwiftUI

@main
struct ClinicalApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $app.path) {
                HomeView()
                    .navigationDestination(for: Route.self) { route in
                        switch route {
                        case .recording(let t):             RecordingView(type: t)
                        case .instructions(let p):          InstructionsView(params: p)
                        case .processing(let p):            ProcessingView(params: p)
                        case .trainingProcessing(let p):    TrainingProcessingView(params: p)
                        case .trainingChat:                 TrainingChatView()
                        case .noteReview(let e):            NoteReviewView(encounter: e)
                        case .recentNotes:                  RecentNotesView()
                        }
                    }
            }
            .toolbar(.hidden, for: .navigationBar)
            .environmentObject(app)
            .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Routes
enum Route: Hashable {
    case recording(String)              // encounter type: "new", "followup", "training"
    case instructions(ProcessParams)    // optional post-recording instructions
    case processing(ProcessParams)
    case trainingProcessing(TrainingParams)
    case trainingChat
    case noteReview(Encounter)
    case recentNotes
}

struct ProcessParams: Hashable {
    let encounterType: String           // "new" or "followup"
    let audioURL: URL
    let elapsed: Int
    let instructions: String?
}

struct TrainingParams: Hashable {
    let audioURL: URL
    let elapsed: Int
}

// MARK: - Global state
@MainActor
final class AppState: ObservableObject {
    @Published var path = NavigationPath()
    @Published var pendingNoteId: String?

    // TODO: Replace with authenticated user_id when auth is implemented
    let userId = "test_user_1"

    /// Transcription kicked off the instant recording stops, so it runs
    /// while the doctor is on the Instructions screen. ProcessingView
    /// claims it via takeBackgroundTranscription.
    private var pendingTranscription: (audioURL: URL, task: Task<String, Error>)?

    init() {
        // API keys live ONLY on the server now. Purge any key a previous
        // build stored in the Keychain — idempotent, runs on every launch.
        Keychain.delete("anthropic_key")
    }

    func startBackgroundTranscription(audioURL: URL, durationSeconds: Int) {
        pendingTranscription?.task.cancel()
        let task = Task {
            try await APIService.transcribe(fileURL: audioURL, durationSeconds: durationSeconds)
        }
        pendingTranscription = (audioURL, task)
        print("[AppState] Background transcription started for \(audioURL.lastPathComponent)")
    }

    func takeBackgroundTranscription(for audioURL: URL) -> Task<String, Error>? {
        guard let p = pendingTranscription, p.audioURL == audioURL else { return nil }
        pendingTranscription = nil
        return p.task
    }

    func push(_ route: Route) { path.append(route) }
    func home() { path = NavigationPath() }
}
