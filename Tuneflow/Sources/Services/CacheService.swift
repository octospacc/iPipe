import Foundation
import Combine

/// Downloads audio straight from YouTube's CDN in Range chunks (the CDN throttles/refuses
/// single full-file requests), writes to a temp file, then moves it into DownloadedAudio/.
public final class CacheService: ObservableObject, @unchecked Sendable {
    public static let shared = CacheService()

    @Published public private(set) var downloadProgress: [String: Double] = [:]
    @Published public private(set) var activeDownloads: Set<String> = []

    private var tasks: [String: Task<String, Error>] = [:]
    private let lock = NSLock()
    private let fileManager = FileManager.default
    private let session: URLSession
    private let chunkSize: Int64 = 1_048_576

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        session = URLSession(configuration: config)
        ensureAudioDirectoryExists()
    }

    private var audioDirectoryURL: URL {
        Track.documentsDirectory.appendingPathComponent("DownloadedAudio", isDirectory: true)
    }

    private func ensureAudioDirectoryExists() {
        try? fileManager.createDirectory(at: audioDirectoryURL, withIntermediateDirectories: true)
    }

    public func isTrackDownloaded(trackId: String) -> Bool {
        fileManager.fileExists(atPath: audioDirectoryURL.appendingPathComponent("\(trackId).m4a").path)
    }

    public func getLocalAudioURL(trackId: String) -> URL? {
        let u = audioDirectoryURL.appendingPathComponent("\(trackId).m4a")
        return fileManager.fileExists(atPath: u.path) ? u : nil
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
            }
            do {
                try await self.performDownload(track: track, directURL: directAudioURL)
                StorageService.shared.saveTrack(track)
                StorageService.shared.updateTrackLocalPath(trackId: track.id, relativePath: relative)
                await self.finish(track.id)
                return relative
            } catch {
                await self.finish(track.id)
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
        var length: Int64?
        var userAgent = "Mozilla/5.0"
        if let directURL {
            url = directURL
        } else {
            let s = try await YouTubeDirectService.shared.resolveAudioStream(videoId: track.id)
            url = s.url; length = s.contentLength; userAgent = s.userAgent
        }

        func ranged(_ from: Int64, _ to: Int64) async throws -> (Data, HTTPURLResponse) {
            var req = URLRequest(url: url)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 206 else {
                throw URLError(.badServerResponse)
            }
            return (data, http)
        }

        // Learn total size if the API did not tell us.
        var first: Data? = nil
        if length == nil {
            let (data, http) = try await ranged(0, chunkSize - 1)
            first = data
            if let cr = http.value(forHTTPHeaderField: "Content-Range"),
               let total = cr.split(separator: "/").last, let n = Int64(total) {
                length = n
            } else if http.statusCode == 200 {
                length = Int64(data.count)   // server ignored Range; whole file returned
            }
        }
        guard let total = length, total > 0 else { throw URLError(.cannotParseResponse) }

        ensureAudioDirectoryExists()
        let tmp = fileManager.temporaryDirectory.appendingPathComponent("\(track.id)-\(UUID().uuidString).part")
        fileManager.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        var ok = false
        defer {
            try? handle.close()
            if !ok { try? fileManager.removeItem(at: tmp) }
        }

        var offset: Int64 = 0
        if let first {
            try handle.write(contentsOf: first)
            offset = Int64(first.count)
        }
        while offset < total {
            try Task.checkCancellation()
            let end = min(offset + chunkSize - 1, total - 1)
            let (data, _) = try await ranged(offset, end)
            if data.isEmpty { throw URLError(.zeroByteResource) }
            try handle.write(contentsOf: data)
            offset += Int64(data.count)
            let p = Double(offset) / Double(total)
            await MainActor.run { self.downloadProgress[track.id] = min(p, 1) }
        }
        try handle.close()

        let dest = audioDirectoryURL.appendingPathComponent("\(track.id).m4a")
        if fileManager.fileExists(atPath: dest.path) { try fileManager.removeItem(at: dest) }
        try fileManager.moveItem(at: tmp, to: dest)
        ok = true
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
        ensureAudioDirectoryExists()
    }
}
