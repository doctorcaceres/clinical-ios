import SwiftUI

struct NoteReviewView: View {
    @EnvironmentObject var app: AppState
    let encounter: Encounter

    @State private var note: [String: String] = [:]
    @State private var editingSection: EditingSection?
    @State private var editText = ""
    @State private var banner = ""

    private let sectionOrder = [
        "Chief Concern", "History of Present Illness", "Review of Systems",
        "Past Medical History", "Family History", "Birth History",
        "Developmental History", "Social History", "Physical Examination",
        "Video Evaluation", "Assessment", "Plan",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Button { app.home() } label: {
                        Image(systemName: "chevron.left")
                            .foregroundColor(C.textMuted)
                            .font(.system(size: 16))
                    }
                    .buttonStyle(PressStyle())
                    Spacer()
                    VStack(spacing: 2) {
                        Text(encounter.displayType)
                            .font(.system(size: 11, weight: .medium))
                            .tracking(1)
                            .textCase(.uppercase)
                            .foregroundColor(C.accent)
                        Text("\(encounter.displayDate)  •  \(formatElapsed(encounter.elapsed ?? 0))")
                            .font(.system(size: 12))
                            .foregroundColor(C.textDim)
                    }
                    Spacer()
                    Color.clear.frame(width: 24)
                }

                // Banner
                if !banner.isEmpty {
                    Text(banner)
                        .font(.system(size: 13))
                        .foregroundColor(C.accent)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(C.accentBg)
                }

                // Sections
                ForEach(orderedSections, id: \.0) { key, content in
                    NoteSection(title: key, content: content) {
                        editingSection = EditingSection(key: key)
                        editText = content
                    }
                }

                // Bottom bar
                HStack(spacing: 10) {
                    Button { app.home() } label: {
                        Text("New")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(C.textMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.borderPri, lineWidth: 1))
                    }
                    .buttonStyle(PressStyle())

                    Button { saveFinal() } label: {
                        Text("Save Final")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(C.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.accent, lineWidth: 1))
                    }
                    .buttonStyle(PressStyle())

                    Button { copyToClipboard() } label: {
                        Text("Copy")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(C.bg)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(C.accent)
                            .cornerRadius(12)
                    }
                    .buttonStyle(PressStyle())
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(C.bg)
        .navigationBarHidden(true)
        .onAppear { note = encounter.finalNote ?? encounter.originalNote ?? [:] }
        .sheet(item: $editingSection) { section in
            SectionEditor(title: section.key, text: $editText, onSave: {
                note[section.key] = editText
                editingSection = nil
            }, onCancel: {
                editingSection = nil
            })
        }
    }

    private var orderedSections: [(String, String)] {
        var result: [(String, String)] = []
        for key in sectionOrder {
            if let c = note[key], !c.isEmpty { result.append((key, c)) }
        }
        for (k, v) in note where !sectionOrder.contains(k) && !v.isEmpty {
            result.append((k, v))
        }
        return result
    }

    private func saveFinal() {
        Task {
            do {
                // Write note as a dictionary (jsonb object), NOT a JSON-encoded string.
                // The previous string-encoded form breaks decoders expecting [String: String].
                try await DB.shared.update(id: encounter.id, fields: [
                    "final_note": note,
                    "status": "finalized",
                ])
                withAnimation { banner = "Saved. Clinical is learning from your edits." }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation { banner = "" }
                }

                // Silent style learning: compare original AI note with doctor's edits
                // Fire-and-forget — no UI, no confirmation, no error display
                if let originalNote = encounter.originalNote {
                    let editedNote = note
                    // TODO: Replace with authenticated user_id
                    let uid = app.userId
                    let key = app.anthropicKey
                    Task.detached {
                        await APIService.extractCorrections(
                            userId: uid,
                            originalNote: originalNote,
                            editedNote: editedNote,
                            anthropicKey: key
                        )
                    }
                }
            } catch {
                banner = "Save failed: \(error.localizedDescription)"
            }
        }
    }

    private func copyToClipboard() {
        let text = orderedSections.map { "\($0.0)\n\($0.1)" }.joined(separator: "\n\n")
        UIPasteboard.general.string = text
        withAnimation { banner = "Copied to clipboard" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { banner = "" } }
    }
}
