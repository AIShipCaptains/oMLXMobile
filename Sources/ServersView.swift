import SwiftUI
import SwiftData

struct ServersView: View {
    @EnvironmentObject private var profiles: ProfileStore
    @State private var editing: ServerProfile?
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            List {
                if profiles.profiles.isEmpty {
                    ContentUnavailableView(
                        "No servers",
                        systemImage: "server.rack",
                        description: Text("Add your oMLX server. Works over Tailscale, LAN, or any OpenAI-compatible endpoint (LM Studio, llama.cpp, Ollama…).")
                    )
                }
                ForEach(profiles.profiles) { profile in
                    Button {
                        editing = profile
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(profile.name).fontWeight(.semibold)
                                    if profiles.activeProfile?.id == profile.id {
                                        Text("ACTIVE")
                                            .font(.caption2).bold()
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Color.accentColor.opacity(0.25))
                                            .clipShape(Capsule())
                                    }
                                }
                                Text(profile.baseURL)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if !profile.defaultModel.isEmpty {
                                    Text(profile.defaultModel)
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            if profiles.activeProfile?.id != profile.id {
                                Image(systemName: "circle")
                                    .foregroundStyle(.tertiary)
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete { indexSet in
                    let targets = indexSet.map { profiles.profiles[$0] }
                    for profile in targets {
                        profiles.remove(profile)
                    }
                }
            }
            .navigationTitle("Servers")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { isAdding = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $isAdding) {
                ServerEditor(profile: ServerProfile(name: "", baseURL: ""))
            }
            .sheet(item: $editing) { profile in
                ServerEditor(profile: profile)
            }
        }
    }
}

// MARK: - Editor

struct ServerEditor: View {
    @EnvironmentObject private var profiles: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State var profile: ServerProfile
    @State private var apiKey = ""
    @State private var fetchedModels: [String] = []
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var healthBody: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Name (e.g. Mac Studio)", text: $profile.name)
                    TextField("Base URL", text: $profile.baseURL, prompt: Text("https://mymac.tailnet123.ts.net"))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Default model") {
                    if fetchedModels.isEmpty {
                        TextField("Model ID", text: $profile.defaultModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        Picker("Model", selection: $profile.defaultModel) {
                            if profile.defaultModel.isEmpty {
                                Text("None").tag("")
                            }
                            ForEach(fetchedModels, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }

                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Label("Test connection", systemImage: "bolt.horizontal")
                            if isTesting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(profile.name.isEmpty || profile.baseURL.isEmpty || isTesting)

                    if let testResult {
                        let ok = testResult.hasPrefix("OK")
                        HStack(spacing: 6) {
                            Image(systemName: ok ? "checkmark.circle" : "xmark.circle")
                            Text(testResult)
                        }
                        .foregroundStyle(ok ? Color.green : Color.red)
                        .font(.footnote)
                    }
                    if let healthBody {
                        Text(healthBody)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(8)
                    }
                } header: {
                    Text("Verify")
                } footer: {
                    Text("oMLX example: https://mymac.tailnet123.ts.net (key from the oMLX app). LM Studio: http://<ip>:1234. Ollama: http://<ip>:11434.")
                }
            }
            .navigationTitle(profiles.profiles.contains { $0.id == profile.id } ? "Edit server" : "New server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmedURL = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedURL.isEmpty else { return }
                        profile.baseURL = trimmedURL
                        profiles.upsert(profile)
                        profiles.activeProfileID = profile.id
                        if !apiKey.isEmpty {
                            Keychain.set(apiKey, account: profile.id.uuidString)
                        }
                        dismiss()
                    }
                    .disabled(profile.name.isEmpty || profile.baseURL.isEmpty)
                }
            }
            .onAppear {
                if let existing = Keychain.get(account: profile.id.uuidString) {
                    apiKey = existing
                }
            }
        }
    }

    private func testConnection() async {
        isTesting = true
        testResult = nil
        healthBody = nil
        defer { isTesting = false }

        guard let base = profile.normalizedBaseURL else {
            testResult = "Invalid URL"
            return
        }
        let client = APIClient(base: base, apiKey: apiKey.isEmpty ? Keychain.get(account: profile.id.uuidString) : apiKey)

        do {
            let models = try await client.listModels().sorted()
            fetchedModels = models
            if profile.defaultModel.isEmpty, let first = models.first {
                profile.defaultModel = first
            }
            testResult = "OK — \(models.count) model(s) found"
        } catch {
            testResult = "Failed: \(error.localizedDescription)"
            return
        }

        if let health = try? await client.health() {
            healthBody = "HTTP \(health.statusCode)\n\(health.body)"
        }
    }
}