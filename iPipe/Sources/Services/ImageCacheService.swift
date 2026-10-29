import Foundation
import Combine
import CryptoKit

#if canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
#endif

/// Explicit persistent disk and in-memory cache for track artwork images.
/// Ensures album arts remain available offline without expiring.
public final class ImageCacheService: ObservableObject, @unchecked Sendable {
    public static let shared = ImageCacheService()

    private let memoryCache = NSCache<NSURL, PlatformImage>()
    private let fileManager = FileManager.default
    private let session: URLSession

    private var artworkDirectoryURL: URL {
        Track.documentsDirectory.appendingPathComponent("CachedArtwork", isDirectory: true)
    }

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
        try? ensureDirectoryExists()
    }

    private func ensureDirectoryExists() throws {
        if !fileManager.fileExists(atPath: artworkDirectoryURL.path) {
            try fileManager.createDirectory(at: artworkDirectoryURL, withIntermediateDirectories: true)
        }
    }

    private func diskFileURL(for url: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return artworkDirectoryURL.appendingPathComponent("\(hex).img")
    }

    /// Synchronously returns an image if present in memory or on disk.
    public func image(for url: URL?) -> PlatformImage? {
        guard let url = url else { return nil }
        if let memoryImage = memoryCache.object(forKey: url as NSURL) {
            return memoryImage
        }
        let fileURL = diskFileURL(for: url)
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let diskImage = PlatformImage(data: data) else {
            return nil
        }
        memoryCache.setObject(diskImage, forKey: url as NSURL)
        return diskImage
    }

    /// Loads the image from cache or downloads from the network and caches to disk.
    @discardableResult
    public func loadImage(for url: URL?) async -> PlatformImage? {
        guard let url = url else { return nil }
        if let existing = image(for: url) {
            return existing
        }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let loadedImage = PlatformImage(data: data) else {
                return nil
            }

            try? ensureDirectoryExists()
            let fileURL = diskFileURL(for: url)
            try? data.write(to: fileURL, options: .atomic)
            memoryCache.setObject(loadedImage, forKey: url as NSURL)
            return loadedImage
        } catch {
            return nil
        }
    }

    /// Prefetches and explicitly writes artwork to disk for offline availability.
    public func prefetch(url: URL?) {
        guard let url = url else { return }
        Task(priority: .background) {
            _ = await self.loadImage(for: url)
        }
    }

    /// Clears both in-memory and on-disk cached images.
    public func clearAllCache() {
        memoryCache.removeAllObjects()
        try? fileManager.removeItem(at: artworkDirectoryURL)
        try? ensureDirectoryExists()
    }
}
