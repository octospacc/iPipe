import Foundation

public actor YouTubeDirectService {
    public static let shared = YouTubeDirectService()
    
    private let session: URLSession
    
    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }
    
    /// Parses a standard YouTube URL or ID into a clean 11-character video ID
    public static func extractVideoId(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 11 && !trimmed.contains("/") && !trimmed.contains("?") && !trimmed.contains("&") {
            return trimmed
        }
        
        // Match patterns like:
        // https://www.youtube.com/watch?v=VIDEO_ID
        // https://youtu.be/VIDEO_ID
        // https://www.youtube.com/embed/VIDEO_ID
        // https://music.youtube.com/watch?v=VIDEO_ID
        if let url = URL(string: trimmed) {
            if let host = url.host?.lowercased() {
                if host.contains("youtu.be") {
                    let pathId = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    if pathId.count == 11 { return pathId }
                } else if host.contains("youtube.com") {
                    if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                       let queryItems = components.queryItems,
                       let v = queryItems.first(where: { $0.name == "v" })?.value,
                       v.count == 11 {
                        return v
                    }
                    if url.path.contains("/embed/") {
                        let pathId = url.lastPathComponent
                        if pathId.count == 11 { return pathId }
                    }
                }
            }
        }
        
        return nil
    }
    
    /// Fetches track metadata directly for a specific video ID or URL using YouTube's official oEmbed endpoint
    public func fetchTrackByUrlOrId(_ input: String) async throws -> Track? {
        guard let videoId = Self.extractVideoId(from: input) else {
            return nil
        }
        
        guard let url = URL(string: "https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=\(videoId)&format=json") else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = json["title"] as? String else {
            throw URLError(.cannotParseResponse)
        }
        
        let author = json["author_name"] as? String ?? "Unknown Artist"
        let thumbUrl = (json["thumbnail_url"] as? String).flatMap(URL.init) ?? URL(string: "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg")
        
        return Track(
            id: videoId,
            title: title,
            artist: author,
            durationSeconds: 0,
            thumbnailUrl: thumbUrl
        )
    }
    
    /// Resolves the direct audio stream URL for a given YouTube video ID.
    /// This method fetches the video data from the internal YouTube API and selects the best audio format.
    public func resolveAudioStreamURL(videoId: String) async throws -> URL {
        let urlString = "https://www.youtube.com/youtubei/v1/player?videoId=\(videoId)&key="
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        
        if let formats = json["streamingData"] as? [String: Any],
           let formatsList = formats["adaptiveFormats"] as? [[String: Any]] {
            let audioFormats = formatsList.filter {
                let type = $0["type"] as? String ?? ""
                return type.contains("audio")
            }
            
            let sorted = audioFormats.sorted {
                let bitrate1 = ($0["bitrate"] as? String).flatMap(Int.init) ?? ($0["bitrate"] as? Int ?? 0)
                let bitrate2 = ($1["bitrate"] as? String).flatMap(Int.init) ?? ($1["bitrate"] as? Int ?? 0)
                return bitrate1 > bitrate2
            }
            
            if let best = sorted.first, let urlStr = best["url"] as? String, let streamURL = URL(string: urlStr) {
                return streamURL
            }
        }
        
        throw URLError(.badURL)
    }
}
