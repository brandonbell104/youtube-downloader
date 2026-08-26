import Foundation

/// Which files have to be fetched, and whether they need muxing afterwards.
struct DownloadPlan: Codable, Equatable {
    /// The video-plus-audio file, when YouTube offers one that already matches
    /// the request.
    var progressive: StreamOption?
    var video: StreamOption?
    var audio: StreamOption?

    var requiresMerge: Bool { progressive == nil && video != nil && audio != nil }

    var isAudioOnly: Bool { progressive == nil && video == nil && audio != nil }

    /// Every stream this plan needs, paired with the slot it fills on disk.
    var slots: [(slot: DownloadSlot, stream: StreamOption)] {
        if let progressive { return [(.single, progressive)] }
        var result: [(DownloadSlot, StreamOption)] = []
        if let video { result.append((.video, video)) }
        if let audio { result.append((.audio, audio)) }
        return result
    }

    var totalBytes: Int64? {
        let sizes = slots.compactMap { $0.stream.contentLength }
        guard sizes.count == slots.count, !sizes.isEmpty else { return nil }
        return sizes.reduce(0, +)
    }

    /// Extension of the file the user ends up with.
    var outputExtension: String {
        if isAudioOnly { return audio?.container ?? "m4a" }
        if let progressive { return progressive.container }
        return "mp4"
    }

    var height: Int? { progressive?.height ?? video?.height }
}

/// Where a downloaded stream lands inside a job's working folder.
enum DownloadSlot: String, Codable, CaseIterable {
    case single
    case video
    case audio

    func filename(container: String) -> String {
        "\(rawValue).\(container)"
    }
}
