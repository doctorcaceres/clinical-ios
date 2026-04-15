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
                                case .recording(let t):     RecordingView(type: t)
                                case .processing(let p):    ProcessingView(params: p)
                                case .noteReview(let e):    NoteReviewView(encounter: e)
                                case .recentNotes:          RecentNotesView()
                                }
                            }
                    }
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
    case recording(String)          // encounter type: "new", "followup", "training"
    case processing(ProcessParams)
    case noteReview(Encounter)
    case recentNotes
}

struct ProcessParams: Hashable {
    let encounterType: String       // "new" or "followup" — must match what Vercel expects
    let audioURL: URL
    let elapsed: Int
    let instructions: String?
}

// MARK: - Global state
@MainActor
final class AppState: ObservableObject {
    @Published var isSetup = false
    @Published var anthropicKey = ""
    @Published var path = NavigationPath()
    @Published var pendingNoteId: String?

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
