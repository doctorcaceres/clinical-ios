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

    // MARK: - Transcribe: stream raw M4A binary from disk → get transcript
    static func transcribe(fileURL: URL, durationSeconds: Int = 0) async throws -> String {
        // Pre-flight: read file size for logging (does NOT load the file into RAM)
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let sizeBytes = (attrs[.size] as? Int) ?? 0
        let sizeMB = Double(sizeBytes) / 1_048_576
        let durationDesc = durationSeconds > 0 ? "\(durationSeconds)s (\(durationSeconds / 60)m \(durationSeconds % 60)s)" : "unknown"
        print("[API] ===== UPLOAD START =====")
        print("[API] file:     \(fileURL.lastPathComponent)")
        print("[API] size:     \(String(format: "%.2f", sizeMB)) MB (\(sizeBytes) bytes)")
        print("[API] duration: \(durationDesc)")

        guard sizeBytes > 0 else {
            throw ClinicalError.server("Audio file is empty (0 bytes) — recording may have failed")
        }

        let url = URL(string: "https://clinical-app-ten.vercel.app/api/transcribe-audio")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        req.setValue(String(sizeBytes), forHTTPHeaderField: "Content-Length")
        req.timeoutInterval = 300

        let started = Date()
        do {
            // Stream the file from disk. NEVER load the whole audio into RAM.
            // upload(for:fromFile:) uses URLSession's underlying NSURLSessionUploadTask
            // which reads the file in chunks straight to the network.
            let (data, response) = try await audioSession.upload(for: req, fromFile: fileURL)
            let elapsed = Date().timeIntervalSince(started)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let bodyText = String(data: data, encoding: .utf8) ?? "<\(data.count) binary bytes>"
            print("[API] ===== UPLOAD DONE =====")
            print("[API] HTTP \(status) in \(String(format: "%.1f", elapsed))s")
            print("[API] response (\(data.count) bytes): \(bodyText.prefix(800))")

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
            print("[API] ===== UPLOAD FAILED =====")
            print("[API] after: \(String(format: "%.1f", elapsed))s")
            print("[API] domain: \(nsError.domain)")
            print("[API] code:   \(nsError.code)")
            print("[API] desc:   \(nsError.localizedDescription)")
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                print("[API] underlying: \(underlying.domain)/\(underlying.code) — \(underlying.localizedDescription)")
            }
            for (k, v) in nsError.userInfo where k != NSUnderlyingErrorKey {
                print("[API] userInfo[\(k)]: \(v)")
            }
            throw nsError
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
