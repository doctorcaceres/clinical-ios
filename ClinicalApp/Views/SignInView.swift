import SwiftUI

/// Sign-in gate. Accounts are created by invitation (Supabase dashboard) —
/// there is deliberately no sign-up UI.
struct SignInView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var auth = AuthService.shared

    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var errorMsg = ""
    @State private var infoMsg = ""

    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && !busy
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ClinicalTitle().padding(.bottom, 40)

            VStack(spacing: 12) {
                TextField("Email", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .font(.system(size: 15))
                    .padding(14)
                    .background(C.surface)
                    .foregroundColor(C.text)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.borderPri, lineWidth: 2))
                    .cornerRadius(12)

                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .font(.system(size: 15))
                    .padding(14)
                    .background(C.surface)
                    .foregroundColor(C.text)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.borderPri, lineWidth: 2))
                    .cornerRadius(12)
                    .onSubmit { signIn() }
            }
            .frame(maxWidth: 320)

            if !errorMsg.isEmpty {
                Text(errorMsg)
                    .font(.system(size: 13))
                    .foregroundColor(C.error)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                    .padding(.top, 12)
            }
            if !infoMsg.isEmpty {
                Text(infoMsg)
                    .font(.system(size: 13))
                    .foregroundColor(C.accent)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                    .padding(.top, 12)
            }

            Button { signIn() } label: {
                HStack(spacing: 8) {
                    if busy { ProgressView().tint(C.bg).scaleEffect(0.8) }
                    Text(busy ? "Signing in..." : "Sign In")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(canSubmit || busy ? C.bg : C.textDim)
                }
                .frame(maxWidth: 320)
                .padding(.vertical, 14)
                .background(canSubmit || busy ? C.accent : C.borderPri)
                .cornerRadius(12)
            }
            .buttonStyle(PressStyle())
            .disabled(!canSubmit)
            .padding(.top, 20)

            Button { recover() } label: {
                Text("Forgot password?")
                    .font(.system(size: 13))
                    .foregroundColor(C.textMuted)
            }
            .buttonStyle(PressStyle())
            .padding(.top, 16)

            Spacer()

            Text("Accounts are created by invitation.\nContact your administrator for access.")
                .font(.system(size: 12))
                .foregroundColor(C.textDark)
                .multilineTextAlignment(.center)
                .padding(.bottom, 32)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.bg.ignoresSafeArea())
    }

    private func signIn() {
        guard canSubmit else { return }
        busy = true; errorMsg = ""; infoMsg = ""
        Task {
            do {
                try await AuthService.shared.signIn(
                    email: email.trimmingCharacters(in: .whitespaces),
                    password: password
                )
                password = ""
                await app.evaluateWelcome()
            } catch {
                errorMsg = error.localizedDescription
            }
            busy = false
        }
    }

    private func recover() {
        let addr = email.trimmingCharacters(in: .whitespaces)
        guard !addr.isEmpty else {
            errorMsg = "Enter your email first, then tap Forgot password."
            return
        }
        errorMsg = ""; infoMsg = ""
        Task {
            do {
                try await AuthService.shared.recover(email: addr)
                infoMsg = "Password reset email sent. Open the link in the email to set a new password, then sign in here."
            } catch {
                errorMsg = error.localizedDescription
            }
        }
    }
}
