import SwiftUI

struct RootView: View {
    @EnvironmentObject private var coordinator: DownloadCoordinator
    @State private var selection: Tab = .downloads

    enum Tab: Hashable {
        case downloads
        case library
        case settings
    }

    var body: some View {
        TabView(selection: $selection) {
            DownloadsView()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
                .badge(coordinator.activeJobs.count)
                .tag(Tab.downloads)

            LibraryView()
                .tabItem { Label("Library", systemImage: "play.square.stack") }
                .tag(Tab.library)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .onOpenURL { url in
            // Links shared into the app land here.
            selection = .downloads
            NotificationCenter.default.post(name: .incomingLink, object: url.absoluteString)
        }
    }
}

extension Notification.Name {
    static let incomingLink = Notification.Name("YTDLPHub.incomingLink")
}
