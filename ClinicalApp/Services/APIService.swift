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

    /// Upload a recorded M4A from local Documents to Supabase Storage.
    /// Streams from disk (never loads file into RAM). Returns the public URL
    /// the server can later download from. Bypasses any Vercel body size limit.
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
        let endpoint = URL(string: "\(API.supabaseURL)/storage/v1/object/\(storageBucket)/\(filename)")!

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(API.supabaseKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(API.supabaseKey)", forHTTPHeaderField: "Authorization")
        req.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        req.setValue("3600", forHTTPHeaderField: "Cache-Control")
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

            guard status == 200 else {
                throw ClinicalError.server("Storage upload failed (HTTP \(status)): \(bodyText.prefix(200))")
            }

            let publicURL = "\(API.supabaseURL)/storage/v1/object/public/\(storageBucket)/\(filename)"
            print("[API] public URL: \(publicURL)")
            return publicURL

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

    /// Tell the server to fetch the audio from Supabase Storage and transcribe via Deepgram.
    /// The server side downloads the file (bypassing Vercel's request body limit) and runs Deepgram.
    static func transcribeFromURL(_ audioURL: String, durationSeconds: Int = 0) async throws -> String {
        let durationDesc = durationSeconds > 0 ? "\(durationSeconds)s (\(durationSeconds / 60)m \(durationSeconds % 60)s)" : "unknown"
        print("[API] ===== TRANSCRIBE FROM URL =====")
        print("[API] url:      \(audioURL)")
        print("[API] duration: \(durationDesc)")

        let endpoint = URL(string: "https://clinical-app-ten.vercel.app/api/transcribe-audio")!
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600

        let body: [String: String] = ["audio_url": audioURL]
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
    /// (ProcessingView splits these so it can cache the URL across retries.)
    static func transcribe(fileURL: URL, durationSeconds: Int = 0) async throws -> String {
        let url = try await uploadAudioToStorage(fileURL: fileURL)
        return try await transcribeFromURL(url, durationSeconds: durationSeconds)
    }

    /// Delete an audio file from Supabase Storage. Silent — never throws.
    /// Called only after a finalized note exists, or after one-shot training/chat
    /// transcription where the audio is no longer needed.
    static func deleteAudioFromStorage(filename: String) async {
        let endpoint = URL(string: "\(API.supabaseURL)/storage/v1/object/\(storageBucket)/\(filename)")!
        var req = URLRequest(url: endpoint)
        req.httpMethod = "DELETE"
        req.setValue(API.supabaseKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(API.supabaseKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("[API] Storage delete: HTTP \(status) for \(filename)")
        } catch {
            print("[API] Storage delete error (non-fatal): \(error.localizedDescription)")
        }
    }

    // MARK: - Generate note: send encounter_id + type → server generates note via Claude
    static func generateNote(encounterId: String, encounterType: String, anthropicKey: String, userId: String) async throws {
        let url = URL(string: "https://clinical-app-ten.vercel.app/api/generate-note")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300

        var body: [String: String] = [
            "encounter_id": encounterId,
            "encounter_type": encounterType,
            "user_id": userId,    // TODO: Replace with authenticated user_id
        ]
        // Send anthropic key if we have one (server also checks env var as fallback)
        if !anthropicKey.isEmpty { body["anthropic_key"] = anthropicKey }

        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status != 200 {
            let errMsg = parseError(data) ?? "Note generation failed (HTTP \(status))"
            print("[API] generate-note error: \(errMsg)")
            throw ClinicalError.server(errMsg)
        }
    }

    // MARK: - Extract style rules from training dictation → returns rule count
    static func extractStyleRules(transcript: String, userId: String, anthropicKey: String) async throws -> Int {
        let url = URL(string: "https://clinical-app-ten.vercel.app/api/extract-style-rules")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120

        var body: [String: String] = [
            "transcript": transcript,
            "user_id": userId,    // TODO: Replace with authenticated user_id
        ]
        if !anthropicKey.isEmpty { body["anthropic_key"] = anthropicKey }

        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard status == 200 else {
            let errMsg = parseError(data) ?? "Style extraction failed (HTTP \(status))"
            throw ClinicalError.server(errMsg)
        }

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["rule_count"] as? Int ?? 0
    }

    // MARK: - Training chat: send message → get response + updated rule count
    struct ChatResponse {
        let text: String
        let ruleCount: Int
    }

    static func trainingChat(userId: String, message: String, history: [[String: String]], anthropicKey: String) async throws -> ChatResponse {
        let url = URL(string: "https://clinical-app-ten.vercel.app/api/training-chat")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60

        var body: [String: Any] = [
            "user_id": userId,       // TODO: Replace with authenticated user_id
            "message": message,
            "conversation_history": history,
        ]
        if !anthropicKey.isEmpty { body["anthropic_key"] = anthropicKey }

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
    static func saveChatSession(userId: String, history: [[String: String]], anthropicKey: String) async {
        // Fire-and-forget — errors are silently logged
        do {
            guard !history.isEmpty else { return }
            let url = URL(string: "https://clinical-app-ten.vercel.app/api/save-chat-session")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 60

            var body: [String: Any] = [
                "user_id": userId,       // TODO: Replace with authenticated user_id
                "conversation_history": history,
            ]
            if !anthropicKey.isEmpty { body["anthropic_key"] = anthropicKey }

            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("[API] save-chat-session: HTTP \(status)")
        } catch {
            print("[API] save-chat-session error (silent): \(error.localizedDescription)")
        }
    }

    // MARK: - Extract corrections silently (Save Final learning)
    static func extractCorrections(userId: String, originalNote: [String: String], editedNote: [String: String], anthropicKey: String) async {
        // Fire-and-forget — errors are silently ignored
        do {
            let url = URL(string: "https://clinical-app-ten.vercel.app/api/extract-corrections")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 120

            var body: [String: Any] = [
                "user_id": userId,           // TODO: Replace with authenticated user_id
                "original_note": originalNote,
                "edited_note": editedNote,
            ]
            if !anthropicKey.isEmpty { body["anthropic_key"] = anthropicKey }

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
