import Foundation

/// Owns the download queue: resolving links, driving transfers, muxing the
/// result and filing it in the library.
@MainActor
final class DownloadCoordinator: ObservableObject {
    @Published private(set) var jobs: [DownloadJob] = []

    private let settings: AppSettings
    private let library: LibraryStore
    private let downloader: BackgroundDownloader
    private var resolveTasks: [UUID: Task<Void, Never>] = [:]
    private var finalizeTasks: [UUID: Task<Void, Never>] = [:]

    init(
        settings: AppSettings,
        library: LibraryStore,
        downloader: BackgroundDownloader = .shared
    ) {
        self.settings = settings
        self.library = library
        self.downloader = downloader
        loadJobs()
        downloader.delegate = self
        downloader.activate()
        Task { await recoverInterruptedJobs() }
    }

    var activeJobs: [DownloadJob] { jobs.filter { $0.state.isActive } }
    var finishedJobs: [DownloadJob] { jobs.filter { $0.state.isFinished } }
    var hasActiveWork: Bool { !activeJobs.isEmpty }

    // MARK: - Queue management

    /// Adds a link to the queue. Returns the job so callers can watch it.
    @discardableResult
    func enqueue(link: String, quality: QualityPreference) -> DownloadJob? {
        guard let url = YouTubeURL.normalize(link) else { return nil }
        let job = DownloadJob(sourceURL: url.absoluteString, quality: quality)
        jobs.insert(job, at: 0)
        saveJobs()
        startResolving(job)
        return job
    }

    /// Adds a link whose streams have already been resolved — used by the
    /// preview sheet so the video isn't looked up twice.
    @discardableResult
    func enqueue(resolved: ResolvedMedia, link: String, quality: QualityPreference) -> DownloadJob? {
        guard let plan = StreamSelector.plan(for: resolved.streams, preference: quality) else { return nil }
        let job = DownloadJob(sourceURL: link, quality: quality)
        job.record.metadata = resolved.metadata
        jobs.insert(job, at: 0)
        begin(job, plan: plan)
        return job
    }

    func cancel(_ job: DownloadJob) {
        resolveTasks[job.id]?.cancel()
        resolveTasks[job.id] = nil
        finalizeTasks[job.id]?.cancel()
        finalizeTasks[job.id] = nil
        downloader.cancel(jobID: job.id)
        guard job.state.isActive else { return }
        job.record.state = .cancelled
        cleanUpWorkingFiles(job.id)
        saveJobs()
    }

    func retry(_ job: DownloadJob) {
        job.record.state = .pending
        job.record.errorMessage = nil
        job.record.bytesReceived = [:]
        job.record.bytesExpected = [:]
        job.record.plan = nil
        cleanUpWorkingFiles(job.id)
        saveJobs()
        startResolving(job)
    }

    func remove(_ job: DownloadJob) {
        cancel(job)
        jobs.removeAll { $0.id == job.id }
        cleanUpWorkingFiles(job.id)
        saveJobs()
    }

    func clearFinished() {
        for job in finishedJobs {
            cleanUpWorkingFiles(job.id)
        }
        jobs.removeAll { $0.state.isFinished }
        saveJobs()
    }

    // MARK: - Resolving

    /// Looks a link up without queueing it, for the confirmation sheet.
    func preview(link: String) async throws -> ResolvedMedia {
        guard let url = YouTubeURL.normalize(link) else {
            throw ResolveError.notALink(link)
        }
        return try await settings.makeResolver().resolve(url)
    }

    private func startResolving(_ job: DownloadJob) {
        job.record.state = .resolving
        let resolver = settings.makeResolver()
        let link = job.record.sourceURL
        let quality = job.record.quality

        resolveTasks[job.id] = Task { [weak self, weak job] in
            guard let job else { return }
            do {
                guard let url = YouTubeURL.normalize(link) else { throw ResolveError.notALink(link) }
                let media = try await resolver.resolve(url)
                try Task.checkCancellation()

                guard let plan = StreamSelector.plan(for: media.streams, preference: quality) else {
                    throw ResolveError.noUsableStreams
                }
                guard let self else { return }
                job.record.metadata = media.metadata
                self.begin(job, plan: plan)
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.fail(job, message: error.localizedDescription)
            }
            self?.resolveTasks[job.id] = nil
        }
    }

    private func begin(_ job: DownloadJob, plan: DownloadPlan) {
        job.record.plan = plan
        job.record.state = .downloading
        job.record.bytesReceived = [:]
        job.record.bytesExpected = [:]

        for entry in plan.slots {
            if let size = entry.stream.contentLength, size > 0 {
                job.record.bytesExpected[entry.slot.rawValue] = size
            }
            downloader.start(jobID: job.id, slot: entry.slot, stream: entry.stream)
        }
        saveJobs()
    }

    private func fail(_ job: DownloadJob, message: String) {
        guard job.state.isActive else { return }
        job.record.state = .failed
        job.record.errorMessage = message
        downloader.cancel(jobID: job.id)
        saveJobs()
    }

    // MARK: - Completion

