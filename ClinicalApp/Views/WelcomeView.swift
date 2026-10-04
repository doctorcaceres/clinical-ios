import SwiftUI

/// One-screen onboarding for a doctor signing in for the first time with an
/// empty profile: point to Training Mode and explain that the first few
/// Save Finals teach the app their style.
struct WelcomeView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("WELCOME TO CLINICAL")
                .font(.system(size: 12, weight: .semibold))
                .tracking(2)
                .foregroundColor(C.accent)
                .padding(.bottom, 14)

            Text("Your notes, in your voice.")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(C.text)
                .padding(.bottom, 18)

            Text("Record an encounter and Clinical writes the note. Your profile starts empty — two ways to teach it your style:")
                .font(.system(size: 14))
                .foregroundColor(C.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 330)
                .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    Text("1.").font(.system(size: 14, weight: .semibold)).foregroundColor(C.warning)
                    Text("**Training Mode** — tell the assistant how you write. Every preference becomes a rule.")
                        .font(.system(size: 14)).foregroundColor(C.textSec)
                }
                HStack(alignment: .top, spacing: 8) {
                    Text("2.").font(.system(size: 14, weight: .semibold)).foregroundColor(C.accent)
                    Text("**Save Final** — your first few edited notes teach it automatically.")
                        .font(.system(size: 14)).foregroundColor(C.textSec)
                }
            }
            .frame(maxWidth: 330, alignment: .leading)

            Button { app.dismissWelcome() } label: {
                Text("Get Started")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(C.bg)
                    .frame(maxWidth: 300)
                    .padding(.vertical, 14)
                    .background(C.accent)
                    .cornerRadius(12)
            }
            .buttonStyle(PressStyle())
            .padding(.top, 28)

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.bg.ignoresSafeArea())
    }
}
