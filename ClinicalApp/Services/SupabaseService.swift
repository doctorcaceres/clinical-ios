import Foundation

/// Direct Supabase PostgREST integration — zero dependencies.
final class DB {
    static let shared = DB()
    private init() {}

    /// Direct PostgREST calls carry the USER's JWT so row-level security
    /// scopes every query to the signed-in doctor. The publishable key is
    /// only the apikey / signed-out fallback.
    private func headers() async -> [String: String] {
        let token = await AuthService.shared.validToken() ?? API.supabaseKey
        return ["apikey": API.supabaseKey, "Authorization": "Bearer \(token)", "Content-Type": "application/json"]
    }

    func createEncounter(type: String) async throws -> String {
        let url = URL(string: "\(API.supabaseURL)/rest/v1/encounters")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        for (k, v) in await headers() { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("return=representation", forHTTPHeaderField: "Prefer")
        var row: [String: Any] = [
            "encounter_type": type,
            "status": "recording",
            "created_at": ISO8601DateFormatter().string(from: Date()),
        ]
        // Explicit attribution (RLS default also covers this once enabled)
        if let uid = await AuthService.shared.uid { row["user_id"] = uid }
        req.httpBody = try JSONSerialization.data(withJSONObject: row)

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
        for (k, v) in await headers() { req.setValue(v, forHTTPHeaderField: k) }
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
        for (k, v) in await headers() { req.setValue(v, forHTTPHeaderField: k) }
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode([Encounter].self, from: data)
    }

    struct EncounterPage {
        let rows: [Encounter]
        let total: Int
    }

    /// Server-side pagination: limit/offset, newest first. The total comes
    /// from the Content-Range header when Prefer: count=exact is sent
    /// (e.g. "0-9/137").
    func encountersPage(page: Int, pageSize: Int = 10) async throws -> EncounterPage {
        let offset = max(0, page) * pageSize
        let url = URL(string: "\(API.supabaseURL)/rest/v1/encounters?select=*&order=created_at.desc&limit=\(pageSize)&offset=\(offset)")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        for (k, v) in await headers() { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("count=exact", forHTTPHeaderField: "Prefer")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let rows = try JSONDecoder().decode([Encounter].self, from: data)
        var total = rows.count
        if let http = resp as? HTTPURLResponse,
           let range = http.value(forHTTPHeaderField: "Content-Range"),
           let totalPart = range.split(separator: "/").last,
           let t = Int(totalPart) {
            total = t
        }
        return EncounterPage(rows: rows, total: total)
    }

    func encounter(id: String) async throws -> Encounter? {
        let url = URL(string: "\(API.supabaseURL)/rest/v1/encounters?id=eq.\(id)&select=*")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        for (k, v) in await headers() { req.setValue(v, forHTTPHeaderField: k) }
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode([Encounter].self, from: data).first
    }

    func delete(id: String) async throws {
        let url = URL(string: "\(API.supabaseURL)/rest/v1/encounters?id=eq.\(id)")!
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.timeoutInterval = 15
        for (k, v) in await headers() { req.setValue(v, forHTTPHeaderField: k) }
        _ = try await URLSession.shared.data(for: req)
    }
}
