import SwiftUI
import SwiftData

@main
struct oMLXMobileApp: App {
    @StateObject private var profiles = ProfileStore()

    var body: some Scene {
        WindowGroup {
            TabView {
                ChatView()
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.text.bubble.right") }
                DashboardView()
                    .tabItem { Label("Dashboard", systemImage: "gauge.with.needle") }
                ServersView()
                    .tabItem { Label("Servers", systemImage: "server.rack") }
            }
            .environmentObject(profiles)
            .modelContainer(for: Conversation.self)
        }
    }
}