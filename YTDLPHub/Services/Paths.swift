import Foundation

/// Centralised on-disk layout.
///
/// iOS re-creates the app container path on every install and can change it on
/// update, so nothing is ever persisted as an absolute path — records store a
/// path relative to one of these roots and resolve it at read time.
enum Paths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var applicationSupport: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Finished downloads. Lives in Documents so the Files app can see it.
    static var library: URL {
        let url = documents.appendingPathComponent("Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Scratch space for in-flight jobs, one folder per job.
    static var jobs: URL {
        let url = applicationSupport.appendingPathComponent("Jobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func jobFolder(_ id: UUID) -> URL {
        let url = jobs.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var thumbnails: URL {
        let url = applicationSupport.appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var jobsFile: URL { applicationSupport.appendingPathComponent("jobs.json") }
    static var libraryFile: URL { applicationSupport.appendingPathComponent("library.json") }

    /// Resolves a library-relative filename to a full URL.
    static func libraryURL(for relativePath: String) -> URL {
        library.appendingPathComponent(relativePath)
    }

    /// Picks a filename inside the library that is not already taken.
    static func uniqueLibraryURL(preferredName: String, ext: String) -> URL {
        let base = sanitize(preferredName)
        var candidate = library.appendingPathComponent("\(base).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = library.appendingPathComponent("\(base) (\(counter)).\(ext)")
            counter += 1
        }
        return candidate
    }

    /// Strips characters that are awkward in filenames and trims the result to
    /// something a filesystem and a Files.app listing can both cope with.
    static func sanitize(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\?%*|\"<>:\n\r\t")
        let cleaned = name
            .components(separatedBy: illegal)
            .joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(cleaned.prefix(120)).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Video" : trimmed
    }

    static func fileSize(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize.map(Int64.init)
    }
}
