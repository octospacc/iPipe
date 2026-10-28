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
}
