import Foundation

public struct Playlist: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var description: String
    public var trackIds: [String]
    public let createdAt: Date
    public var updatedAt: Date
    
    public init(
        id: UUID = UUID(),
        title: String,
        description: String = "",
        trackIds: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.trackIds = trackIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    
    /// Builds an account-less YouTube (standard, as Music does not support it) playlist link from chained video IDs
    /// (`www.youtube.com/watch_videos?video_ids=...`).
    public static func youTubeMusicLink(videoIds: [String]) -> URL? {
        guard !videoIds.isEmpty else { return nil }
        var components = URLComponents(string: "https://www.youtube.com/watch_videos")
        components?.queryItems = [URLQueryItem(name: "video_ids", value: videoIds.joined(separator: ","))]
        return components?.url
    }
}
