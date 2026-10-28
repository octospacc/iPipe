import Foundation
import Combine

/// Downloads audio straight from YouTube's CDN in Range chunks (the CDN throttles/refuses
/// single full-file requests), writes to a temp file, then moves it into DownloadedAudio/.
public final class CacheService: ObservableObject, @unchecked Sendable {
    public static let shared = CacheService()

    @Published public private(set) var downloadProgress: [String: Double] = [:]
    @Published public private(set) var activeDownloads: Set<String> = []
    @Published public private(set) var lastError: String?

    private var tasks: [String: Task<String, Error>] = [:]
    private let lock = NSLock()
    private let fileManager = FileManager.default
    private let session: URLSession
    private let chunkSize: Int64 = 1_048_576

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)
        try? ensureAudioDirectoryExists()
    }

    private var audioDirectoryURL: URL {
        Track.documentsDirectory.appendingPathComponent("DownloadedAudio", isDirectory: true)
    }

    private func ensureAudioDirectoryExists() throws {
        guard !fileManager.fileExists(atPath: audioDirectoryURL.path) else { return }
        try fileManager.createDirectory(at: audioDirectoryURL, withIntermediateDirectories: true)
    }

    public func isTrackDownloaded(trackId: String) -> Bool {
        fileManager.fileExists(atPath: audioDirectoryURL.appendingPathComponent("\(trackId).m4a").path)
    }

    public func getLocalAudioURL(trackId: String) -> URL? {
        let u = audioDirectoryURL.appendingPathComponent("\(trackId).m4a")
        return fileManager.fileExists(atPath: u.path) ? u : nil
    }

    public func clearError() {
        lastError = nil
    }

    // Sync helpers so NSLock is never held across an await.
    private func existingTask(_ id: String) -> Task<String, Error>? {
        lock.lock(); defer { lock.unlock() }
        return tasks[id]
    }
    private func setTask(_ t: Task<String, Error>?, for id: String) {
        lock.lock(); defer { lock.unlock() }
        tasks[id] = t
    }

    /// Returns the path relative to the documents directory ("DownloadedAudio/<id>.m4a").
    public func downloadTrack(track: Track, directAudioURL: URL? = nil) async throws -> String {
        let relative = "DownloadedAudio/\(track.id).m4a"
        if isTrackDownloaded(trackId: track.id) { return relative }
        if let existing = existingTask(track.id) { return try await existing.value }

        let task = Task<String, Error> { [weak self] in
            guard let self else { throw URLError(.cancelled) }
            await MainActor.run {
                self.activeDownloads.insert(track.id)
                self.downloadProgress[track.id] = 0
                self.lastError = nil
            }
            do {
                try await self.performDownload(track: track, directURL: directAudioURL)
                StorageService.shared.saveTrack(track)
                StorageService.shared.updateTrackLocalPath(trackId: track.id, relativePath: relative)
                await self.finish(track.id)
                return relative
            } catch {
                let cancelled = (error is CancellationError) || (error as? URLError)?.code == .cancelled
                await self.finish(track.id)
                if !cancelled {
                    #if DEBUG
                    print("[Tuneflow] download failed for \(track.id): \(error.localizedDescription)")
                    #endif
                    await MainActor.run {
                        self.lastError = "Could not download \"\(track.title)\": \(error.localizedDescription)"
                    }
                }
                throw error
            }
        }
        setTask(task, for: track.id)
        return try await task.value
    }

    private func finish(_ id: String) async {
        setTask(nil, for: id)
        await MainActor.run {
            self.activeDownloads.remove(id)
            self.downloadProgress.removeValue(forKey: id)
        }
    }

    private func performDownload(track: Track, directURL: URL?) async throws {
        var url: URL
        var expectedLength: Int64?
        var userAgent = "Mozilla/5.0"
        if let directURL {
            url = directURL
        } else {
            let stream = try await YouTubeDirectService.shared.resolveAudioStream(videoId: track.id)
            url = stream.url
            expectedLength = stream.contentLength
            userAgent = stream.userAgent
        }

        func ranged(_ from: Int64, _ to: Int64) async throws -> (Data, HTTPURLResponse) {
            var req = URLRequest(url: url)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
            req.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard http.statusCode == 200 || http.statusCode == 206 else {
                throw URLError(.badServerResponse)
            }
            return (data, http)
        }

        // Prime the download and learn the total size from Content-Range when needed.
        var firstChunk: Data?
        var wholeFile: Data?
        if expectedLength == nil {
            let (data, http) = try await ranged(0, chunkSize - 1)
            if http.statusCode == 200 {
                // Server ignored Range and returned everything.
                wholeFile = data
                expectedLength = Int64(data.count)
            } else {
                firstChunk = data
                if let total = totalLength(from: http) {
                    expectedLength = total
                } else {
                    // Ask for a single byte to read the total size.
                    let (_, probe) = try await ranged(0, 0)
                    expectedLength = totalLength(from: probe)
                }
            }
        }

        guard let total = expectedLength, total > 0 else { throw URLError(.cannotParseResponse) }

        try ensureAudioDirectoryExists()
        let tmp = fileManager.temporaryDirectory.appendingPathComponent("\(track.id)-\(UUID().uuidString).part")
        guard fileManager.createFile(atPath: tmp.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: tmp)
        var completed = false
        defer {
            try? handle.close()
            if !completed { try? fileManager.removeItem(at: tmp) }
        }

        var offset: Int64 = 0
        if let wholeFile {
            try handle.write(contentsOf: wholeFile)
            offset = Int64(wholeFile.count)
        } else if let firstChunk {
            guard !firstChunk.isEmpty else { throw URLError(.zeroByteResource) }
            try handle.write(contentsOf: firstChunk)
            offset = Int64(firstChunk.count)
        }
        let initialProgress = total > 0 ? min(Double(offset) / Double(total), 1) : 0
        await MainActor.run { self.downloadProgress[track.id] = initialProgress }

        while offset < total {
            try Task.checkCancellation()
            let end = min(offset + chunkSize - 1, total - 1)
            let (data, http) = try await ranged(offset, end)
            guard !data.isEmpty else { throw URLError(.zeroByteResource) }
            if http.statusCode == 200 && offset > 0 {
                // The CDN ignored our Range and re-sent the whole file; appending it would corrupt.
                throw URLError(.cannotParseResponse)
            }
            try handle.write(contentsOf: data)
            offset += Int64(data.count)
            let progress = min(Double(offset) / Double(total), 1)
            await MainActor.run { self.downloadProgress[track.id] = progress }
        }

        try handle.close()

        let attributes = try fileManager.attributesOfItem(atPath: tmp.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize == total else { throw URLError(.cannotDecodeContentData) }

        let destination = audioDirectoryURL.appendingPathComponent("\(track.id).m4a")
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: tmp, to: destination)
        completed = true
    }

    private func totalLength(from response: HTTPURLResponse) -> Int64? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range"),
              let total = value.split(separator: "/").last,
              let n = Int64(total.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return n
    }

    public func cancelDownload(trackId: String) {
        existingTask(trackId)?.cancel()
    }

    public func deleteTrackAudio(trackId: String) {
        try? fileManager.removeItem(at: audioDirectoryURL.appendingPathComponent("\(trackId).m4a"))
        StorageService.shared.updateTrackLocalPath(trackId: trackId, relativePath: nil)
    }

    public func clearAllCache() {
        try? fileManager.removeItem(at: audioDirectoryURL)
        try? ensureAudioDirectoryExists()
    }
}
