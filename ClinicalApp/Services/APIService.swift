import Foundation

/// All server communication. Uses raw binary upload for audio (avoids base64 overhead and Vercel body limits).
enum APIService {

    /// Dedicated URLSession for audio uploads. Both per-request and per-resource
    /// timeouts are set to 300s so a long encounter can finish uploading even on a
    /// slow cellular connection. waitsForConnectivity prevents instant failure if
    /// the radio briefly drops between recording and upload.
    private static let audioSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.allowsCellularAccess = true
        return URLSession(configuration: config)
    }()

    // MARK: - Storage bucket name
    static let storageBucket = "encounter-audio"

    /// Ask the server to sign an upload URL for the private bucket.
    /// Used by the foreground upload path and by BackgroundPipeline.
    static func requestSignedUploadURL(filename: String) async throws -> URL {
        let endpoint = URL(string: "https://clinical-app-ten.vercel.app/api/upload-url")!
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = try JSONSerialization.data(withJSONObject: ["filename": filename])

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlString = json["signedUrl"] as? String,
              let url = URL(string: urlString) else {
            let errMsg = parseError(data) ?? "Could not get signed upload URL (HTTP \(status))"
            print("[API] upload-url failed: \(errMsg)")
            throw ClinicalError.server(errMsg)
        }
        print("[API] signed URL issued for \(filename)")
        return url
    }

    /// Upload a recorded M4A from local Documents to the PRIVATE Supabase
    /// Storage bucket via a server-issued signed URL. Two steps:
    ///   1. POST /api/upload-url with the filename → server (holding the
    ///      service-role key) returns a short-lived signed upload URL.
    ///   2. PUT the audio to that signed URL, streaming from disk.
    /// No Supabase key is ever used for uploads, the bucket stays private,
    /// and no anon RLS policies exist. Returns the filename.
    static func uploadAudioToStorage(fileURL: URL) async throws -> String {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let sizeBytes = (attrs[.size] as? Int) ?? 0
        let sizeMB = Double(sizeBytes) / 1_048_576

        print("[API] ===== STORAGE UPLOAD START =====")
        print("[API] file: \(fileURL.lastPathComponent)")
        print("[API] size: \(String(format: "%.2f", sizeMB)) MB (\(sizeBytes) bytes)")

        guard sizeBytes > 0 else {
            throw ClinicalError.server("Audio file is empty (0 bytes) — recording may have failed")
        }

        let filename = fileURL.lastPathComponent

        // Step 1: ask the server for a signed upload URL
        let signedUrl = try await requestSignedUploadURL(filename: filename)

        // Step 2: PUT the audio to the signed URL, streaming from disk
        var req = URLRequest(url: signedUrl)
        req.httpMethod = "PUT"
        req.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        req.setValue("true", forHTTPHeaderField: "x-upsert")  // allow re-upload on retry
        req.setValue(String(sizeBytes), forHTTPHeaderField: "Content-Length")
        req.timeoutInterval = 300

        let started = Date()
        do {
            let (data, response) = try await audioSession.upload(for: req, fromFile: fileURL)
            let elapsed = Date().timeIntervalSince(started)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let bodyText = String(data: data, encoding: .utf8) ?? "<binary>"
            print("[API] ===== STORAGE UPLOAD DONE =====")
            print("[API] HTTP \(status) in \(String(format: "%.1f", elapsed))s")
            print("[API] body: \(bodyText.prefix(400))")

            guard (200...299).contains(status) else {
                throw ClinicalError.server("Storage upload failed (HTTP \(status)): \(bodyText.prefix(200))")
            }

            print("[API] uploaded to private bucket — filename: \(filename)")
            return filename

        } catch let nsError as NSError {
            let elapsed = Date().timeIntervalSince(started)
            print("[API] ===== STORAGE UPLOAD FAILED =====")
            print("[API] after: \(String(format: "%.1f", elapsed))s")
            print("[API] domain: \(nsError.domain) code: \(nsError.code)")
            print("[API] desc: \(nsError.localizedDescription)")
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                print("[API] underlying: \(underlying.domain)/\(underlying.code) — \(underlying.localizedDescription)")
            }
            throw nsError
        }
    }

    /// Tell the server to fetch the audio from PRIVATE Supabase Storage and transcribe via Deepgram.
    /// The argument is the filename returned by uploadAudioToStorage — sent in the JSON body as
    /// `audio_url` for backward compatibility. The server uses the service-role key to download
    /// and to immediately delete the file once Deepgram returns a transcript.
    static func transcribeFromURL(_ audioFilename: String, durationSeconds: Int = 0) async throws -> String {
        let durationDesc = durationSeconds > 0 ? "\(durationSeconds)s (\(durationSeconds / 60)m \(durationSeconds % 60)s)" : "unknown"
        print("[API] ===== TRANSCRIBE FROM STORAGE =====")
        print("[API] filename: \(audioFilename)")
        print("[API] duration: \(durationDesc)")

        let endpoint = URL(string: "https://clinical-app-ten.vercel.app/api/transcribe-audio")!
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600

        let body: [String: String] = ["audio_url": audioFilename]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = Date()
        do {
            let (data, response) = try await audioSession.data(for: req)
            let elapsed = Date().timeIntervalSince(started)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let bodyText = String(data: data, encoding: .utf8) ?? "<binary>"
            print("[API] ===== TRANSCRIBE DONE =====")
            print("[API] HTTP \(status) in \(String(format: "%.1f", elapsed))s")
            print("[API] response: \(bodyText.prefix(800))")

            guard status == 200 else {
                let errMsg = parseError(data) ?? "Transcription failed (HTTP \(status))"
                throw ClinicalError.server(errMsg)
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let transcript = json["transcript"] as? String, !transcript.isEmpty else {
                throw ClinicalError.server("No transcript returned — audio may be too short or silent")
            }

            print("[API] transcript: \(transcript.count) chars")
            return transcript

        } catch let nsError as NSError {
            let elapsed = Date().timeIntervalSince(started)
            print("[API] ===== TRANSCRIBE FAILED =====")
            print("[API] after: \(String(format: "%.1f", elapsed))s")
            print("[API] domain: \(nsError.domain) code: \(nsError.code)")
            print("[API] desc: \(nsError.localizedDescription)")
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                print("[API] underlying: \(underlying.domain)/\(underlying.code) — \(underlying.localizedDescription)")
            }
            throw nsError
        }
    }

    /// Convenience: upload to Storage + transcribe. Used by training mode and chat mic.
    /// (Instructions-screen dictation and Training Chat use this one-shot path.)
    static func transcribe(fileURL: URL, durationSeconds: Int = 0) async throws -> String {
        let url = try await uploadAudioToStorage(fileURL: fileURL)
        return try await transcribeFromURL(url, durationSeconds: durationSeconds)
    }

    // NOTE: There is no Swift-side Storage delete. The phone has INSERT-only
    // permission on the encounter-audio bucket. The server (with the service
    // role key) deletes the file immediately after a successful transcript.

    // MARK: - Generate note: send encounter_id + type → server generates note via Claude
    // All API keys live server-side (Vercel env vars). The app never sends keys.
    static func generateNote(encounterId: String, encounterType: String, userId: String) async throws {
        let url = URL(string: "https://clinical-app-ten.vercel.app/api/generate-note")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300

        let body: [String: String] = [
            "encounter_id": encounterId,
            "encounter_type": encounterType,
            "user_id": userId,    // TODO: Replace with authenticated user_id
        ]

        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status != 200 {
            let errMsg = parseError(data) ?? "Note generation failed (HTTP \(status))"
            print("[API] generate-note error: \(errMsg)")
            throw ClinicalError.server(errMsg)
        }
    }

    // MARK: - Training chat: send message → get response + updated rule count
    struct ChatResponse {
        let text: String
        let ruleCount: Int
    }

    static func trainingChat(userId: String, message: String, history: [[String: String]]) async throws -> ChatResponse {
        let url = URL(string: "https://clinical-app-ten.vercel.app/api/training-chat")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60

        let body: [String: Any] = [
            "user_id": userId,       // TODO: Replace with authenticated user_id
            "message": message,
            "conversation_history": history,
        ]

        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard status == 200 else {
            let errMsg = parseError(data) ?? "Chat failed (HTTP \(status))"
            throw ClinicalError.server(errMsg)
        }

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text = json?["response"] as? String ?? "I've noted your preference."
        let count = json?["rule_count"] as? Int ?? 0
        return ChatResponse(text: text, ruleCount: count)
    }

    // MARK: - Save chat session summary (called on Done in Training Chat)
    static func saveChatSession(userId: String, history: [[String: String]]) async {
        // Fire-and-forget — errors are silently logged
        do {
            guard !history.isEmpty else { return }
            let url = URL(string: "https://clinical-app-ten.vercel.app/api/save-chat-session")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 60

            let body: [String: Any] = [
                "user_id": userId,       // TODO: Replace with authenticated user_id
                "conversation_history": history,
            ]

            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("[API] save-chat-session: HTTP \(status)")
        } catch {
            print("[API] save-chat-session error (silent): \(error.localizedDescription)")
        }
    }

    // MARK: - Extract corrections silently (Save Final learning)
    static func extractCorrections(userId: String, originalNote: [String: String], editedNote: [String: String]) async {
        // Fire-and-forget — errors are silently ignored
        do {
            let url = URL(string: "https://clinical-app-ten.vercel.app/api/extract-corrections")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 120

            let body: [String: Any] = [
                "user_id": userId,           // TODO: Replace with authenticated user_id
                "original_note": originalNote,
                "edited_note": editedNote,
            ]

            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("[API] extract-corrections: HTTP \(status)")
        } catch {
            print("[API] extract-corrections error (silent): \(error.localizedDescription)")
        }
    }

    // MARK: - Network test
    static func networkTest() async -> String {
        do {
            let url = URL(string: "https://clinical-app-ten.vercel.app/api/transcribe-audio")!
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 15
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 405 = Method Not Allowed (expected — endpoint only accepts POST)
            return "Connected! Server responded: HTTP \(status)"
        } catch {
            return "FAILED: \(error.localizedDescription)"
        }
    }

    private static func parseError(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
    }
}

enum ClinicalError: LocalizedError {
    case server(String)
    var errorDescription: String? {
        switch self { case .server(let m): return m }
    }
}
