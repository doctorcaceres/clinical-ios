import SwiftUI

/// One-screen onboarding for a doctor signing in for the first time with an
/// empty profile. Two action buttons route straight into the two ways of
/// teaching Clinical their style; "Skip for now" goes to Home.
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

            Text("Record an encounter and Clinical writes the note. Your profile starts empty. Two ways to teach it your style:")
                .font(.system(size: 14))
                .foregroundColor(C.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 330)
                .padding(.bottom, 28)

            VStack(spacing: 6) {
                Button {
                    app.dismissWelcome()
                    app.push(.trainingChat)
                } label: {
                    Text("Start a training session")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(C.bg)
                        .frame(maxWidth: 300)
                        .padding(.vertical, 14)
                        .background(C.accent)
                        .cornerRadius(12)
                }
                .buttonStyle(PressStyle())

                Text("Tell it how you write. Every preference becomes a rule.")
                    .font(.system(size: 12))
                    .foregroundColor(C.textDim)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                    .padding(.bottom, 14)

                Button {
                    app.dismissWelcome()
                    app.push(.recording("new"))
                } label: {
                    Text("Record your first encounter")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(C.text)
                        .frame(maxWidth: 300)
                        .padding(.vertical, 14)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.borderPri, lineWidth: 2))
                }
                .buttonStyle(PressStyle())

                Text("Edit the note and save it. Your edits teach it automatically.")
                    .font(.system(size: 12))
                    .foregroundColor(C.textDim)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            Button { app.dismissWelcome() } label: {
                Text("Skip for now")
                    .font(.system(size: 13))
                    .foregroundColor(C.textMuted)
            }
            .buttonStyle(PressStyle())
            .padding(.top, 24)

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.bg.ignoresSafeArea())
    }
}
