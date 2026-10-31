import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var profiles: ProfileStore
    @Environment(\.modelContext) private var modelContext

    @State private var statPairs: [(String, String)] = []
    @State private var usagePairs: [(String, String)] = []
    @State private var models: [AdminModel] = []
    @State private var busyModelID: String?
    @State private var actionMessage: String?
    @State private var confirmRestart = false
    @State private var statsRaw = ""
    @State private var adminAvailable = true
    @State private var isBusy = false

    var body: some View {
        NavigationStack {
            Group {
                if profiles.activeProfile == nil {
                    ContentUnavailableView("No server", systemImage: "server.rack",
                                           description: Text("Add a server first."))
                } else if !adminAvailable {
                    ContentUnavailableView("oMLX admin not available",
                                           systemImage: "nosign",
                                           description: Text("This endpoint doesn't expose the oMLX admin API (or the API key lacks admin rights). Stats and server controls require oMLX."))
                } else {
                    dashboard
                }
            }
            .navigationTitle("Dashboard")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await loadAll() }
            .confirmationDialog(
                "Restart server?",
                isPresented: $confirmRestart, titleVisibility: .visible
            ) {
                Button("Restart now", role: .destructive) { Task { await restart() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All in-flight requests (including running agent sessions) will be dropped, and models reload afterwards.")
            }
            .alert("Result", isPresented: Binding(
                get: { actionMessage != nil },
                set: { if !$0 { actionMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionMessage ?? "")
            }
            .task { await loadAll() }
        }
    }

    private var dashboard: some View {
        List {
            Section("Server controls") {
                Button {
                    confirmRestart = true
                } label: {
                    Label("Restart server", systemImage: "arrow.clockwise.circle")
                        .foregroundStyle(.orange)
                }
                .disabled(isBusy)

                Button {
                    Task {
                        guard let api = client() else { return }
                        await simpleAction("Settings reloaded") { try await api.reloadServer() }
                    }
                } label: {
                    Label("Reload settings", systemImage: "gearshape.arrow.triangle.2.circlepath")
                }
                .disabled(isBusy)

                Button {
                    Task {
                        guard let api = client() else { return }
                        await simpleAction("Hot cache cleared") { try await api.clearHotCache() }
                    }
                } label: {
                    Label("Clear hot cache", systemImage: "trash.slash")
                }
                .disabled(isBusy)
            }

            Section("Stats") {
                if isBusy && statPairs.isEmpty {
                    HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                } else if statPairs.isEmpty {
                    Text("No stats available").foregroundStyle(.secondary)
                } else {
                    ForEach(statPairs, id: \.0) { pair in
                        HStack {
                            Text(pair.0).font(.footnote.monospaced()).foregroundStyle(.secondary)
                            Spacer()
                            Text(pair.1).font(.footnote.monospaced())
                        }
                        .textSelection(.enabled)
                    }
                }
                Button {
                    UIPasteboard.general.string = statsRaw
                    actionMessage = "Raw stats JSON copied"
                } label: {
                    Label("Copy raw JSON", systemImage: "doc.on.doc")
                        .font(.footnote)
                }
            }

            if !usagePairs.isEmpty {
                Section("Usage") {
                    ForEach(usagePairs, id: \.0) { pair in
                        HStack {
                            Text(pair.0).font(.footnote.monospaced()).foregroundStyle(.secondary)
                            Spacer()
                            Text(pair.1).font(.footnote.monospaced())
                        }
                        .textSelection(.enabled)
                    }
                }
            }

            Section("Models on disk") {
                if models.isEmpty {
                    Text("No models reported").foregroundStyle(.secondary)
                }
                ForEach(models) { model in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.name).lineLimit(1)
                            if let size = model.sizeBytes {
                                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .memory))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if model.loaded == true {
                            Text("LOADED")
                                .font(.caption2).bold()
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.green.opacity(0.2))
                                .clipShape(Capsule())
                        }
                        Menu {
                            Button("Load") { Task { await modelAction(model, load: true) } }
                            Button("Unload", role: .destructive) { Task { await modelAction(model, load: false) } }
                        } label: {
                            if busyModelID == model.id {
                                ProgressView()
                            } else {
                                Image(systemName: "ellipsis.circle")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Data loading

    private func client() -> APIClient? {
        guard let profile = profiles.activeProfile, let base = profile.normalizedBaseURL else { return nil }
        return APIClient(base: base, apiKey: Keychain.get(account: profile.id.uuidString))
    }

    private func loadAll() async {
        guard let api = client() else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let stats = try await api.adminStats()
            statsRaw = pretty(stats)
            statPairs = flattenJSON(stats)
        } catch {
            if isNotFound(error) {
                adminAvailable = false
                return
            }
            statPairs = [("error", error.localizedDescription)]
        }

        if let usage = try? await api.adminUsage() {
            usagePairs = flattenJSON(usage)
        } else {
            usagePairs = []
        }

        if let list = try? await api.adminModels() {
            models = list
        }
    }

    private func restart() async {
        guard let api = client() else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await api.restartServer()
            actionMessage = "Restart requested — the server will come back in a few seconds; models reload on demand."
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await loadAll()
        } catch {
            actionMessage = "Restart failed: \(error.localizedDescription)"
        }
    }

    private func simpleAction(_ success: String, _ op: @escaping () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await op()
            actionMessage = success
            await loadAll()
        } catch {
            actionMessage = "Failed: \(error.localizedDescription)"
        }
    }

    private func modelAction(_ model: AdminModel, load: Bool) async {
        guard let api = client() else { return }
        busyModelID = model.id
        defer { busyModelID = nil }
        do {
            if load {
                try await api.loadModel(model.id)
                actionMessage = "Loading \(model.name)…"
            } else {
                try await api.unloadModel(model.id)
                actionMessage = "Unload requested for \(model.name)"
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await loadAll()
        } catch {
            actionMessage = "Failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func isNotFound(_ error: Error) -> Bool {
        if case APIError.http(let status, _) = error { return status == 404 }
        return false
    }

    private func pretty(_ obj: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            return String(decoding: data, as: UTF8.self)
        }
        return String(describing: obj)
    }

    private func flattenJSON(_ obj: Any, prefix: String = "", depth: Int = 0) -> [(String, String)] {
        guard let dict = obj as? [String: Any] else { return [] }
        var out: [(String, String)] = []
        for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
            let fullKey = prefix.isEmpty ? key : prefix + "." + key
            let lower = fullKey.lowercased()
            if lower.contains("api_key") || lower.contains("apikey") || lower.contains("token")
                || lower.contains("secret") || lower.contains("password") || lower.contains("credential") {
                out.append((fullKey, "•••• redacted"))
                continue
            }
            switch value {
            case let nested as [String: Any]:
                if depth < 1 {
                    out += flattenJSON(nested, prefix: fullKey, depth: depth + 1)
                } else {
                    out.append((fullKey, "{\(nested.count) keys}"))
                }
            case let array as [Any]:
                out.append((fullKey, "[\(array.count) items]"))
            case let flag as Bool:
                out.append((fullKey, flag ? "true" : "false"))
            case let number as NSNumber:
                out.append((fullKey, format(number, key: fullKey)))
            case let text as String:
                out.append((fullKey, text))
            default:
                out.append((fullKey, String(describing: value)))
            }
        }
        return out
    }

    private func format(_ number: NSNumber, key: String) -> String {
        let lower = key.lowercased()
        if lower.contains("byte") || (lower.contains("memory") && abs(number.doubleValue) > 1024) {
            return ByteCountFormatter.string(fromByteCount: number.int64Value, countStyle: .memory)
        }
        if floor(number.doubleValue) == number.doubleValue, abs(number.doubleValue) < 1e15 {
            let grouped = number.int64Value
            return grouped.formatted(.number.grouping(.automatic))
        }
        return number.doubleValue.formatted(.number.precision(.fractionLength(1...3)))
    }
}