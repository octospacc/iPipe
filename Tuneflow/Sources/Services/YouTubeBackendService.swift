import Foundation

public struct InvidiousInstance: Identifiable, Hashable, Codable, Sendable {
    public var id: String { host }
    public let host: String
    public let isHttps: Bool
    
    public init(host: String, isHttps: Bool = true) {
        self.host = host
        self.isHttps = isHttps
    }
    
    public var baseURL: URL {
        let scheme = isHttps ? "https" : "http"
        return URL(string: "\(scheme)://\(host)")!
    }
}

public actor YouTubeBackendService {
    public static let shared = YouTubeBackendService()
    
    // Removed Piped/Invidious instances as they are no longer used.
    private var instances: [InvidiousInstance] = []
    
    private var customBaseURL: URL? = nil
    private let session: URLSession
    
    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }
    
    public func setCustomInstance(urlString: String) {
        if let url = URL(string: urlString), url.host != nil {
            self.customBaseURL = url
        } else {
            self.customBaseURL = nil
        }
    }
    
    public func search(query: String) async throws -> [Track] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        // Use YouTubeDirectService for modern search logic
        return try await YouTubeDirectService.shared.search(query: query)
    }
    
    private func searchInstance(instance: InvidiousInstance, query: String) async throws -> [Track] {
        guard var components = URLComponents(url: instance.baseURL.appendingPathComponent("api/v1/search"), resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "video")
        ]
        
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.setValue("Tuneflow/1.0 (iOS/macOS; Anonymous Native Music Player)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        
        guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }
        
        var results: [Track] = []
        for item in jsonArray {
            guard let videoId = item["videoId"] as? String ?? item["id"] as? String,
                  let title = item["title"] as? String else {
                continue
            }
            
            let author = item["author"] as? String ?? item["uploaderName"] as? String ?? "Unknown Artist"
            let lengthSeconds = Double(item["lengthSeconds"] as? Int ?? item["duration"] as? Int ?? 0)
            
            var thumbURL: URL? = nil
            if let thumbs = item["videoThumbnails"] as? [[String: Any]], let first = thumbs.first, let urlStr = first["url"] as? String {
                thumbURL = URL(string: urlStr)
            } else if let thumbStr = item["thumbnail"] as? String {
                thumbURL = URL(string: thumbStr)
            } else {
                thumbURL = URL(string: "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg")
            }
            
            let track = Track(
                id: videoId,
                title: title,
                artist: author,
                durationSeconds: lengthSeconds,
                thumbnailUrl: thumbURL
            )
            results.append(track)
        }
        
        return results
    }
    
    /// Resolves the direct audio stream URL for a given YouTube video ID.
    /// Note: This is now deprecated in favor of YouTubeDirectService.
    public func resolveAudioStreamURL(videoId: String) async throws -> URL {
        return try await YouTubeDirectService.shared.resolveAudioStreamURL(videoId: videoId)
    }
    
    private func resolveStreamFromInstance(instance: InvidiousInstance, videoId: String) async throws -> URL {
        // This method is no longer used as we are moving to direct YouTube connection.
        throw URLError(.badURL)
    }
}
