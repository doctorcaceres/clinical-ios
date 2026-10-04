import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var auth = AuthService.shared
    @State private var confirmSignOut = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                BackButton { dismiss() }
                Spacer()
                Text("SETTINGS")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(2)
                    .foregroundColor(C.text)
                Spacer()
                Color.clear.frame(width: 44, height: 1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SIGNED IN AS")
                        .font(.system(size: 11, weight: .medium))
                        .tracking(1)
                        .foregroundColor(C.textDim)
                    Text(auth.email.isEmpty ? "—" : auth.email)
                        .font(.system(size: 15))
                        .foregroundColor(C.textSec)
                }

                Button { confirmSignOut = true } label: {
                    Text("Sign Out")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(C.error)
                        .frame(maxWidth: 320)
                        .padding(.vertical, 14)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.error, lineWidth: 1))
                }
                .buttonStyle(PressStyle())

                Text("Notes and style learning are tied to this account. Signing out does not delete anything.")
                    .font(.system(size: 12))
                    .foregroundColor(C.textDark)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.bg.ignoresSafeArea())
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .alert("Sign out?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) {
                AuthService.shared.signOut()
                app.home()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
