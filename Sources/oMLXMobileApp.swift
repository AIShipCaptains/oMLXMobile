import SwiftUI
import SwiftData

@main
struct oMLXMobileApp: App {
    @StateObject private var profiles = ProfileStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(profiles)
                .modelContainer(for: Conversation.self)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var profiles: ProfileStore
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        TabView {
            ChatView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.text.bubble.right") }
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "gauge.with.needle") }
            ServersView()
                .tabItem { Label("Servers", systemImage: "server.rack") }
        }
        .task { DemoSeed.seedIfNeeded(profiles: profiles, context: modelContext) }
    }
}

/// Seeds demo content when launched with `-UITEST_DEMO` (screenshots, previews).
enum DemoSeed {
    @MainActor
    static func seedIfNeeded(profiles: ProfileStore, context: ModelContext) {
        guard ProcessInfo.processInfo.arguments.contains("-UITEST_DEMO"),
              profiles.profiles.isEmpty else { return }

        var profile = ServerProfile(name: "Mac Studio", baseURL: "https://mymac.tailnet123.ts.net")
        profile.defaultModel = "GLM-5.3-Flash-mixed-4_8bit"
        profiles.upsert(profile)
        profiles.activeProfileID = profile.id

        let convo = Conversation(title: "Why did the build fail?", model: profile.defaultModel, serverID: profile.id)
        context.insert(convo)

        let user = ChatMessage(role: "user", content: "The simulator build failed after I added the Dashboard tab — what broke?")
        let answer = """
        The type-checker crashed on **ServersView.swift**, not on the new tab. Two real bugs:

        - `profiles[i]` — invalid subscript on `ProfileStore` (no subscript exists)
        - a `Binding` helper defined on the wrong specialization

        Both fixed — next run: **BUILD SUCCEEDED** ✅
        """
        let assistant = ChatMessage(role: "assistant", content: answer)
        context.insert(user)
        context.insert(assistant)
        user.conversation = convo
        assistant.conversation = convo
    }
}