import Foundation

@MainActor
protocol BackgroundDownloaderDelegate: AnyObject {
    func downloader(_ downloader: BackgroundDownloader, progressFor jobID: UUID, slot: DownloadSlot, received: Int64, expected: Int64)
    func downloader(_ downloader: BackgroundDownloader, finished jobID: UUID, slot: DownloadSlot, at fileURL: URL)
    func downloader(_ downloader: BackgroundDownloader, failed jobID: UUID, slot: DownloadSlot, error: Error)
}

enum DownloadFailure: LocalizedError {
    case httpStatus(Int)
    case couldNotStore(String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            if code == 403 {
                return "The media link was rejected (HTTP 403). These links expire quickly — try the download again."
            }
            return "The server refused the download (HTTP \(code))."
        case .couldNotStore(let message):
            return "Couldn't save the downloaded file: \(message)"
        }
    }
}

/// Runs the actual byte transfers.
///
/// Uses a background `URLSession` so transfers continue while the app is in
/// the background and survive the app being terminated. Because a task can
/// outlive the process that created it, no state is held in memory: each task
/// carries everything needed to file its result in `taskDescription`, and the
/// coordinator reconciles against its persisted job list on launch.
@MainActor
final class BackgroundDownloader: NSObject {
    static let shared = BackgroundDownloader()

    weak var delegate: BackgroundDownloaderDelegate?

    /// Set by the app delegate when iOS relaunches us to deliver results.
    var backgroundEventsCompletionHandler: (() -> Void)?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: "com.ytdlphub.downloads")
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = true
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// Touching `session` early makes sure the delegate is attached before iOS
    /// tries to deliver events from a previous launch.
    func activate() {
        _ = session
    }

    func start(jobID: UUID, slot: DownloadSlot, stream: StreamOption) {
        var request = URLRequest(url: stream.url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let task = session.downloadTask(with: request)
        task.taskDescription = Ticket(jobID: jobID, slot: slot, container: stream.container).encoded
        if let size = stream.contentLength, size > 0 {
            task.countOfBytesClientExpectsToReceive = size
        }
        task.resume()
    }

    func cancel(jobID: UUID) {
        session.getAllTasks { tasks in
            for task in tasks {
                guard let ticket = Ticket(task.taskDescription), ticket.jobID == jobID else { continue }
                task.cancel()
            }
        }
    }

    func cancelEverything() {
        session.invalidateAndCancel()
    }

    /// Job IDs that still have work in flight, used to re-attach after launch.
    func activeJobIDs() async -> Set<UUID> {
        let tasks = await session.allTasks
        return Set(tasks.compactMap { Ticket($0.taskDescription)?.jobID })
    }

    // Matching the desktop browser is enough for googlevideo; the media hosts
    // reject requests with no user agent at all.
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36"

    /// The bit of state that rides along with a task.
    struct Ticket {
        var jobID: UUID
        var slot: DownloadSlot
        var container: String

        var encoded: String { "\(jobID.uuidString)|\(slot.rawValue)|\(container)" }

        init(jobID: UUID, slot: DownloadSlot, container: String) {
            self.jobID = jobID
            self.slot = slot
            self.container = container
        }

        init?(_ encoded: String?) {
            guard let encoded else { return nil }
            let parts = encoded.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3,
                  let jobID = UUID(uuidString: parts[0]),
                  let slot = DownloadSlot(rawValue: parts[1]) else { return nil }
            self.jobID = jobID
            self.slot = slot
            self.container = parts[2]
        }

        var destination: URL {
            Paths.jobFolder(jobID).appendingPathComponent(slot.filename(container: container))
        }
    }
}

extension BackgroundDownloader: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let ticket = Ticket(downloadTask.taskDescription) else { return }
        Task { @MainActor in
            self.delegate?.downloader(
                self,
                progressFor: ticket.jobID,
                slot: ticket.slot,
                received: totalBytesWritten,
                expected: totalBytesExpectedToWrite
            )
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let ticket = Ticket(downloadTask.taskDescription) else { return }

        // The temporary file is deleted the moment this method returns, so it
        // has to be moved synchronously, before any hop to the main actor.
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let status = http.statusCode
            Task { @MainActor in
                self.delegate?.downloader(self, failed: ticket.jobID, slot: ticket.slot, error: DownloadFailure.httpStatus(status))
            }
            return
        }

        let destination = ticket.destination
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            let message = error.localizedDescription
            Task { @MainActor in
                self.delegate?.downloader(self, failed: ticket.jobID, slot: ticket.slot, error: DownloadFailure.couldNotStore(message))
            }
            return
        }

        Task { @MainActor in
            self.delegate?.downloader(self, finished: ticket.jobID, slot: ticket.slot, at: destination)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error, let ticket = Ticket(task.taskDescription) else { return }
        // A cancelled task is the user's doing; the coordinator already knows.
        if (error as NSError).code == NSURLErrorCancelled { return }
        Task { @MainActor in
            self.delegate?.downloader(self, failed: ticket.jobID, slot: ticket.slot, error: error)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            let handler = self.backgroundEventsCompletionHandler
            self.backgroundEventsCompletionHandler = nil
            handler?()
        }
    }
}
