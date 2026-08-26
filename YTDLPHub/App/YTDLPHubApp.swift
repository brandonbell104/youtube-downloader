import SwiftUI
import UIKit

@main
struct YTDLPHubApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var settings: AppSettings
    @StateObject private var library: LibraryStore
    @StateObject private var coordinator: DownloadCoordinator

    init() {
        let settings = AppSettings.shared
        let library = LibraryStore()
        _settings = StateObject(wrappedValue: settings)
        _library = StateObject(wrappedValue: library)
        _coordinator = StateObject(
            wrappedValue: DownloadCoordinator(settings: settings, library: library)
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(library)
                .environmentObject(coordinator)
        }
    }
}

/// Exists for one reason: iOS relaunches the app in the background when
/// transfers finish, and hands us a completion handler that has to be called
/// once the session has finished delivering its events.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            BackgroundDownloader.shared.backgroundEventsCompletionHandler = completionHandler
            BackgroundDownloader.shared.activate()
        }
    }
}