    /// Called once every slot of a job has landed on disk.
    private func finalize(_ job: DownloadJob) {
        guard let plan = job.record.plan, job.state == .downloading else { return }
        job.record.state = .merging
        saveJobs()

        let jobID = job.id
        let title = job.record.metadata?.title ?? "Video"
        let folder = Paths.jobFolder(jobID)

        finalizeTasks[jobID] = Task { [weak self, weak job] in
            do {
                let output = Paths.uniqueLibraryURL(preferredName: title, ext: plan.outputExtension)

                if plan.requiresMerge,
                   let video = plan.video,
                   let audio = plan.audio {
                    let videoFile = folder.appendingPathComponent(DownloadSlot.video.filename(container: video.container))
                    let audioFile = folder.appendingPathComponent(DownloadSlot.audio.filename(container: audio.container))
                    try await MediaMerger.mux(video: videoFile, audio: audioFile, into: output)
                } else if let single = plan.progressive ?? plan.audio {
                    let slot: DownloadSlot = plan.progressive != nil ? .single : .audio
                    let source = folder.appendingPathComponent(slot.filename(container: single.container))
                    try MediaMerger.move(source, to: output)
                } else {
                    throw MergeError.missingTrack("media")
                }

                try Task.checkCancellation()
                guard let self, let job else { return }
                self.complete(job, plan: plan, output: output)
            } catch is CancellationError {
                return
            } catch {
                guard let self, let job else { return }
                self.fail(job, message: error.localizedDescription)
            }
            self?.finalizeTasks[jobID] = nil
        }
    }

    private func complete(_ job: DownloadJob, plan: DownloadPlan, output: URL) {
        let metadata = job.record.metadata
        let item = LibraryItem(
            title: metadata?.title ?? output.deletingPathExtension().lastPathComponent,
            videoID: metadata?.videoID,
            sourceURL: job.record.sourceURL,
            channel: metadata?.channel,
            relativePath: output.lastPathComponent,
            remoteThumbnail: metadata?.thumbnailURL,
            duration: metadata?.duration,
            fileSize: Paths.fileSize(at: output),
            isAudioOnly: plan.isAudioOnly,
            qualityLabel: StreamSelector.label(for: plan)
        )
        library.add(item)

        job.record.libraryItemID = item.id
        job.record.state = .completed
        cleanUpWorkingFiles(job.id)
        saveJobs()

        if settings.saveToPhotos, !plan.isAudioOnly {
            Task { await PhotoLibraryExporter.save(output) }
        }
    }

    private func allSlotsPresent(for job: DownloadJob) -> Bool {
        guard let plan = job.record.plan else { return false }
        let folder = Paths.jobFolder(job.id)
        return plan.slots.allSatisfy { entry in
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent(
                    entry.slot.filename(container: entry.stream.container)
                ).path
            )
        }
    }

    private func cleanUpWorkingFiles(_ jobID: UUID) {
        try? FileManager.default.removeItem(at: Paths.jobs.appendingPathComponent(jobID.uuidString, isDirectory: true))
    }

    // MARK: - Persistence and recovery

    private func loadJobs() {
        guard let data = try? Data(contentsOf: Paths.jobsFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = (try? decoder.decode([JobRecord].self, from: data)) ?? []
        jobs = records.map { DownloadJob(record: $0) }
    }

    private func saveJobs() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(jobs.map(\.record)) else { return }
        try? data.write(to: Paths.jobsFile, options: .atomic)
    }

    /// Background transfers outlive the app. On launch, work out what happened
    /// while we were gone: finish jobs whose files all arrived, re-queue the
    /// ones that stalled, and fail the ones that can't be resumed.
    private func recoverInterruptedJobs() async {
        let inFlight = await downloader.activeJobIDs()

        for job in jobs where job.state.isActive {
            switch job.state {
            case .pending, .resolving:
                startResolving(job)
            case .downloading:
                if allSlotsPresent(for: job) {
                    finalize(job)
                } else if !inFlight.contains(job.id) {
                    // No live task and no finished file: the transfer died with
                    // the process. Media URLs are short-lived, so re-resolve.
                    retry(job)
                }
            case .merging:
                if allSlotsPresent(for: job) {
                    job.record.state = .downloading
                    finalize(job)
                } else {
                    retry(job)
                }
            default:
                break
            }
        }
    }
}

// MARK: - Transfer callbacks

extension DownloadCoordinator: BackgroundDownloaderDelegate {
    func downloader(
        _ downloader: BackgroundDownloader,
        progressFor jobID: UUID,
        slot: DownloadSlot,
        received: Int64,
        expected: Int64
    ) {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        job.record.bytesReceived[slot.rawValue] = received
        if expected > 0 {
            job.record.bytesExpected[slot.rawValue] = expected
        }
        if job.record.state == .pending || job.record.state == .resolving {
            job.record.state = .downloading
        }
    }

    func downloader(
        _ downloader: BackgroundDownloader,
        finished jobID: UUID,
        slot: DownloadSlot,
        at fileURL: URL
    ) {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        if let size = Paths.fileSize(at: fileURL) {
            job.record.bytesReceived[slot.rawValue] = size
            job.record.bytesExpected[slot.rawValue] = size
        }
        if allSlotsPresent(for: job) {
            finalize(job)
        }
    }

    func downloader(
        _ downloader: BackgroundDownloader,
        failed jobID: UUID,
        slot: DownloadSlot,
        error: Error
    ) {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        fail(job, message: error.localizedDescription)
    }
}
