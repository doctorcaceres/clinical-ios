import SwiftUI

/// Chat-based style refinement (Training Mode Path 2).
struct TrainingChatView: View {
    @EnvironmentObject var app: AppState

    @State private var messages: [ChatMsg] = []
    @State private var inputText = ""
    @State private var isSending = false
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
                Button { app.home() } label: {
                    Text("Done")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: 0x888888))
                }
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
            HStack(spacing: 8) {
                TextField("Type a style instruction...", text: $inputText)
                    .font(.system(size: 15))
                    .foregroundColor(C.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(hex: 0x1A1A1A))
                    .cornerRadius(12)
                    .submitLabel(.send)
                    .onSubmit { sendMessage() }

                Button { sendMessage() } label: {
                    Text("Send")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(inputText.trimmingCharacters(in: .whitespaces).isEmpty || isSending ? C.textDim : C.accent)
                }
                .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || isSending)
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
