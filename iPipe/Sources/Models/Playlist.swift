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

    
    /// Builds an account-less YouTube playlist link from chained video IDs with an optional title
    /// (`www.youtube.com/watch_videos?video_ids=...&title=...`).
    public static func youTubeMusicLink(videoIds: [String], title: String? = nil) -> URL? {
        guard !videoIds.isEmpty else { return nil }
        var components = URLComponents(string: "https://www.youtube.com/watch_videos")
        var queryItems = [URLQueryItem(name: "video_ids", value: videoIds.joined(separator: ","))]
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            queryItems.append(URLQueryItem(name: "title", value: title))
        }
        components?.queryItems = queryItems
        return components?.url
    }
}
