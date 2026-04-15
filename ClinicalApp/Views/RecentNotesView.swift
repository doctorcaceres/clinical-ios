import SwiftUI

struct RecentNotesView: View {
    @EnvironmentObject var app: AppState
    @State private var encounters: [Encounter] = []
    @State private var loading = true
    @State private var deleteTarget: Encounter?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button { app.home() } label: {
                    Image(systemName: "chevron.left")
                        .foregroundColor(C.textMuted)
                }
                Spacer()
                Text("RECENT NOTES")
                    .font(.system(size: 16, weight: .semibold))
                    .tracking(2)
                    .foregroundColor(C.text)
                Spacer()
                Color.clear.frame(width: 24)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            if loading {
                Spacer()
                ProgressView().tint(C.accent)
                Spacer()
            } else if encounters.isEmpty {
                Spacer()
                Text("No encounters yet")
                    .font(.system(size: 15))
                    .foregroundColor(C.textDim)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(encounters) { enc in
                            encounterRow(enc)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
                .refreshable { await load() }
            }
        }
        .background(C.bg.ignoresSafeArea())
        .navigationBarHidden(true)
        .task { await load() }
        .alert("Delete this encounter?", isPresented: .init(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let e = deleteTarget { Task { await delete(e) } }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        }
    }

    // MARK: - Row
    private func encounterRow(_ enc: Encounter) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(enc.displayType)
                    .font(.system(size: 11, weight: .medium))
                    .tracking(1)
                    .textCase(.uppercase)
                    .foregroundColor(C.accent)

                if enc.isProcessing {
                    Text("• Processing")
                        .font(.system(size: 11))
                        .foregroundColor(C.textMuted)
                }
                if enc.isError {
                    Text("• Error")
                        .font(.system(size: 11))
                        .foregroundColor(C.error)
                }
                if enc.isFinalized {
                    Text("• Finalized")
                        .font(.system(size: 11))
                        .foregroundColor(C.accent)
                }

                Spacer()

                Text(enc.displayDate)
                    .font(.system(size: 12))
                    .foregroundColor(C.textDim)
            }

            // Chief concern preview
            if let cc = enc.chiefConcern, !cc.isEmpty {
                Text(cc)
                    .font(.system(size: 13))
                    .foregroundColor(C.textMuted)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                if enc.hasNote {
                    Button { app.push(.noteReview(enc)) } label: {
                        Text("Open")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(C.accent)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.accent, lineWidth: 1))
                    }
                    .buttonStyle(PressStyle())
                }

                if enc.isError {
                    Button { retry(enc) } label: {
                        Text("Retry")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(C.warning)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.warning, lineWidth: 1))
                    }
                    .buttonStyle(PressStyle())
                }

                Spacer()

                Button { deleteTarget = enc } label: {
                    Text("Delete")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(C.error)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.error.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(14)
        .background(C.surface)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.border, lineWidth: 1))
    }

    // MARK: - Actions
    private func load() async {
        loading = true
        encounters = (try? await DB.shared.encounters()) ?? []
        loading = false
    }

    private func delete(_ enc: Encounter) async {
        try? await DB.shared.delete(id: enc.id)
        encounters.removeAll { $0.id == enc.id }
    }

    private func retry(_ enc: Encounter) {
        Task {
            try? await APIService.generateNote(
                encounterId: enc.id,
                encounterType: enc.encounterType,
                anthropicKey: app.anthropicKey
            )
            try? await DB.shared.update(id: enc.id, fields: ["status": "processing"])
            await load()
        }
    }
}
