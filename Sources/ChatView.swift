import SwiftUI
import SwiftData

struct ChatView: View {
    @EnvironmentObject private var profiles: ProfileStore
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Conversation.createdAt, order: .reverse)
    private var conversations: [Conversation]

    @State private var selectedConversation: Conversation?
    @State private var draft = ""
    @State private var isStreaming = false
    @State private var streamTask: Task<Void, Never>?
    @State private var models: [String] = []
    @State private var errorMessage: String?
    @State private var showHistory = false
    @FocusState private var inputFocused: Bool

    private var activeConversation: Conversation? {
        guard let selectedConversation, !selectedConversation.isDeleted else { return nil }
        return selectedConversation
    }

    var body: some View {
        NavigationStack {
            Group {
                if profiles.activeProfile == nil {
                    ContentUnavailableView(
                        "No server configured",
                        systemImage: "server.rack",
                        description: Text("Add an oMLX (or any OpenAI-compatible) server in the Servers tab first.")
                    )
                } else if let convo = activeConversation {
                    messageList(convo)
                } else {
                    ContentUnavailableView(
                        "oMLX Mobile",
                        systemImage: "bubble.left.and.text.bubble.right",
                        description: Text("Start a new chat with the + button.")
                    )
                }
            }
            .navigationTitle(profiles.activeProfile?.name ?? "oMLX Mobile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(isPresented: $showHistory) { historySheet }
            .alert("Request failed", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear {
                Task { await refreshModels() }
                if activeConversation == nil {
                    selectedConversation = conversations.first
                }
            }
        }
    }

    // MARK: - Message list

    private func messageList(_ convo: Conversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(convo.messages.sorted { $0.createdAt < $1.createdAt }) { msg in
                        MessageBubble(message: msg)
                            .id(msg.id)
                    }
                    if isStreaming {
                        HStack {
                            ProgressView()
                            Text("generating…").font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .onChange(of: convo.messages.map(\.content)) { _, _ in
                if let last = convo.messages.sorted(by: { $0.createdAt < $1.createdAt }).last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .safeAreaInset(edge: .bottom) { inputBar(convo) }
        }
    }

    // MARK: - Input bar

    private func inputBar(_ convo: Conversation) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .focused($inputFocused)
            if isStreaming {
                Button {
                    streamTask?.cancel()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                }
            } else {
                Button {
                    send(in: convo)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button {
                newConversation()
            } label: { Image(systemName: "square.and.pencil") }

            if profiles.activeProfile != nil {
                Menu {
                    if models.isEmpty {
                        Text("No models loaded").foregroundStyle(.secondary)
                    }
                    ForEach(models, id: \.self) { m in
                        Button(m) { setModel(m) }
                    }
                } label: {
                    Text(shortModelName(selectedConversation?.model ?? profiles.activeProfile?.defaultModel ?? "model"))
                }
            }

            Button {
                showHistory = true
            } label: { Image(systemName: "clock.arrow.circlepath") }
        }
    }

    private var historySheet: some View {
        NavigationStack {
            List {
                ForEach(conversations) { convo in
                    Button {
                        selectedConversation = convo
                        showHistory = false
                    } label: {
                        VStack(alignment: .leading) {
                            Text(convo.title).lineLimit(1)
                            Text(convo.createdAt, style: .date)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete { idx in
                    for i in idx {
                        modelContext.delete(conversations[i])
                    }
                    if selectedConversation == nil, let first = conversations.first {
                        selectedConversation = first
                    }
                }
            }
            .navigationTitle("History")
        }
    }

    // MARK: - Actions

    private func newConversation() {
        let convo = Conversation(model: currentModel(), serverID: profiles.activeProfile?.id)
        modelContext.insert(convo)
        selectedConversation = convo
        draft = ""
    }

    private func setModel(_ model: String) {
        guard let convo = activeConversation else { return }
        convo.model = model
    }

    private func currentModel() -> String {
        profiles.activeProfile?.defaultModel ?? models.first ?? ""
    }

    private func shortModelName(_ full: String) -> String {
        full.split(separator: "-").prefix(2).joined(separator: "-")
    }

    private func refreshModels() async {
        guard let profile = profiles.activeProfile,
              let base = profile.normalizedBaseURL else { return }
        let client = APIClient(base: base, apiKey: Keychain.get(account: profile.id.uuidString))
        do { models = try await client.listModels().sorted() } catch { /* keep previous list */ }
    }

    private func send(in convo: Conversation) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let profile = profiles.activeProfile,
              let base = profile.normalizedBaseURL else { return }

        if convo.messages.isEmpty {
            convo.title = String(text.prefix(48))
        }
        convo.model = convo.model.isEmpty ? currentModel() : convo.model

        let userMessage = ChatMessage(role: "user", content: text)
        let assistantMessage = ChatMessage(role: "assistant", content: "")
        modelContext.insert(userMessage)
        modelContext.insert(assistantMessage)
        userMessage.conversation = convo
        assistantMessage.conversation = convo
        draft = ""
        inputFocused = false

        let history = (convo.messages.sorted { $0.createdAt < $1.createdAt })
            .map { APIClient.ChatTurn(role: $0.role, content: $0.content) }

        let client = APIClient(base: base, apiKey: Keychain.get(account: profile.id.uuidString))
        let model = convo.model
        isStreaming = true

        streamTask = Task {
            do {
                for try await delta in client.streamChat(messages: history, model: model) {
                    guard !Task.isCancelled else { break }
                    assistantMessage.content += delta
                }
            } catch is CancellationError {
                // keep partial content
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
            await MainActor.run { isStreaming = false }
        }
    }
}

// MARK: - Bubble

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        let isUser = message.role == "user"
        HStack {
            if isUser { Spacer(minLength: 48) }
            Text(rich(message.content))
                .textSelection(.enabled)
                .padding(12)
                .background(isUser ? Color.accentColor.opacity(0.22) : Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            if !isUser { Spacer(minLength: 48) }
        }
        .padding(.horizontal)
    }

    private func rich(_ content: String) -> AttributedString {
        if let attr = try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return attr
        }
        return AttributedString(content)
    }
}