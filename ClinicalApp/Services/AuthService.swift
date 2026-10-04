import Foundation

/// Supabase GoTrue auth via plain REST — no SDK. The session (access +
/// refresh token) persists in the iOS Keychain; the access token auto-
/// refreshes when near expiry. user_id is NEVER sent by the app — every
/// server route derives it from the JWT this service attaches.
@MainActor
final class AuthService: ObservableObject {
    static let shared = AuthService()

    @Published var isSignedIn = false
    @Published var email = ""
    private(set) var uid: String?

    private var accessToken: String?
    private var refreshToken: String?
    private var expiresAt: TimeInterval = 0

    private init() {
        accessToken = Keychain.load("sb_access_token")
        refreshToken = Keychain.load("sb_refresh_token")
        expiresAt = Double(Keychain.load("sb_expires_at") ?? "") ?? 0
        email = Keychain.load("sb_email") ?? ""
        uid = Keychain.load("sb_uid")
        isSignedIn = refreshToken != nil
    }

    // MARK: - Sign in / out / recover
    func signIn(email: String, password: String) async throws {
        let data = try await tokenRequest(path: "token?grant_type=password",
                                          body: ["email": email, "password": password])
        try apply(tokenResponse: data)
    }

    func recover(email: String) async throws {
        var req = URLRequest(url: URL(string: "\(API.supabaseURL)/auth/v1/recover")!)
        req.httpMethod = "POST"
        req.setValue(API.supabaseKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["email": email])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode ?? 0 < 300 else {
            throw ClinicalError.server(Self.authError(data) ?? "Could not send reset email")
        }
    }

    func signOut() {
        if let t = accessToken {
            var req = URLRequest(url: URL(string: "\(API.supabaseURL)/auth/v1/logout")!)
            req.httpMethod = "POST"
            req.setValue(API.supabaseKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            let request = req   // immutable copy for the @Sendable closure
            Task.detached { _ = try? await URLSession.shared.data(for: request) }
        }
        for k in ["sb_access_token", "sb_refresh_token", "sb_expires_at", "sb_email", "sb_uid"] {
            Keychain.delete(k)
        }
        accessToken = nil; refreshToken = nil; expiresAt = 0; uid = nil
        email = ""
        isSignedIn = false
    }

    // MARK: - Token access (auto-refresh)
    /// Returns a currently-valid access token, refreshing if it expires within
    /// 60 seconds. Returns nil when signed out or refresh fails.
    func validToken() async -> String? {
        guard refreshToken != nil else { return nil }
        if Date().timeIntervalSince1970 > expiresAt - 60 {
            do { try await refresh() } catch {
                print("[Auth] Refresh failed: \(error.localizedDescription)")
                return nil
            }
        }
        return accessToken
    }

    private func refresh() async throws {
        guard let rt = refreshToken else { throw ClinicalError.server("Not signed in") }
        var req = URLRequest(url: URL(string: "\(API.supabaseURL)/auth/v1/token?grant_type=refresh_token")!)
        req.httpMethod = "POST"
        req.setValue(API.supabaseKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": rt])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400 || status == 401 {
            // Refresh token revoked or expired — session is dead. Surface the
            // sign-in screen instead of silently degrading to empty lists.
            signOut()
            throw ClinicalError.server("Session expired — please sign in again")
        }
        guard status == 200 else {
            // Transient failure: keep the session; next call retries
            throw ClinicalError.server(Self.authError(data) ?? "Could not refresh session (HTTP \(status))")
        }
        try apply(tokenResponse: data)
    }

    // MARK: - Helpers
    private func tokenRequest(path: String, body: [String: String]) async throws -> Data {
        var req = URLRequest(url: URL(string: "\(API.supabaseURL)/auth/v1/\(path)")!)
        req.httpMethod = "POST"
        req.setValue(API.supabaseKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw ClinicalError.server(Self.authError(data) ?? "Sign-in failed (HTTP \(status))")
        }
        return data
    }

    private func apply(tokenResponse data: Data) throws {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String else {
            throw ClinicalError.server("Malformed auth response")
        }
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        let user = json["user"] as? [String: Any]
        accessToken = access
        refreshToken = refresh
        expiresAt = Date().timeIntervalSince1970 + expiresIn
        uid = user?["id"] as? String ?? uid
        email = user?["email"] as? String ?? email
        Keychain.save(access, key: "sb_access_token")
        Keychain.save(refresh, key: "sb_refresh_token")
        Keychain.save(String(expiresAt), key: "sb_expires_at")
        Keychain.save(email, key: "sb_email")
        if let u = uid { Keychain.save(u, key: "sb_uid") }
        isSignedIn = true
    }

    private static func authError(_ data: Data) -> String? {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["error_description"] as? String) ?? (json?["msg"] as? String) ?? (json?["message"] as? String)
    }
}
