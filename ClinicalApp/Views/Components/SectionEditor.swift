import SwiftUI

/// Inline section editor — presented as a sheet. Tap section → edit → save.
struct SectionEditor: View {
    let title: String
    @Binding var text: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            TextEditor(text: $text)
                .font(.system(size: 15))
                .foregroundColor(C.text)
                .scrollContentBackground(.hidden)
                .padding()
                .background(C.bg)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                            .foregroundColor(C.textMuted)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onSave)
                            .fontWeight(.semibold)
                            .foregroundColor(C.accent)
                    }
                }
        }
        .preferredColorScheme(.dark)
    }
}
