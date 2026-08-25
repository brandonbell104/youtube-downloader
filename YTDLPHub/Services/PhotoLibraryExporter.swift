import Foundation
import Photos

/// Copies a finished video into the system Photos library.
///
/// Optional, and off by default — the app's own library in Files is the
/// primary home for downloads.
enum PhotoLibraryExporter {
    @discardableResult
    static func save(_ fileURL: URL) async -> Bool {
        let status = await requestAddAuthorization()
        guard status == .authorized || status == .limited else { return false }

        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
            } completionHandler: { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    private static func requestAddAuthorization() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }
}
