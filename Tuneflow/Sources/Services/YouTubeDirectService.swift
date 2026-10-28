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
    
    /// Queries YouTube directly using the official client endpoint without any proxy or API key
    public func search(query: String) async throws -> [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        
        // If user pasted a YouTube URL or Video ID directly, resolve it via oEmbed instantly
        if let directTrack = try? await fetchTrackByUrlOrId(trimmed) {
            return [directTrack]
        }
        
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/search?prettyPrint=false") else {
            throw URLError(.badURL)
        }
        
        let payload: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "WEB",
                    "clientVersion": "2.20240101.00.00",
                    "hl": "en",
                    "gl": "US"
                ]
            ],
            "query": trimmed
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        
        var results: [Track] = []
        
        // Parse section list items
        let contents = json["contents"] as? [String: Any]
        let twoCol = contents?["twoColumnSearchResultsRenderer"] as? [String: Any]
        let primary = twoCol?["primaryContents"] as? [String: Any]
        let sectionList = primary?["sectionListRenderer"] as? [String: Any]
        let sections = sectionList?["contents"] as? [[String: Any]] ?? []
        
        for section in sections {
            let itemSection = section["itemSectionRenderer"] as? [String: Any]
            let items = itemSection?["contents"] as? [[String: Any]] ?? []
            
            for item in items {
                guard let vr = item["videoRenderer"] as? [String: Any],
                      let videoId = vr["videoId"] as? String else {
                    continue
                }
                
                // Extract Title
                let titleRuns = (vr["title"] as? [String: Any])?["runs"] as? [[String: Any]] ?? []
                let title = titleRuns.compactMap { $0["text"] as? String }.joined()
                guard !title.isEmpty else { continue }
                
                // Extract Channel/Artist
                let ownerRuns = (vr["ownerText"] as? [String: Any])?["runs"] as? [[String: Any]] ?? []
                let author = ownerRuns.compactMap { $0["text"] as? String }.joined()
                
                // Extract Duration
                var seconds: Double = 0
                if let durText = (vr["lengthText"] as? [String: Any])?["simpleText"] as? String {
                    seconds = parseDurationString(durText)
                }
                
                // Extract Thumbnail
                var thumbUrl: URL? = nil
                if let thumbs = (vr["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]],
                   let last = thumbs.last,
                   let urlStr = last["url"] as? String {
                    thumbUrl = URL(string: urlStr)
                } else {
                    thumbUrl = URL(string: "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg")
                }
                
                let track = Track(
                    id: videoId,
                    title: title,
                    artist: author.isEmpty ? "YouTube Music" : author,
                    durationSeconds: seconds,
                    thumbnailUrl: thumbUrl
                )
                results.append(track)
            }
        }
        
        return results
    }
    
    private func parseDurationString(_ text: String) -> Double {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        if parts.count == 3 {
            return parts[0] * 3600 + parts[1] * 60 + parts[2]
        } else if parts.count == 2 {
            return parts[0] * 60 + parts[1]
        } else if parts.count == 1 {
            return parts[0]
        }
        return 0
    }
}
