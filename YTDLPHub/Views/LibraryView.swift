import SwiftUI
import UIKit

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var search = ""
    @State private var nowPlaying: LibraryItem?
    @State private var renaming: LibraryItem?
    @State private var draftTitle = ""

    var body: some View {
        NavigationStack {
            Group {
                if library.items.isEmpty {
                    EmptyStateView(
                        symbol: "play.square.stack",
                        title: "Your library is empty",
                        message: "Downloads land here. They play offline and stay on the device until you delete them."
                    )
                } else {
                    list
                }
            }
            .navigationTitle("Library")
            .toolbar {
                if !library.items.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Text(Formatters.bytes(library.totalSize) ?? "")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $search, prompt: "Search downloads")
            .onAppear { library.prune() }
            .fullScreenCover(item: $nowPlaying) { item in
                PlayerView(item: item)
            }
            .alert("Rename", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("Title", text: $draftTitle)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") {
                    if let renaming, !draftTitle.trimmingCharacters(in: .whitespaces).isEmpty {
                        library.rename(renaming, to: draftTitle)
                    }
                    renaming = nil
                }
            }
        }
    }

    private var list: some View {
        List {
            ForEach(filteredItems) { item in
                Button {
                    nowPlaying = item
                } label: {
                    LibraryRow(item: item)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    ShareLink(item: item.fileURL) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        renaming = item
                        draftTitle = item.title
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    if let source = item.sourceURL, let url = URL(string: source) {
                        Link(destination: url) {
                            Label("Open original", systemImage: "safari")
                        }
                    }
                    Button(role: .destructive) {
                        library.delete(item)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        library.delete(item)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    ShareLink(item: item.fileURL) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .tint(.blue)
                }
            }
        }
        .listStyle(.plain)
    }

    private var filteredItems: [LibraryItem] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return library.items }
        return library.items.filter {
            $0.title.lowercased().contains(query)
                || ($0.channel?.lowercased().contains(query) ?? false)
        }
    }
}

struct LibraryRow: View {
    let item: LibraryItem
    @State private var poster: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let poster {
                    Image(uiImage: poster)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                    Image(systemName: item.isAudioOnly ? "music.note" : "film")
                        .foregroundStyle(.tertiary)
                }
                if !item.isAudioOnly {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 2)
                }
            }
            .frame(width: 96, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !item.exists {
                    Label("File missing", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .task(id: item.id) {
            poster = await ThumbnailProvider.shared.image(for: item)
        }
    }
}
