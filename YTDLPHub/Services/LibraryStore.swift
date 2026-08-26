import Foundation

/// The list of finished downloads, persisted as JSON next to the files.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [LibraryItem] = []

    private let fileURL: URL

    init(fileURL: URL = Paths.libraryFile) {
        self.fileURL = fileURL
        load()
    }

    var totalSize: Int64 {
        items.compactMap { $0.fileSize }.reduce(0, +)
    }

    func add(_ item: LibraryItem) {
        items.insert(item, at: 0)
        save()
    }

    func item(with id: UUID) -> LibraryItem? {
        items.first { $0.id == id }
    }

    func delete(_ item: LibraryItem) {
        try? FileManager.default.removeItem(at: item.fileURL)
        items.removeAll { $0.id == item.id }
        save()
    }

    func delete(atOffsets offsets: IndexSet) {
        for index in offsets {
            guard items.indices.contains(index) else { continue }
            try? FileManager.default.removeItem(at: items[index].fileURL)
        }
        items.remove(atOffsets: offsets)
        save()
    }

    func rename(_ item: LibraryItem, to newTitle: String) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].title = newTitle
        save()
    }

    /// Drops entries whose file has gone missing — the user can delete files
    /// from the Files app behind our back.
    func prune() {
        let survivors = items.filter { $0.exists }
        guard survivors.count != items.count else { return }
        items = survivors
        save()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = (try? decoder.decode([LibraryItem].self, from: data)) ?? []
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
