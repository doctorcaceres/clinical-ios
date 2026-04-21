import SwiftUI
import Security
import NaturalLanguage

// MARK: - Language detection (for note_embeddings metadata)
func detectLanguage(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "en" }
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(trimmed)
    return recognizer.dominantLanguage?.rawValue ?? "en"
}

// MARK: - Color from hex
extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - Elapsed time formatting
func formatElapsed(_ seconds: Int) -> String {
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    let s = seconds % 60
    return h > 0
        ? String(format: "%d:%02d:%02d", h, m, s)
        : String(format: "%d:%02d", m, s)
}

// MARK: - ISO date formatting
func formatDate(_ iso: String) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var date = f.date(from: iso)
    if date == nil {
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        date = f2.date(from: iso)
    }
    guard let d = date else { return iso }
    let df = DateFormatter()
    df.dateFormat = "MMM d, h:mm a"
    return df.string(from: d)
}

// MARK: - Keychain
enum Keychain {
    static func save(_ value: String, key: String) {
        guard let data = value.data(using: .utf8) else { return }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key, kSecValueData as String: data]
        SecItemDelete(q as CFDictionary)
        SecItemAdd(q as CFDictionary, nil)
    }
    static func load(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Reusable UI
struct ClinicalTitle: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("CLINICAL")
                .font(.system(size: 28, weight: .light))
                .tracking(8)
                .foregroundColor(C.text)
            Rectangle()
                .fill(C.accent)
                .frame(width: 24, height: 2)
                .clipShape(Capsule())
        }
    }
}

/// Instant-feedback button style. No iOS default delay, no highlight tint —
/// just a snappy scale-to-0.97 on press that's visible before the finger lifts.
/// Apply to every Button in the app so the tap response feels web-fast.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())    // reliable tap target covering the label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

// Wrapper for sheet(item:) with strings
struct EditingSection: Identifiable {
    let id = UUID()
    let key: String
}
