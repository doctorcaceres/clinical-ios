import SwiftUI

@main
struct ClinicalApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            Group {
                if app.isSetup {
                    NavigationStack(path: $app.path) {
                        HomeView()
                            .navigationDestination(for: Route.self) { route in
                                switch route {
                                case .recording(let t):             RecordingView(type: t)
                                case .processing(let p):            ProcessingView(params: p)
                                case .trainingProcessing(let p):    TrainingProcessingView(params: p)
                                case .trainingChat:                 TrainingChatView()
                                case .noteReview(let e):            NoteReviewView(encounter: e)
                                case .recentNotes:                  RecentNotesView()
                                }
                            }
                    }
                    .toolbar(.hidden, for: .navigationBar)
                } else {
                    SetupView()
                }
            }
            .environmentObject(app)
            .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Routes
enum Route: Hashable {
    case recording(String)              // encounter type: "new", "followup", "training"
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
    @Published var isSetup = false
    @Published var anthropicKey = ""
    @Published var path = NavigationPath()
    @Published var pendingNoteId: String?

    // TODO: Replace with authenticated user_id when auth is implemented
    let userId = "test_user_1"

    init() {
        if let k = Keychain.load("anthropic_key"), !k.isEmpty {
            anthropicKey = k
            isSetup = true
        }
    }

    func setup(key: String) {
        Keychain.save(key, key: "anthropic_key")
        anthropicKey = key
        isSetup = true
    }

    func push(_ route: Route) { path.append(route) }
    func home() { path = NavigationPath() }
}
