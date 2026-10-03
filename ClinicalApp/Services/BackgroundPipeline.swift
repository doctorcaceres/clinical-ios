import Foundation
import UserNotifications

extension Notification.Name {
    static let clinicalNoteReady = Notification.Name("clinicalNoteReady")
}

/// Kill-proof note pipeline. After the doctor taps Generate/Skip the app goes
/// straight home; this object hands the remaining work to a BACKGROUND
/// URLSession, which iOS runs in a system daemon — uploads and the trigger
/// request continue with the phone locked, the app backgrounded, or the app
/// killed by the system (a user force-quit is the one thing iOS cancels).
///
/// Chain (each step's context rides in taskDescription, which iOS persists
/// across app relaunches):
///   1. PUT audio → signed Storage URL          (taskDescription "upload|<job>")
///   2. POST /api/process-encounter             (taskDescription "trigger|<job>")
///      → server transcribes + generates + saves independently of the phone
///   3. On the trigger's 200: delete local audio, post "note ready" local
///      notification, clear the home banner.
final class BackgroundPipeline: NSObject {
    static let shared = BackgroundPipeline()
    static let sessionIdentifier = "com.doctorcaceres.clinical.pipeline"

    /// Set by AppDelegate when iOS relaunches us for background session events.
    var backgroundCompletionHandler: (() -> Void)?

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        cfg.allowsCellularAccess = true
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    struct Job: Codable {
        let encounterId: String
        let encounterType: String
        let userId: String
        let filename: String
        let localAudioPath: String
    }

    /// Ensure the session (and its pending-task delegate wiring) exists —
    /// called from AppDelegate on background relaunch.
    func activate() { _ = session }

    // MARK: - Submit (called while app is foreground, right after row creation)
    func submit(encounterId: String, encounterType: String, userId: String, audioURL: URL) async throws {
        let filename = audioURL.lastPathComponent
        let signedURL = try await APIService.requestSignedUploadURL(filename: filename)

        let attrs = try FileManager.default.attributesOfItem(atPath: audioURL.path)
        let sizeBytes = (attrs[.size] as? Int) ?? 0
        guard sizeBytes > 0 else { throw ClinicalError.server("Audio file is empty") }

        var req = URLRequest(url: signedURL)
        req.httpMethod = "PUT"
        req.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        req.setValue("true", forHTTPHeaderField: "x-upsert")
        req.timeoutInterval = 600

        let job = Job(encounterId: encounterId, encounterType: encounterType,
                      userId: userId, filename: filename, localAudioPath: audioURL.path)
        let task = session.uploadTask(with: req, fromFile: audioURL)
        task.taskDescription = "upload|" + (Self.encode(job) ?? "")
        task.resume()
        print("[Pipeline] Background upload enqueued for \(filename) (\(sizeBytes) bytes), encounter \(encounterId)")
    }

    // MARK: - Step 2: trigger server-side processing
    private func enqueueTrigger(_ job: Job) {
        do {
            let body: [String: String] = [
                "encounter_id": job.encounterId,
                "encounter_type": job.encounterType,
                "user_id": job.userId,
                "audio_filename": job.filename,
            ]
            let data = try JSONSerialization.data(withJSONObject: body)
            // Background upload tasks must read the body from a file.
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                .appendingPathComponent("pipeline", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let bodyFile = dir.appendingPathComponent("trigger_\(job.encounterId).json")
            try data.write(to: bodyFile)

            var req = URLRequest(url: URL(string: "https://clinical-app-ten.vercel.app/api/process-encounter")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 600

            let task = session.uploadTask(with: req, fromFile: bodyFile)
            task.taskDescription = "trigger|" + (Self.encode(job) ?? "")
            task.resume()
            print("[Pipeline] Trigger enqueued for encounter \(job.encounterId)")
        } catch {
            print("[Pipeline] Failed to enqueue trigger: \(error.localizedDescription)")
            finishWithFailure(job, reason: "Could not start note generation")
        }
    }

    // MARK: - Completion handling
    private func finishWithSuccess(_ job: Job) {
        // Note is saved in Supabase. Local audio no longer needed.
        try? FileManager.default.removeItem(atPath: job.localAudioPath)
        cleanupBodyFile(job)
        notify(title: "Note ready",
               body: "Your \(job.encounterType == "new" ? "new patient" : "follow-up") note is ready in Recent Notes.")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .clinicalNoteReady, object: job.encounterId)
        }
        print("[Pipeline] SUCCESS for encounter \(job.encounterId)")
    }

    private func finishWithFailure(_ job: Job, reason: String) {
        cleanupBodyFile(job)
        // Keep the local audio — Recent Notes retry still works from transcript,
        // and the audio stays recoverable on disk.
        Task {
            try? await DB.shared.update(id: job.encounterId, fields: ["status": "error"])
        }
        notify(title: "Note failed",
               body: "\(reason). Open Recent Notes and tap Retry.")
        print("[Pipeline] FAILURE for encounter \(job.encounterId): \(reason)")
    }

    private func cleanupBodyFile(_ job: Job) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("pipeline", isDirectory: true)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("trigger_\(job.encounterId).json"))
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - Helpers
    private static func encode(_ job: Job) -> String? {
        guard let d = try? JSONEncoder().encode(job) else { return nil }
        return String(data: d, encoding: .utf8)
    }
    private static func decode(_ s: String) -> Job? {
        guard let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Job.self, from: d)
    }
}

// MARK: - URLSession delegate (runs on background queue; may run in a
// background relaunch of the app after iOS killed it)
extension BackgroundPipeline: URLSessionTaskDelegate, URLSessionDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let desc = task.taskDescription else { return }
        let parts = desc.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let job = Self.decode(parts[1]) else { return }
        let step = parts[0]
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0

        print("[Pipeline] \(step) completed for \(job.encounterId) — status=\(status), error=\(error?.localizedDescription ?? "none")")

        switch step {
        case "upload":
            if error == nil && (200...299).contains(status) {
                enqueueTrigger(job)
            } else {
                finishWithFailure(job, reason: "Audio upload failed")
            }
        case "trigger":
            if error == nil && status == 200 {
                finishWithSuccess(job)
            } else {
                finishWithFailure(job, reason: "Note generation failed")
            }
        default:
            break
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }
}
