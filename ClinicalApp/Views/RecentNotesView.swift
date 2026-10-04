import SwiftUI

struct RecentNotesView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var encounters: [Encounter] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var deleteTarget: Encounter?
    @State private var page = 0
    @State private var total = 0

    private let pageSize = 10
    private var pageCount: Int { max(1, Int(ceil(Double(total) / Double(pageSize)))) }

    // Poll every 5s while visible so Processing → Ready updates live
    private let poll = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    BackButton { dismiss() }
                    Spacer()
                    Text("RECENT NOTES")
                        .font(.system(size: 16, weight: .semibold))
                        .tracking(2)
                        .foregroundColor(C.text)
                    Spacer()
                    Color.clear.frame(width: 44)
                }

                if loading {
                    HStack {
                        Spacer()
                        ProgressView().tint(C.accent)
                        Spacer()
                    }
                    .padding(.top, 20)
                } else if let err = loadError {
                    VStack(spacing: 8) {
                        Text("Failed to load encounters")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(C.error)
                        Text(err)
                            .font(.system(size: 12))
                            .foregroundColor(C.textMuted)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(C.errorBg)
                    .cornerRadius(12)
                    .padding(.top, 20)
                } else if encounters.isEmpty {
                    HStack {
                        Spacer()
                        Text("No encounters yet")
                            .font(.system(size: 15))
                            .foregroundColor(C.textDim)
                        Spacer()
                    }
                    .padding(.top, 20)
                } else {
                    ForEach(encounters) { enc in
                        encounterRow(enc)
                    }
                    paginationBar
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(C.bg)
        .navigationBarHidden(true)
        .task { await load() }
        .onReceive(poll) { _ in
            Task { await load(silent: true) }
        }
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

                if showRetry(enc) {
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

    // MARK: - Pagination bar
    private var paginationBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button { changePage(to: page - 1) } label: {
                    Text("Previous")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(page == 0 ? C.textDark : C.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.borderPri, lineWidth: 1))
                }
                .buttonStyle(PressStyle())
                .disabled(page == 0)

                Spacer()

                Button { changePage(to: page + 1) } label: {
                    Text("Next")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(page >= pageCount - 1 ? C.textDark : C.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.borderPri, lineWidth: 1))
                }
                .buttonStyle(PressStyle())
                .disabled(page >= pageCount - 1)
            }

            Text("Page \(page + 1) of \(pageCount)  •  \(total) note\(total == 1 ? "" : "s")")
                .font(.system(size: 12))
                .foregroundColor(C.textDim)
        }
        .padding(.top, 8)
        .padding(.bottom, 24)
    }

    private func changePage(to newPage: Int) {
        let clamped = min(max(0, newPage), pageCount - 1)
        guard clamped != page else { return }
        page = clamped
        Task { await load() }
    }

    private func load(silent: Bool = false) async {
        if !silent { loading = true; loadError = nil }
        do {
            let result = try await DB.shared.encountersPage(page: page, pageSize: pageSize)
            // Page emptied out (deletes) — step back to the last real page
            if result.rows.isEmpty && page > 0 && result.total > 0 {
                page = max(0, Int(ceil(Double(result.total) / Double(pageSize))) - 1)
                let retry = try await DB.shared.encountersPage(page: page, pageSize: pageSize)
                encounters = retry.rows
                total = retry.total
            } else {
                encounters = result.rows
                total = result.total
            }
            if !silent { print("[RecentNotes] Loaded page \(page + 1): \(encounters.count) of \(total) encounters") }
            loadError = nil
            // Clear the home banner once the pending note is ready
            if let pid = app.pendingNoteId,
               let pending = encounters.first(where: { $0.id == pid }),
               pending.hasNote {
                app.pendingNoteId = nil
            }
        } catch {
            print("[RecentNotes] Failed to load encounters: \(error)")
            if !silent {
                loadError = error.localizedDescription
                encounters = []
            }
        }
        if !silent { loading = false }
    }

    /// Retry is shown for errored rows and for rows stuck in "processing"
    /// for over 2 minutes — in both cases only when a transcript exists,
    /// since generate-note cannot succeed without one. Mirrors the web app.
    private func showRetry(_ enc: Encounter) -> Bool {
        guard enc.transcript != nil else { return false }
        if enc.isError { return true }
        guard enc.isProcessing, let iso = enc.updatedAt ?? enc.createdAt else { return false }
        let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime]
        guard let d = f1.date(from: iso) ?? f2.date(from: iso) else { return false }
        return Date().timeIntervalSince(d) > 120
    }

    private func delete(_ enc: Encounter) async {
        try? await DB.shared.delete(id: enc.id)
        encounters.removeAll { $0.id == enc.id }
        // Refill the page from the server and refresh the total
        await load(silent: true)
    }

    private func retry(_ enc: Encounter) {
        Task {
            try? await APIService.generateNote(
                encounterId: enc.id,
                encounterType: enc.encounterType
            )
            try? await DB.shared.update(id: enc.id, fields: ["status": "processing"])
            await load()
        }
    }
}
