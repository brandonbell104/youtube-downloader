import Foundation

/// Turns "the user asked for 1080p" into "download these one or two files".
///
/// Two constraints drive the choices:
///
/// * AVFoundation can only stitch MPEG-4 family tracks back together, so a
///   merge plan sticks to H.264 video and AAC audio. WebM/VP9/Opus renditions
///   are ignored for merging even when they're higher quality.
/// * Anything above 720p on YouTube only exists as video-only, so the common
///   case is a two-file download followed by a mux.
enum StreamSelector {
    static func plan(for streams: [StreamOption], preference: QualityPreference) -> DownloadPlan? {
        guard !streams.isEmpty else { return nil }

        if preference.isAudioOnly {
            guard let audio = bestAudio(in: streams, strict: true) else { return nil }
            return DownloadPlan(audio: audio)
        }

        let cap = preference.maxHeight

        if let video = bestVideo(in: streams, maxHeight: cap), let audio = bestAudio(in: streams) {
            // A progressive file that already meets the request avoids a mux
            // entirely, so prefer it when it's not a downgrade.
            if let progressive = bestProgressive(in: streams, maxHeight: cap),
               (progressive.height ?? 0) >= (video.height ?? 0) {
                return DownloadPlan(progressive: progressive)
            }
            return DownloadPlan(video: video, audio: audio)
        }

        if let progressive = bestProgressive(in: streams, maxHeight: cap) {
            return DownloadPlan(progressive: progressive)
        }

        // Last resort: the video exists but nothing we can play or mux. Take
        // the best audio so the user gets something rather than an error.
        if let audio = bestAudio(in: streams, strict: true) {
            return DownloadPlan(audio: audio)
        }

        return nil
    }

    static func bestVideo(in streams: [StreamOption], maxHeight: Int?) -> StreamOption? {
        streams
            .filter { $0.kind == .videoOnly && $0.isMuxable && withinCap($0, maxHeight) }
            .max(by: videoOrdering)
    }

    /// - Parameter strict: when true, only true audio-only renditions are
    ///   considered. An "audio only" download must not silently produce a file
    ///   with a video track in it.
    static func bestAudio(in streams: [StreamOption], strict: Bool = false) -> StreamOption? {
        let muxable = streams.filter { $0.kind == .audioOnly && $0.isMuxable }
        if let best = muxable.max(by: { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }) {
            return best
        }
        guard !strict else { return nil }
        // No AAC audio offered — take the audio side of a progressive stream
        // to pair with a video-only rendition rather than giving up.
        return streams
            .filter { $0.kind == .progressive && $0.isMuxable }
            .max(by: videoOrdering)
    }

    static func bestProgressive(in streams: [StreamOption], maxHeight: Int?) -> StreamOption? {
        streams
            .filter { $0.kind == .progressive && $0.isAVPlayable && withinCap($0, maxHeight) }
            .max(by: videoOrdering)
    }

    /// Every rendition worth showing in a manual picker, best first.
    static func selectableStreams(_ streams: [StreamOption]) -> [StreamOption] {
        let video = streams.filter { $0.hasVideo && $0.isMuxable }.sorted(by: { videoOrdering($1, $0) })
        let audio = streams.filter { $0.kind == .audioOnly && $0.isMuxable }
            .sorted { ($0.bitrate ?? 0) > ($1.bitrate ?? 0) }
        return video + audio
    }

    /// The quality string recorded against a finished download.
    static func label(for plan: DownloadPlan) -> String? {
        if plan.isAudioOnly {
            return plan.audio?.bitrate.map { "\($0 / 1000) kbps" } ?? "Audio"
        }
        guard let height = plan.height else { return nil }
        let fps = plan.progressive?.fps ?? plan.video?.fps ?? 0
        return fps > 30 ? "\(height)p\(fps)" : "\(height)p"
    }

    private static func withinCap(_ stream: StreamOption, _ maxHeight: Int?) -> Bool {
        guard let maxHeight else { return true }
        guard let height = stream.height else { return true }
        return height <= maxHeight
    }

    /// Height first, then frame rate, then bitrate.
    private static func videoOrdering(_ lhs: StreamOption, _ rhs: StreamOption) -> Bool {
        if (lhs.height ?? 0) != (rhs.height ?? 0) { return (lhs.height ?? 0) < (rhs.height ?? 0) }
        if (lhs.fps ?? 0) != (rhs.fps ?? 0) { return (lhs.fps ?? 0) < (rhs.fps ?? 0) }
        return (lhs.bitrate ?? 0) < (rhs.bitrate ?? 0)
    }
}
