import SwiftUI

/// Chat-based style refinement (Training Mode Path 2).
struct TrainingChatView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var rec = AudioRecorder.shared

    @State private var messages: [ChatMsg] = []
    @State private var inputText = ""
    @State private var isSending = false
    @State private var isTranscribing = false
    @State private var pulse = false
    @State private var ruleCount = 0

    struct ChatMsg: Identifiable {
        let id = UUID()
        let role: String    // "user" or "assistant"
        let content: String
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar — back saves the session summary and pops
            HStack {
                Button { endSession() } label: {
                    Image(systemName: "chevron.left")
                        .foregroundColor(C.textMuted)
                        .font(.system(size: 16))
                }
                .buttonStyle(PressStyle())
                Spacer()
                Text("TRAINING")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(2)
                    .foregroundColor(C.warning)
                Spacer()
                Color.clear.frame(width: 24, height: 1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Rule count banner
            if ruleCount > 0 {
                Text("\(ruleCount) rule\(ruleCount == 1 ? "" : "s") active")
                    .font(.system(size: 11))
                    .foregroundColor(C.accent)
                    .padding(.vertical, 4)
            }

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if messages.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "bubble.left.and.bubble.right.fill")
                                    .font(.system(size: 28))
                                    .foregroundColor(C.accent.opacity(0.6))
                                Text("I'm your Clinical companion.")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(C.text)
                                Text("Tell me how you want your notes written — every preference becomes a rule for future notes. You can also ask me how the app works, or anything about your documentation.")
                                    .font(.system(size: 14))
                                    .foregroundColor(C.textMuted)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 12)
                                Text("Type below, or tap the mic to dictate.")
                                    .font(.system(size: 13))
                                    .foregroundColor(C.textDim)
                            }
                            .padding(.top, 48)
                        }

                        ForEach(messages) { msg in
                            chatBubble(msg)
                                .id(msg.id)
                        }

                        if isSending {
                            HStack {
                                ProgressView()
                                    .tint(C.textMuted)
                                    .scaleEffect(0.6)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .id("loading")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .onChange(of: messages.count) { _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            // Input bar
            HStack(spacing: 10) {
                TextField("Type a style instruction...", text: $inputText, axis: .vertical)
                    .font(.system(size: 15))
                    .foregroundColor(C.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(hex: 0x1A1A1A))
                    .cornerRadius(12)
                    .lineLimit(1...4)
                    .submitLabel(.send)
                    .onSubmit { sendMessage() }

                // Mic button (voice dictation)
                micButton

                // Send button
                Button { sendMessage() } label: {
                    Text("Send")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(sendDisabled ? C.textDim : C.accent)
                }
                .buttonStyle(PressStyle())
                .disabled(sendDisabled)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(C.bg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.bg.ignoresSafeArea())
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Mic button — prominent: dictation is a first-class input method
    private var micButton: some View {
        Button { toggleMic() } label: {
            ZStack {
                // Pulsing ring while recording
                if rec.isRecording {
                    Circle()
                        .fill(C.accent.opacity(0.25))
                        .frame(width: 54, height: 54)
                        .scaleEffect(pulse ? 1.3 : 0.85)
                        .opacity(pulse ? 0.3 : 0.7)
                }

                // Base circle — filled accent when idle so the mic stands out
                Circle()
                    .fill(rec.isRecording ? C.error : C.accent)
                    .frame(width: 48, height: 48)

                // Icon (changes to stop while recording; spinner while transcribing)
                if isTranscribing {
                    ProgressView().tint(C.bg).scaleEffect(0.8)
                } else {
                    Image(systemName: rec.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(C.bg)
                }
            }
            .frame(width: 54, height: 54)
        }
        .buttonStyle(PressStyle())
        .disabled(isTranscribing || isSending)
        .onChange(of: rec.isRecording) { recording in
            if recording {
                // Start pulsing — autoreverses bounces between scaleEffect values forever
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            } else {
                // Stop pulsing
                withAnimation(.easeOut(duration: 0.2)) {
                    pulse = false
                }
            }
        }
    }

    private var sendDisabled: Bool {
        inputText.trimmingCharacters(in: .whitespaces).isEmpty || isSending || isTranscribing
    }

    // MARK: - Chat bubble
    @ViewBuilder
    private func chatBubble(_ msg: ChatMsg) -> some View {
        if msg.role == "user" {
            HStack {
                Spacer()
                Text(msg.content)
                    .font(.system(size: 15))
                    .foregroundColor(C.text)
                    .multilineTextAlignment(.trailing)
            }
        } else {
            HStack {
                Text(msg.content)
                    .font(.system(size: 15))
                    .foregroundColor(Color(hex: 0xCCCCCC))
                    .padding(12)
                    .background(Color(hex: 0x1A1A1A))
                    .cornerRadius(12)
                Spacer()
            }
        }
    }

    // MARK: - Voice dictation
    private func toggleMic() {
        if rec.isRecording {
            // Stop (merges segments if a call interrupted the dictation), then transcribe
            isTranscribing = true
            Task {
                guard let url = await rec.stop() else {
                    messages.append(ChatMsg(role: "assistant", content: "Voice capture failed — nothing was recorded."))
                    isTranscribing = false
                    return
                }
                do {
                    let raw = try await APIService.transcribe(fileURL: url)
                    let cleaned = stripSpeakerLabels(raw)
                    if inputText.isEmpty {
                        inputText = cleaned
                    } else {
                        inputText = inputText.trimmingCharacters(in: .whitespaces) + " " + cleaned
                    }
                } catch {
                    messages.append(ChatMsg(role: "assistant", content: "Voice transcription failed: \(error.localizedDescription)"))
                }
                isTranscribing = false
            }
        } else {
            // Start recording
            Task { try? await rec.start() }
        }
    }

    // MARK: - End session (summarize + save)
    private func endSession() {
        // If dictation is active, discard it — user is bailing (no merge needed)
        if rec.isRecording { rec.reset() }

        // Fire-and-forget summary save if there was any exchange
        if !messages.isEmpty {
            let history = messages.map { ["role": $0.role, "content": $0.content] }
            // TODO: Replace with authenticated user_id
            let uid = app.userId
            Task.detached {
                await APIService.saveChatSession(userId: uid, history: history)
            }
        }
        dismiss()
    }

    // MARK: - Send message
    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !isSending else { return }

        inputText = ""
        messages.append(ChatMsg(role: "user", content: text))
        isSending = true

        Task {
            do {
                // Build conversation history for the API
                let history = messages.dropLast().map { ["role": $0.role, "content": $0.content] }

                // TODO: Replace with authenticated user_id
                let response = try await APIService.trainingChat(
                    userId: app.userId,
                    message: text,
                    history: history
                )

                messages.append(ChatMsg(role: "assistant", content: response.text))
                ruleCount = response.ruleCount
            } catch {
                messages.append(ChatMsg(role: "assistant", content: "Error: \(error.localizedDescription)"))
            }
            isSending = false
        }
    }
}
