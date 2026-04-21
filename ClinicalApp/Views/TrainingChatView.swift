import SwiftUI

/// Chat-based style refinement (Training Mode Path 2).
struct TrainingChatView: View {
    @EnvironmentObject var app: AppState
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
            // Top bar
            HStack {
                Button { endSession() } label: {
                    Text("Done")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: 0x888888))
                }
                .buttonStyle(PressStyle())
                Spacer()
                Text("Style Chat")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(C.textMuted)
                Spacer()
                // Balance the layout
                Text("Done").font(.system(size: 14)).foregroundColor(.clear)
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
                            Text("Tell me how you want your notes written.\nI'll extract style rules from your instructions.")
                                .font(.system(size: 14))
                                .foregroundColor(C.textDim)
                                .multilineTextAlignment(.center)
                                .padding(.top, 40)
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

    // MARK: - Mic button
    private var micButton: some View {
        Button { toggleMic() } label: {
            ZStack {
                // Pulsing ring while recording
                if rec.isRecording {
                    Circle()
                        .fill(C.accent.opacity(0.25))
                        .frame(width: 40, height: 40)
                        .scaleEffect(pulse ? 1.3 : 0.85)
                        .opacity(pulse ? 0.3 : 0.7)
                }

                // Base circle
                Circle()
                    .fill(rec.isRecording ? C.accent.opacity(0.15) : Color(hex: 0x1A1A1A))
                    .frame(width: 36, height: 36)

                // Icon (changes to stop while recording; spinner while transcribing)
                if isTranscribing {
                    ProgressView().tint(C.accent).scaleEffect(0.7)
                } else {
                    Image(systemName: rec.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(C.accent)
                }
            }
            .frame(width: 40, height: 40)
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
            // Stop and transcribe
            guard let url = rec.stop() else { return }
            isTranscribing = true
            Task {
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

    /// Deepgram returns "Speaker 0: ..." labels — strip them for single-speaker dictation.
    private func stripSpeakerLabels(_ s: String) -> String {
        let pattern = #"^Speaker \d+:\s*"#
        return s.components(separatedBy: "\n")
            .map { line -> String in
                if let range = line.range(of: pattern, options: .regularExpression) {
                    return String(line[range.upperBound...])
                }
                return line
            }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - End session (summarize + save)
    private func endSession() {
        // If recording is active, stop it without transcribing — user is bailing
        if rec.isRecording { _ = rec.stop() }

        // Fire-and-forget summary save if there was any exchange
        if !messages.isEmpty {
            let history = messages.map { ["role": $0.role, "content": $0.content] }
            // TODO: Replace with authenticated user_id
            let uid = app.userId
            let key = app.anthropicKey
            Task.detached {
                await APIService.saveChatSession(userId: uid, history: history, anthropicKey: key)
            }
        }
        app.home()
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
                    history: history,
                    anthropicKey: app.anthropicKey
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
