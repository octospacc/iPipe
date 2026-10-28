import Foundation

public actor YouTubeDirectService {
    public static let shared = YouTubeDirectService()

    public struct AudioStream: Sendable {
        public let url: URL
        public let contentLength: Int64?
        public let userAgent: String
    }

    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - Video ID parsing

    public static func extractVideoId(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 11 && !trimmed.contains("/") && !trimmed.contains("?") && !trimmed.contains("&") && !trimmed.contains(" ") {
            return trimmed
        }
        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else { return nil }
        if host.contains("youtu.be") {
            let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return id.count == 11 ? id : nil
        }
        if host.contains("youtube.com") {
            if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "v" })?.value, v.count == 11 {
                return v
            }
            if url.path.contains("/embed/") || url.path.contains("/shorts/") {
                let id = url.lastPathComponent
                return id.count == 11 ? id : nil
            }
        }
        return nil
    }

    // MARK: - Metadata (oEmbed)

    public func fetchTrackByUrlOrId(_ input: String) async throws -> Track? {
        guard let videoId = Self.extractVideoId(from: input) else { return nil }

        var comps = URLComponents(string: "https://www.youtube.com/oembed")!
        comps.queryItems = [
            URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(videoId)"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = comps.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = json["title"] as? String else {
            throw URLError(.cannotParseResponse)
        }
        let author = json["author_name"] as? String ?? "Unknown Artist"
        let thumb = (json["thumbnail_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg")
        return Track(id: videoId, title: title, artist: author, durationSeconds: 0, thumbnailUrl: thumb)
    }

    // MARK: - Search (restored)

    public func search(query: String) async throws -> [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let direct = try? await fetchTrackByUrlOrId(trimmed) { return [direct] }

        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/search?prettyPrint=false") else {
            throw URLError(.badURL)
        }
        let payload: [String: Any] = [
            "context": ["client": ["clientName": "WEB", "clientVersion": "2.20240101.00.00", "hl": "en", "gl": "US"]],
            "query": trimmed
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        var results: [Track] = []
        let sections = (((((json["contents"] as? [String: Any])?["twoColumnSearchResultsRenderer"] as? [String: Any])?["primaryContents"] as? [String: Any])?["sectionListRenderer"] as? [String: Any])?["contents"] as? [[String: Any]]) ?? []

        for section in sections {
            let items = (section["itemSectionRenderer"] as? [String: Any])?["contents"] as? [[String: Any]] ?? []
            for item in items {
                guard let vr = item["videoRenderer"] as? [String: Any],
                      let videoId = vr["videoId"] as? String else { continue }

                let titleRuns = (vr["title"] as? [String: Any])?["runs"] as? [[String: Any]] ?? []
                let title = titleRuns.compactMap { $0["text"] as? String }.joined()
                guard !title.isEmpty else { continue }

                let ownerRuns = (vr["ownerText"] as? [String: Any])?["runs"] as? [[String: Any]] ?? []
                let author = ownerRuns.compactMap { $0["text"] as? String }.joined()

                var seconds: Double = 0
                if let dur = (vr["lengthText"] as? [String: Any])?["simpleText"] as? String {
                    seconds = parseDurationString(dur)
                }

                var thumb: URL? = nil
                if let thumbs = (vr["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]],
                   let last = thumbs.last, let s = last["url"] as? String {
                    thumb = URL(string: s)
                } else {
                    thumb = URL(string: "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg")
                }

                results.append(Track(id: videoId, title: title,
                                     artist: author.isEmpty ? "YouTube" : author,
                                     durationSeconds: seconds, thumbnailUrl: thumb))
            }
        }
        return results
    }

    private func parseDurationString(_ text: String) -> Double {
        let p = text.split(separator: ":").compactMap { Double($0) }
        switch p.count {
        case 3: return p[0] * 3600 + p[1] * 60 + p[2]
        case 2: return p[0] * 60 + p[1]
        case 1: return p[0]
        default: return 0
        }
    }

    // MARK: - Direct audio stream resolution (innertube player, POST)

    private struct ClientProfile {
        let name: String
        let version: String
        let headerId: String
        let userAgent: String
        let extra: [String: Any]
    }

    private func profiles() -> [ClientProfile] {
        [
            ClientProfile(
                name: "ANDROID_VR", version: "1.60.19", headerId: "28",
                userAgent: "com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
                extra: ["androidSdkVersion": 32, "deviceMake": "Oculus", "deviceModel": "Quest 3", "osName": "Android", "osVersion": "12L"]
            ),
            ClientProfile(
                name: "IOS", version: "19.45.4", headerId: "5",
                userAgent: "com.google.ios.youtube/19.45.4 (iPhone16,2; U; CPU iOS 18_1_0 like Mac OS X;)",
                extra: ["deviceMake": "Apple", "deviceModel": "iPhone16,2", "osName": "iPhone", "osVersion": "18.1.0.22B83"]
            )
        ]
    }

    /// Resolves a direct, AVPlayer-compatible (audio/mp4 AAC) stream URL straight from YouTube.
    public func resolveAudioStream(videoId: String) async throws -> AudioStream {
        guard let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false") else {
            throw URLError(.badURL)
        }
        var lastError: Error = URLError(.resourceUnavailable)

        for p in profiles() {
            do {
                var client: [String: Any] = ["clientName": p.name, "clientVersion": p.version, "hl": "en", "gl": "US"]
                client.merge(p.extra) { _, new in new }
                let payload: [String: Any] = [
                    "context": ["client": client],
                    "videoId": videoId,
                    "contentCheckOk": true,
                    "racyCheckOk": true
                ]
                var req = URLRequest(url: endpoint)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue(p.userAgent, forHTTPHeaderField: "User-Agent")
                req.setValue(p.headerId, forHTTPHeaderField: "X-YouTube-Client-Name")
                req.setValue(p.version, forHTTPHeaderField: "X-YouTube-Client-Version")
                req.httpBody = try JSONSerialization.data(withJSONObject: payload)

                let (data, response) = try await session.data(for: req)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw URLError(.badServerResponse)
                }
                let status = (json["playabilityStatus"] as? [String: Any])?["status"] as? String
                guard status == "OK" else { throw URLError(.resourceUnavailable) }

                let formats = (json["streamingData"] as? [String: Any])?["adaptiveFormats"] as? [[String: Any]] ?? []
                let candidates = formats.filter {
                    ($0["mimeType"] as? String)?.hasPrefix("audio/mp4") == true && $0["url"] is String
                }.sorted { (($0["bitrate"] as? Int) ?? 0) > (($1["bitrate"] as? Int) ?? 0) }

                if let best = candidates.first,
                   let s = best["url"] as? String, let url = URL(string: s) {
                    let length = (best["contentLength"] as? String).flatMap { Int64($0) }
                    return AudioStream(url: url, contentLength: length, userAgent: p.userAgent)
                }
                throw URLError(.cannotParseResponse)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    public func resolveAudioStreamURL(videoId: String) async throws -> URL {
        try await resolveAudioStream(videoId: videoId).url
    }
}
