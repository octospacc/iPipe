import Foundation
import Combine

public final class CacheService: NSObject, ObservableObject, @unchecked Sendable {
    public static let shared = CacheService()
    
    @Published public private(set) var downloadProgress: [String: Double] = [:]
    @Published public private(set) var activeDownloads: Set<String> = []
    
    private var downloadTasks: [String: URLSessionDownloadTask] = [:]
    private var taskToTrackId: [Int: String] = [:]
    private var downloadCompletions: [String: (Result<String, Error>) -> Void] = [:]
    
    private var session: URLSession!
    private let fileManager = FileManager.default
    private let lock = NSLock()
    
    private override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        ensureAudioDirectoryExists()
    }
    
    private var audioDirectoryURL: URL {
        Track.documentsDirectory.appendingPathComponent("DownloadedAudio", isDirectory: true)
    }
    
    private func ensureAudioDirectoryExists() {
        if !fileManager.fileExists(atPath: audioDirectoryURL.path) {
            try? fileManager.createDirectory(at: audioDirectoryURL, withIntermediateDirectories: true)
        }
    }
    
    public func isTrackDownloaded(trackId: String) -> Bool {
        let destination = audioDirectoryURL.appendingPathComponent("\(trackId).m4a")
        return fileManager.fileExists(atPath: destination.path)
    }
    
    public func getLocalAudioURL(trackId: String) -> URL? {
        let destination = audioDirectoryURL.appendingPathComponent("\(trackId).m4a")
        return fileManager.fileExists(atPath: destination.path) ? destination : nil
    }
    
    /// Downloads direct audio stream or direct audio source into local storage
    public func downloadTrack(track: Track, directAudioURL: URL? = nil) async throws -> String {
        if isTrackDownloaded(trackId: track.id) {
            return "DownloadedAudio/\(track.id).m4a"
        }
        
        let targetURL: URL
        if let directAudioURL = directAudioURL {
            targetURL = directAudioURL
        } else {
            // Attempt to resolve from custom instance or fallback
            targetURL = try await YouTubeBackendService.shared.resolveAudioStreamURL(videoId: track.id)
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: URLError(.cancelled))
                    return
                }
                
                self.lock.lock()
                defer { self.lock.unlock() }
                
                if let existing = self.downloadTasks[track.id] {
                    existing.cancel()
                }
                
                var request = URLRequest(url: targetURL)
                request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                
                let task = self.session.downloadTask(with: request)
                self.downloadTasks[track.id] = task
                self.taskToTrackId[task.taskIdentifier] = track.id
                self.activeDownloads.insert(track.id)
                self.downloadProgress[track.id] = 0.0
                
                self.downloadCompletions[track.id] = { result in
                    switch result {
                    case .success(let path):
                        continuation.resume(returning: path)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                
                task.resume()
            }
        }
    }
    
    public func cancelDownload(trackId: String) {
        lock.lock()
        defer { self.lock.unlock() }
        
        if let task = downloadTasks[trackId] {
            task.cancel()
            downloadTasks.removeValue(forKey: trackId)
            taskToTrackId.removeValue(forKey: task.taskIdentifier)
        }
        activeDownloads.remove(trackId)
        downloadProgress.removeValue(forKey: trackId)
        if let completion = downloadCompletions.removeValue(forKey: trackId) {
            completion(.failure(URLError(.cancelled)))
        }
    }
    
    public func deleteTrackAudio(trackId: String) {
        let destination = audioDirectoryURL.appendingPathComponent("\(trackId).m4a")
        try? fileManager.removeItem(at: destination)
    }
    
    public func clearAllCache() {
        try? fileManager.removeItem(at: audioDirectoryURL)
        ensureAudioDirectoryExists()
    }
}

extension CacheService: URLSessionDownloadDelegate {
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let trackId = taskToTrackId[downloadTask.taskIdentifier] else { return }
        
        if totalBytesExpectedToWrite > 0 {
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            DispatchQueue.main.async {
                self.downloadProgress[trackId] = progress
            }
        }
    }
    
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let trackId = taskToTrackId[downloadTask.taskIdentifier] else { return }
        
        ensureAudioDirectoryExists()
        let destination = audioDirectoryURL.appendingPathComponent("\(trackId).m4a")
        try? fileManager.removeItem(at: destination)
        
        do {
            try fileManager.moveItem(at: location, to: destination)
            let relativePath = "DownloadedAudio/\(trackId).m4a"
            
            DispatchQueue.main.async {
                self.activeDownloads.remove(trackId)
                self.downloadProgress.removeValue(forKey: trackId)
                self.downloadTasks.removeValue(forKey: trackId)
                self.taskToTrackId.removeValue(forKey: downloadTask.taskIdentifier)
                
                if let completion = self.downloadCompletions.removeValue(forKey: trackId) {
                    completion(.success(relativePath))
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.activeDownloads.remove(trackId)
                self.downloadProgress.removeValue(forKey: trackId)
                self.downloadTasks.removeValue(forKey: trackId)
                self.taskToTrackId.removeValue(forKey: downloadTask.taskIdentifier)
                
                if let completion = self.downloadCompletions.removeValue(forKey: trackId) {
                    completion(.failure(error))
                }
            }
        }
    }
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error, let trackId = taskToTrackId[task.taskIdentifier] else { return }
        
        DispatchQueue.main.async {
            self.activeDownloads.remove(trackId)
            self.downloadProgress.removeValue(forKey: trackId)
            self.downloadTasks.removeValue(forKey: trackId)
            self.taskToTrackId.removeValue(forKey: task.taskIdentifier)
            
            if let completion = self.downloadCompletions.removeValue(forKey: trackId) {
                completion(.failure(error))
            }
        }
    }
}
