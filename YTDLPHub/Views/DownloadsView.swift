import Combine
import SwiftUI
import UIKit

struct DownloadsView: View {
    @EnvironmentObject private var coordinator: DownloadCoordinator
    @EnvironmentObject private var settings: AppSettings

    @State private var link = ""
    @State private var quality: QualityPreference = .fhd1080
    @State private var isResolving = false
    @State private var preview: PreviewPayload?
    @State private var errorMessage: String?
    @FocusState private var linkFieldFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    linkEntry
                } header: {
                    Text("Paste a link")
                } footer: {
                    Text("YouTube video, Shorts, or youtu.be links. The video is saved into the app and plays offline.")
                }

                if !coordinator.activeJobs.isEmpty {
                    Section("In progress") {
                        ForEach(coordinator.activeJobs) { job in
                            JobRow(job: job)
                        }
                    }
                }

                if !coordinator.finishedJobs.isEmpty {
                    Section {
                        ForEach(coordinator.finishedJobs) { job in
                            JobRow(job: job)
                        }
                    } header: {
                        HStack {
                            Text("Recent")
                            Spacer()
                            Button("Clear") { coordinator.clearFinished() }
                                .font(.caption)
                                .textCase(nil)
                        }
                    }
                }

                if coordinator.jobs.isEmpty {
                    Section {
                        EmptyStateView(
                            symbol: "arrow.down.circle",
                            title: "Nothing downloading",
                            message: "Copy a YouTube link, come back here and paste it above."
                        )
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Downloads")
            .onAppear { quality = settings.defaultQuality }
            .onReceive(NotificationCenter.default.publisher(for: .incomingLink)) { note in
                if let value = note.object as? String {
                    link = value
                }
            }
            .sheet(item: $preview) { payload in
                DownloadPreviewSheet(
                    media: payload.media,
                    link: payload.link,
                    quality: $quality
                ) { chosen in
                    coordinator.enqueue(resolved: payload.media, link: payload.link, quality: chosen)
                    link = ""
                    preview = nil
                }
            }
            .alert(
                "Couldn't add that link",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                ),
                actions: { Button("OK", role: .cancel) { errorMessage = nil } },
                message: { Text(errorMessage ?? "") }
            )
        }
    }

    // MARK: - Pieces

    private var linkEntry: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                TextField("https://youtube.com/watch?v=…", text: $link)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .focused($linkFieldFocused)
                    .onSubmit(submit)
                if !link.isEmpty {
                    Button {
                        link = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Menu {
                    Picker("Quality", selection: $quality) {
                        ForEach(QualityPreference.allCases) { option in
                            Label(option.displayName, systemImage: option.symbolName).tag(option)
                        }
                    }
                } label: {
                    Label(quality.shortName, systemImage: quality.symbolName)
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)

                Button {
                    if let pasted = UIPasteboard.general.string {
                        link = pasted
                    }
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(action: submit) {
                    if isResolving {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Download", systemImage: "arrow.down")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || isResolving)
            }
        }
        .padding(.vertical, 4)
    }

    private func submit() {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        linkFieldFocused = false

        guard settings.confirmBeforeDownloading else {
            guard coordinator.enqueue(link: trimmed, quality: quality) != nil else {
                errorMessage = ResolveError.notALink(trimmed).localizedDescription
                return
            }
            link = ""
            return
        }

        isResolving = true
        Task {
            defer { isResolving = false }
            do {
                let media = try await coordinator.preview(link: trimmed)
                preview = PreviewPayload(media: media, link: trimmed)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private struct PreviewPayload: Identifiable {
        let media: ResolvedMedia
        let link: String
        var id: String { media.metadata.videoID + link }
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}
