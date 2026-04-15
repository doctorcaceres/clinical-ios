import SwiftUI

struct SetupView: View {
    @EnvironmentObject var app: AppState
    @State private var key = ""
    @State private var testResult = ""
    @State private var showTest = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ClinicalTitle().padding(.bottom, 40)

            Text("SETUP")
                .font(.system(size: 12, weight: .medium))
                .tracking(3)
                .foregroundColor(C.textMuted)
                .padding(.bottom, 24)

            // --- Network test button ---
            Button {
                Task {
                    testResult = "Testing..."
                    showTest = true
                    testResult = await APIService.networkTest()
                }
            } label: {
                Text("Test Server Connection")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(C.accent)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 20)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(C.accent, lineWidth: 1))
            }
            .buttonStyle(PressStyle())
            .padding(.bottom, 24)

            VStack(alignment: .leading, spacing: 6) {
                Text("Anthropic API Key")
                    .font(.system(size: 12))
                    .foregroundColor(C.textMuted)

                SecureField("sk-ant-...", text: $key)
                    .font(.system(size: 15))
                    .padding(14)
                    .background(C.surface)
                    .foregroundColor(C.text)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.borderPri, lineWidth: 2))
                    .cornerRadius(12)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .frame(maxWidth: 320)
            .padding(.bottom, 32)

            Button {
                let trimmed = key.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                app.setup(key: trimmed)
            } label: {
                Text("Get Started")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(C.bg)
                    .frame(maxWidth: 320)
                    .padding(.vertical, 14)
                    .background(key.trimmingCharacters(in: .whitespaces).isEmpty ? C.borderPri : C.accent)
                    .cornerRadius(12)
            }
            .buttonStyle(PressStyle())

            Spacer()

            Text("Stored securely in the iOS Keychain.\nAll other API keys live on the server.")
                .font(.system(size: 12))
                .foregroundColor(C.textDark)
                .multilineTextAlignment(.center)
                .padding(.bottom, 32)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.bg.ignoresSafeArea())
        .alert("Network Test", isPresented: $showTest) {
            Button("OK") {}
        } message: {
            Text(testResult)
        }
    }
}
