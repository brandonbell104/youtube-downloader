import AVFoundation
import Foundation

enum MergeError: LocalizedError {
    case missingTrack(String)
    case exportUnavailable
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingTrack(let kind):
            return "The downloaded file had no \(kind) track."
        case .exportUnavailable:
            return "Couldn't start the media exporter."
        case .exportFailed(let message):
            return message
        }
    }
}

/// Stitches a video-only file and an audio-only file into one playable movie.
///
/// This is the job ffmpeg does on desktop. AVFoundation can do the same thing
/// for MPEG-4 tracks without re-encoding: the tracks are placed in a
/// composition and exported with the passthrough preset, so the operation is
/// a remux and runs at copy speed.
enum MediaMerger {
    static func mux(video videoURL: URL, audio audioURL: URL, into outputURL: URL) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)

        guard let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw MergeError.missingTrack("video")
        }
        guard let sourceAudio = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw MergeError.missingTrack("audio")
        }

        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)

        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw MergeError.missingTrack("video")
        }
        try videoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: sourceVideo,
            at: .zero
        )
        videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)

        guard let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw MergeError.missingTrack("audio")
        }
        // The two files can differ by a frame or two; clamp to the shorter one
        // so the export doesn't pad with silence or trailing video.
        try audioTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: min(videoDuration, audioDuration)),
            of: sourceAudio,
            at: .zero
        )

        try? FileManager.default.removeItem(at: outputURL)
        try await export(composition, to: outputURL)
    }

    /// Rewraps a single downloaded file into the library, without touching the
    /// bitstream. Used for progressive and audio-only downloads.
    static func move(_ source: URL, to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: source, to: destination)
    }

    private static func export(_ asset: AVAsset, to outputURL: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw MergeError.exportUnavailable
        }
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                continuation.resume()
            }
        }

        switch session.status {
        case .completed:
            return
        case .cancelled:
            throw MergeError.exportFailed("The merge was cancelled.")
        default:
            throw MergeError.exportFailed(
                session.error?.localizedDescription ?? "The merge did not finish."
            )
        }
    }
}
