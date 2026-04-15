import Foundation

/// Direct Supabase PostgREST integration — zero dependencies.
final class DB {
    static let shared = DB()
    private init() {}

    private var headers: [String: String] {
        ["apikey": API.supabaseKey, "Authorization": "Bearer \(API.supabaseKey)", "Content-Type": "application/json"]
    }

    func createEncounter(type: String) async throws -> String {
        let url = URL(string: "\(API.supabaseURL)/rest/v1/encounters")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("return=representation", forHTTPHeaderField: "Prefer")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "encounter_type": type,
            "status": "recording",
            "created_at": ISO8601DateFormatter().string(from: Date()),
        ])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 201 else {
            throw ClinicalError.server("Failed to create encounter: \(String(data: data, encoding: .utf8) ?? "")")
        }
        let rows = try JSONDecoder().decode([Encounter].self, from: data)
        guard let id = rows.first?.id else { throw ClinicalError.server("No encounter ID returned") }
        return id
    }

    func update(id: String, fields: [String: Any]) async throws {
        let url = URL(string: "\(API.supabaseURL)/rest/v1/encounters?id=eq.\(id)")!
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.timeoutInterval = 30
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        var body = fields
        body["updated_at"] = ISO8601DateFormatter().string(from: Date())
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let hr = resp as? HTTPURLResponse, (200...299).contains(hr.statusCode) else {
            throw ClinicalError.server("Failed to update encounter")
        }
    }

    func encounters(limit: Int = 20) async throws -> [Encounter] {
        let url = URL(string: "\(API.supabaseURL)/rest/v1/encounters?select=*&order=created_at.desc&limit=\(limit)")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode([Encounter].self, from: data)
    }

    func encounter(id: String) async throws -> Encounter? {
        let url = URL(string: "\(API.supabaseURL)/rest/v1/encounters?id=eq.\(id)&select=*")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode([Encounter].self, from: data).first
    }

    func delete(id: String) async throws {
        let url = URL(string: "\(API.supabaseURL)/rest/v1/encounters?id=eq.\(id)")!
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.timeoutInterval = 15
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        _ = try await URLSession.shared.data(for: req)
    }
}
