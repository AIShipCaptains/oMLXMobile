import Foundation
import SwiftData
import Combine

// MARK: - Server profiles (connection configs, keys live in Keychain)

struct ServerProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var baseURL: String        // e.g. https://mymac.tailnet.ts.net or http://192.168.1.10:8000
    var defaultModel: String = ""
    var createdAt: Date = Date()

    var normalizedBaseURL: URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var s = trimmed
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }
}

@MainActor
final class ProfileStore: ObservableObject {
    private static let storageKey = "omlxmobile.profiles"
    private static let activeKey = "omlxmobile.activeProfile"

    @Published var profiles: [ServerProfile] = [] {
        didSet { persist() }
    }
    @Published var activeProfileID: UUID? {
        didSet {
            UserDefaults.standard.set(activeProfileID?.uuidString, forKey: Self.activeKey)
        }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            profiles = decoded
        }
        if let raw = UserDefaults.standard.string(forKey: Self.activeKey) {
            activeProfileID = UUID(uuidString: raw)
        }
        if activeProfileID == nil {
            activeProfileID = profiles.first?.id
        }
    }

    var activeProfile: ServerProfile? {
        profiles.first { $0.id == activeProfileID } ?? profiles.first
    }

    func upsert(_ profile: ServerProfile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        if activeProfileID == nil { activeProfileID = profile.id }
    }

    func remove(_ profile: ServerProfile) {
        profiles.removeAll { $0.id == profile.id }
        Keychain.delete(account: profile.id.uuidString)
        if activeProfileID == profile.id { activeProfileID = profiles.first?.id }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

// MARK: - Chat history (SwiftData)

@Model
final class Conversation {
    var title: String = "New chat"
    var model: String = ""
    var serverID: UUID?
    var createdAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.conversation)
    var messages: [ChatMessage] = []

    init(title: String = "New chat", model: String = "", serverID: UUID? = nil) {
        self.title = title
        self.model = model
        self.serverID = serverID
    }
}

@Model
final class ChatMessage {
    var role: String          // "user" | "assistant" | "system"
    var content: String = ""
    var createdAt: Date = Date()
    var conversation: Conversation?

    init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}