import Foundation

public struct Track: Identifiable, Codable, Hashable, Sendable {
    public let id: String // YouTube video ID
    public let title: String
    public let artist: String
    public let durationSeconds: Double
    public let thumbnailUrl: URL?
    public var localAudioRelativePath: String? // Relative to app's documents directory
    public let dateAdded: Date
    
    public init(
        id: String,
        title: String,
        artist: String,
        durationSeconds: Double = 0,
        thumbnailUrl: URL? = nil,
        localAudioRelativePath: String? = nil,
        dateAdded: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.durationSeconds = durationSeconds
        self.thumbnailUrl = thumbnailUrl
        self.localAudioRelativePath = localAudioRelativePath
        self.dateAdded = dateAdded
    }
    
    public var isDownloaded: Bool {
        guard let path = localAudioRelativePath else { return false }
        let fullPath = Track.documentsDirectory.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: fullPath.path)
    }
    
    public var localAudioURL: URL? {
        guard let path = localAudioRelativePath else { return nil }
        let url = Track.documentsDirectory.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    
    public var formattedDuration: String {
        let total = Int(durationSeconds)
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }
    
    public static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}
