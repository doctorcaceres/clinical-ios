import SwiftUI
import UserNotifications

/// Receives the background-URLSession relaunch: when the note pipeline
/// finishes while the app is dead, iOS relaunches us here so
/// BackgroundPipeline can process the completion and post the notification.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundPipeline.sessionIdentifier else { completionHandler(); return }
        BackgroundPipeline.shared.backgroundCompletionHandler = completionHandler
        BackgroundPipeline.shared.activate()
    }
}

@main
struct ClinicalApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppState()
    @StateObject private var auth = AuthService.shared

    init() {
        // Local notification permission ("Note ready") — one-time system prompt.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        BackgroundPipeline.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if !auth.isSignedIn {
                    SignInView()
                } else if app.showWelcome {
                    WelcomeView()
                } else {
                    NavigationStack(path: $app.path) {
                        HomeView()
                            .navigationDestination(for: Route.self) { route in
                                switch route {
                                case .recording(let t):     RecordingView(type: t)
                                case .instructions(let p):  InstructionsView(params: p)
                                case .trainingChat:         TrainingChatView()
                                case .noteReview(let e):    NoteReviewView(encounter: e)
                                case .recentNotes:          RecentNotesView()
                                case .settings:             SettingsView()
                                }
                            }
                    }
                    .toolbar(.hidden, for: .navigationBar)
                }
            }
            .environmentObject(app)
            .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Routes
enum Route: Hashable {
    case recording(String)              // encounter type: "new", "followup"
    case instructions(ProcessParams)    // optional post-recording instructions
    case trainingChat
    case noteReview(Encounter)
    case recentNotes
    case settings
}

struct ProcessParams: Hashable {
    let encounterType: String           // "new" or "followup"
    let audioURL: URL
    let elapsed: Int
    let instructions: String?
}

// MARK: - Global state
@MainActor
final class AppState: ObservableObject {
    @Published var path = NavigationPath()
    @Published var pendingNoteId: String?
    @Published var showWelcome = false

    init() {
        // API keys live ONLY on the server now. Purge any key a previous
        // build stored in the Keychain — idempotent, runs on every launch.
        Keychain.delete("anthropic_key")

        // Clear the home "note is being written" banner when the background
        // pipeline reports the note landed.
        NotificationCenter.default.addObserver(forName: .clinicalNoteReady, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let id = note.object as? String, self.pendingNoteId == id || self.pendingNoteId == nil {
                    self.pendingNoteId = nil
                }
            }
        }
    }

    /// First-sign-in onboarding: show the welcome screen only when this
    /// account has no data yet and hasn't been welcomed on this device.
    func evaluateWelcome() async {
        guard let uid = AuthService.shared.uid else { return }
        let flag = "welcomed_\(uid)"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        if let page = try? await DB.shared.encountersPage(page: 0, pageSize: 1), page.total == 0 {
            showWelcome = true
        } else {
            UserDefaults.standard.set(true, forKey: flag)
        }
    }

    func dismissWelcome() {
        if let uid = AuthService.shared.uid {
            UserDefaults.standard.set(true, forKey: "welcomed_\(uid)")
        }
        showWelcome = false
    }

    func push(_ route: Route) { path.append(route) }
    func home() { path = NavigationPath() }
}
