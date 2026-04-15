import SwiftUI

/// Single note section display — tap to edit.
struct NoteSection: View {
    let title: String
    let content: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(C.accent)

                Text(content)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(C.textSec)
                    .lineSpacing(4)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(C.surface)
            .cornerRadius(12)
        }
        .buttonStyle(PressStyle())
    }
}
