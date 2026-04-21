import Foundation

/// All server communication. Uses raw binary upload for audio (avoids base64 overhead and Vercel body limits).
enum APIService {

    // MARK: - Transcribe: upload raw M4A binary → get transcript
    static func transcribe(fileURL: URL) async throws -> String {
        let audioData = try Data(contentsOf: fileURL)
        let sizeMB = Double(audioData.count) / 1_048_576
        print("[API] Uploading audio: \(String(format: "%.1f", sizeMB)) MB")

        // Raw binary upload — Content-Type tells the server and Deepgram the format
        let url = URL(string: "https://clinical-app-ten.vercel.app/api/transcribe-audio")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300

        let (data, response) = try await URLSession.shared.upload(for: req, from: audioData)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard status == 200 else {
            let errMsg = parseError(data) ?? "Transcription failed (HTTP \(status))"
            throw ClinicalError.server(errMsg)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let transcript = json["transcript"] as? String, !transcript.isEmpty else {
            throw ClinicalError.server("No transcript returned — audio may be too short")
        }

        print("[API] Transcript: \(transcript.count) chars")
        return transcript
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
