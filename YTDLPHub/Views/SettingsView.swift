import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LibraryStore

    @State private var serverStatus: ServerStatus = .unknown
    @State private var bundledVersion: String?
    @State private var checkedBundledVersion = false

    enum ServerStatus: Equatable {
        case unknown
        case checking
        case reachable(String)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Downloads") {
                    Picker("Default quality", selection: $settings.defaultQuality) {
                        ForEach(QualityPreference.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    Toggle("Confirm before downloading", isOn: $settings.confirmBeforeDownloading)
                    Toggle("Also save videos to Photos", isOn: $settings.saveToPhotos)
                }

                Section {
                    if settings.embeddedYTDLPAvailable {
                        Toggle("Use the bundled yt-dlp", isOn: $settings.useEmbeddedYTDLP)
                        LabeledContent("Version") {
                            if checkedBundledVersion {
                                Text(bundledVersion ?? "Unknown")
                                    .foregroundStyle(.secondary)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                    } else {
                        Label("Not included in this build", systemImage: "shippingbox")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Bundled yt-dlp")
                } footer: {
                    if settings.embeddedYTDLPAvailable {
                        Text("yt-dlp runs inside the app, on this device. Update it by re-running Scripts/fetch-python.sh and rebuilding.")
                    } else {
                        Text("Run Scripts/fetch-python.sh and rebuild to bundle yt-dlp and a Python runtime into the app. Without it, extraction falls back to the built-in YouTube extractor.")
                    }
                }

                Section {
                    Toggle("Use a yt-dlp server", isOn: $settings.useRemoteResolver)

                    if settings.useRemoteResolver {
                        TextField("http://192.168.1.10:8420", text: $settings.remoteServerAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)

                        SecureField("Access token (optional)", text: $settings.remoteServerToken)

                        Toggle("Prefer the server over on-device", isOn: $settings.preferRemoteResolver)

                        Button {
                            checkServer()
                        } label: {
                            HStack {
                                Text("Test connection")
                                Spacer()
                                statusLabel
                            }
                        }
                    }
                } header: {
                    Text("yt-dlp bridge")
                } footer: {
                    Text("Point this at a Mac, Raspberry Pi or server running the companion script to do extraction there instead. Handy when you'd rather update yt-dlp with pip than rebuild the app. The download itself still happens on this device.")
                }

                Section {
                    LabeledContent("Downloads", value: "\(library.items.count)")
                    LabeledContent("Space used", value: Formatters.bytes(library.totalSize) ?? "None")
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Files live in the app's Documents folder and are visible in the Files app under \"YTDLP Hub\". Deleting the app deletes them.")
                }

                Section {
                    Text("Downloading from YouTube is against YouTube's Terms of Service unless the video offers a download button or you own the content. Use this for videos you have the right to keep.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .task {
                guard !checkedBundledVersion else { return }
                // Reading the version boots the interpreter, which takes a
                // moment, so it happens off the main thread.
                bundledVersion = await Task.detached { EmbeddedYTDLPResolver.version }.value
                checkedBundledVersion = true
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch serverStatus {
        case .unknown:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .reachable(let version):
            Label(version, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private func checkServer() {
        guard let base = settings.remoteServerURL else {
            serverStatus = .failed("Invalid address")
            return
        }
        serverStatus = .checking

        Task {
            var request = URLRequest(url: base.appendingPathComponent("health"))
            request.timeoutInterval = 10
            if !settings.remoteServerToken.isEmpty {
                request.setValue("Bearer \(settings.remoteServerToken)", forHTTPHeaderField: "Authorization")
            }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    serverStatus = .failed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                    return
                }
                let health = try? JSONDecoder().decode(Health.self, from: data)
                serverStatus = .reachable(health?.ytDlpVersion.map { "yt-dlp \($0)" } ?? "Connected")
            } catch {
                serverStatus = .failed(error.localizedDescription)
            }
        }
    }

    private struct Health: Decodable {
        var ytDlpVersion: String?

        enum CodingKeys: String, CodingKey {
            case ytDlpVersion = "yt_dlp_version"
        }
    }
}
