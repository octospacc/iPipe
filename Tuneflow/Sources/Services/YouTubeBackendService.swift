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
    
    // Default public reliable Invidious/Piped instances with fallbacks
    private var instances: [InvidiousInstance] = [
        InvidiousInstance(host: "inv.nadeko.net"),
        InvidiousInstance(host: "invidious.nerdvpn.de"),
        InvidiousInstance(host: "invidious.private.coffee"),
        InvidiousInstance(host: "vid.puffyan.us"),
        InvidiousInstance(host: "invidious.projectsegfau.lt")
    ]
    
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
        
        let targetInstances: [InvidiousInstance]
        if let custom = customBaseURL, let host = custom.host {
            targetInstances = [InvidiousInstance(host: host, isHttps: custom.scheme == "https")]
        } else {
            targetInstances = instances
        }
        
        var lastError: Error?
        for instance in targetInstances {
            do {
                return try await searchInstance(instance: instance, query: query)
            } catch {
                lastError = error
                continue
            }
        }
        
        throw lastError ?? URLError(.badServerResponse)
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
    public func resolveAudioStreamURL(videoId: String) async throws -> URL {
        let targetInstances: [InvidiousInstance]
        if let custom = customBaseURL, let host = custom.host {
            targetInstances = [InvidiousInstance(host: host, isHttps: custom.scheme == "https")]
        } else {
            targetInstances = instances
        }
        
        var lastError: Error?
        for instance in targetInstances {
            do {
                return try await resolveStreamFromInstance(instance: instance, videoId: videoId)
            } catch {
                lastError = error
                continue
            }
        }
        
        throw lastError ?? URLError(.cannotFindHost)
    }
    
    private func resolveStreamFromInstance(instance: InvidiousInstance, videoId: String) async throws -> URL {
        let url = instance.baseURL.appendingPathComponent("api/v1/videos/\(videoId)")
        var request = URLRequest(url: url)
        request.setValue("Tuneflow/1.0 (iOS/macOS; Anonymous Native Music Player)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        
        // 1. Look for adaptiveFormats with audio
        if let adaptive = json["adaptiveFormats"] as? [[String: Any]] {
            let audioFormats = adaptive.filter {
                let type = $0["type"] as? String ?? ""
                return type.contains("audio")
            }
            
            // Prefer m4a / mp4 audio or best bitrate audio
            let sorted = audioFormats.sorted {
                let bitrate1 = ($0["bitrate"] as? String).flatMap(Int.init) ?? ($0["bitrate"] as? Int ?? 0)
                let bitrate2 = ($1["bitrate"] as? String).flatMap(Int.init) ?? ($1["bitrate"] as? Int ?? 0)
                return bitrate1 > bitrate2
            }
            
            if let best = sorted.first, let urlStr = best["url"] as? String, let streamURL = URL(string: urlStr) {
                return streamURL
            }
        }
        
        // 2. Look for formatStreams (combined video+audio fallback)
        if let formatStreams = json["formatStreams"] as? [[String: Any]], let first = formatStreams.first, let urlStr = first["url"] as? String, let streamURL = URL(string: urlStr) {
            return streamURL
        }
        
        // 3. Fallback to direct proxy stream endpoint provided by Invidious
        let fallbackProxyURL = instance.baseURL.appendingPathComponent("latest_version").appending(queryItems: [
            URLQueryItem(name: "id", value: videoId),
            URLQueryItem(name: "itag", value: "140") // itag 140 is 128kbps AAC M4A
        ])
        return fallbackProxyURL
    }
}
