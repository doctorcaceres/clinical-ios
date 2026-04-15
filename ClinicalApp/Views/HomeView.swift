import SwiftUI

struct HomeView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ClinicalTitle()
                .padding(.bottom, 48)

            VStack(spacing: 14) {
                // New Patient
                primaryButton("New Patient") { app.push(.recording("new")) }

                // Follow Up
                primaryButton("Follow Up") { app.push(.recording("followup")) }

                // ── OR ── divider
                HStack(spacing: 12) {
                    line
                    Text("OR")
                        .font(.system(size: 11))
                        .tracking(2)
                        .foregroundColor(C.textDim)
                    line
                }
                .padding(.vertical, 6)

                // Training Mode
                secondaryButton("Training Mode") { app.push(.recording("training")) }

                // Recent Notes
                secondaryButton("Recent Notes") { app.push(.recentNotes) }
            }
            .frame(maxWidth: 300)

            Spacer()

            // Processing banner
            if app.pendingNoteId != nil {
                Text("Your note is being written...")
                    .font(.system(size: 13))
                    .foregroundColor(C.accent)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(C.accentBg)
                    .cornerRadius(10)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 16)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.bg.ignoresSafeArea())
        .navigationBarHidden(true)
    }

    // MARK: - Button builders
    private func primaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(C.text)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.borderPri, lineWidth: 2))
        }
        .buttonStyle(PressStyle())
    }

    private func secondaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(C.textMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.borderSec, lineWidth: 2))
        }
        .buttonStyle(PressStyle())
    }

    private var line: some View {
        Rectangle().fill(C.borderSec).frame(height: 1)
    }
}
