import Foundation

/// Talks to YouTube directly: search through the public InnerTube web endpoint,
/// metadata through oEmbed, and audio stream resolution through the InnerTube
/// player endpoint.
public actor YouTubeDirectService {
    public static let shared = YouTubeDirectService()

    public struct AudioStream: Sendable {
        public let url: URL
        public let contentLength: Int64?
        public let userAgent: String
        public let durationSeconds: Double?
    }

    public enum ServiceError: LocalizedError {
        case invalidURL
        case httpStatus(Int)
        case videoUnavailable(String)
        case noAudioFormat

        public var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "YouTube returned an invalid URL."
            case .httpStatus(let code):
                return "YouTube returned HTTP \(code)."
            case .videoUnavailable(let reason):
                return reason.isEmpty ? "This video is unavailable on YouTube." : reason
            case .noAudioFormat:
                return "No playable audio stream was found for this video."
            }
        }
    }

    private let session: URLSession

    private static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.httpAdditionalHeaders = ["Accept-Language": "en-US,en;q=0.9"]
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
        guard let url = comps.url else { throw ServiceError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue(Self.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.httpStatus(-1) }
        guard (200...299).contains(http.statusCode) else { return nil }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = json["title"] as? String else {
            throw URLError(.cannotParseResponse)
        }
        let author = json["author_name"] as? String ?? "Unknown Artist"
        let thumb = (json["thumbnail_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg")
        return Track(id: videoId, title: title, artist: author, durationSeconds: 0, thumbnailUrl: thumb)
    }

    // MARK: - Search

    public func search(query: String) async throws -> [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // A pasted link or a bare video ID short-circuits to that single video.
        if let direct = try? await fetchTrackByUrlOrId(trimmed) { return [direct] }

        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/search?prettyPrint=false") else {
            throw ServiceError.invalidURL
        }
        let payload: [String: Any] = [
            "context": ["client": ["clientName": "WEB", "clientVersion": "2.20240101.00.00", "hl": "en", "gl": "US"]],
            "query": trimmed
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.httpStatus(-1) }
        guard (200...299).contains(http.statusCode) else { throw ServiceError.httpStatus(http.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        // Search responses already carry a visitor ID; reuse it for stream resolution
        // so playback does not have to bootstrap another session.
        if let rc = json["responseContext"] as? [String: Any],
           let visitor = rc["visitorData"] as? String, !visitor.isEmpty {
            cachedVisitorData = visitor
            visitorDataExpiry = Date().addingTimeInterval(30 * 60)
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
                if let dur = Self.simpleText(from: vr["lengthText"]) {
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

    // MARK: - Direct audio stream resolution (InnerTube player, POST)

    private struct ClientProfile {
        let name: String
        let version: String
        let headerId: String
        let userAgent: String
        let extra: [String: Any]
    }

    /// Clients that still return a signed, non-PoToken `url`.
    ///
    /// `VISIONOS` is first: unlike the web clients it does not need a PoToken, but it
    /// does need a real visitor session (cookies + `X-Goog-Visitor-Id`), which is
    /// bootstrapped from the YouTube home page. `ANDROID_VR` is the fallback.
    private func profiles() -> [ClientProfile] {
        [
            ClientProfile(
                name: "VISIONOS", version: "1.02", headerId: "101",
                userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
                extra: ["deviceMake": "Apple", "deviceModel": "RealityDevice17,1", "osName": "visionOS", "osVersion": "26.5.23O471"]
            ),
            ClientProfile(
                name: "ANDROID_VR", version: "1.62.27", headerId: "28",
                userAgent: "com.google.android.apps.youtube.vr.oculus/1.62.27 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
                extra: ["androidSdkVersion": 32, "deviceMake": "Oculus", "deviceModel": "Quest 3", "osName": "Android", "osVersion": "12L"]
            ),
            ClientProfile(
                name: "ANDROID_VR", version: "1.60.19", headerId: "28",
                userAgent: "com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
                extra: ["androidSdkVersion": 32, "deviceMake": "Oculus", "deviceModel": "Quest 3", "osName": "Android", "osVersion": "12L"]
            )
        ]
    }

    // MARK: - Visitor session
    //
    // YouTube's player endpoint refuses anonymous requests for most videos
    // ("Sign in to confirm you're not a bot") unless the request carries a visitor
    // ID created by a real browser session. Loading the home page once gives us the
    // visitorData value plus the cookies, and both are reused until they expire.

    private var cachedVisitorData: String?
    private var visitorDataExpiry: Date?
    private var lastVisitorAttempt: Date?

    private func ensureVisitorSession() async -> String? {
        if let cached = cachedVisitorData, let expiry = visitorDataExpiry, expiry > Date() {
            return cached
        }
        if let last = lastVisitorAttempt, Date().timeIntervalSince(last) < 60 {
            return cachedVisitorData
        }
        lastVisitorAttempt = Date()

        guard let url = URL(string: "https://www.youtube.com/") else { return cachedVisitorData }
        var request = URLRequest(url: url)
        request.setValue(Self.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return cachedVisitorData
            }
            if let visitor = Self.parseVisitorData(from: data) {
                cachedVisitorData = visitor
                visitorDataExpiry = Date().addingTimeInterval(30 * 60)
                #if DEBUG
                print("[iPipe] visitor session established (cookies: \(HTTPCookieStorage.shared.cookies?.count ?? 0))")
                #endif
            }
        } catch {
            #if DEBUG
            print("[iPipe] visitor session bootstrap failed: \(error.localizedDescription)")
            #endif
        }
        return cachedVisitorData
    }

    private static func parseVisitorData(from data: Data) -> String? {
        guard let html = String(data: data, encoding: .utf8) else { return nil }
        for token in ["\"visitorData\":\"", "\"VISITOR_DATA\":\""] {
            guard let start = html.range(of: token) else { continue }
            let rest = html[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            let value = String(rest[..<end])
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// Resolves a direct, AVPlayer-compatible (audio/mp4 AAC) stream URL straight from YouTube.
    public func resolveAudioStream(videoId: String) async throws -> AudioStream {
        guard let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false") else {
            throw ServiceError.invalidURL
        }
        let visitorData = await ensureVisitorSession()
        var reasons: [String] = []

        for p in profiles() {
            do {
                var client: [String: Any] = ["clientName": p.name, "clientVersion": p.version, "hl": "en", "gl": "US"]
                client.merge(p.extra) { _, new in new }
                if let visitorData { client["visitorData"] = visitorData }
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
                req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
                req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
                req.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
                if let visitorData {
                    req.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
                }
                req.httpBody = try JSONSerialization.data(withJSONObject: payload)

                let (data, response) = try await session.data(for: req)
                guard let http = response as? HTTPURLResponse else { throw ServiceError.httpStatus(-1) }
                guard (200...299).contains(http.statusCode) else { throw ServiceError.httpStatus(http.statusCode) }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw URLError(.cannotParseResponse)
                }
                // Refresh the cached visitor ID when YouTube hands us a newer one.
                if let rc = json["responseContext"] as? [String: Any],
                   let fresh = rc["visitorData"] as? String, !fresh.isEmpty {
                    cachedVisitorData = fresh
                    visitorDataExpiry = Date().addingTimeInterval(30 * 60)
                }
                return try parseStream(json, profile: p)
            } catch {
                let message = error.localizedDescription
                #if DEBUG
                print("[iPipe] stream client \(p.name) \(p.version) failed: \(message)")
                #endif
                reasons.append("\(p.name) \(p.version): \(message)")
            }
        }
        // Surface the most useful reason (usually "video unavailable").
        let summary = reasons.isEmpty ? "This video is unavailable on YouTube." : reasons.joined(separator: " | ")
        throw ServiceError.videoUnavailable(summary)
    }

    private func parseStream(_ json: [String: Any], profile: ClientProfile) throws -> AudioStream {
        let playability = json["playabilityStatus"] as? [String: Any]
        let status = playability?["status"] as? String
        if status != "OK" {
            let reason = (playability?["reason"] as? String) ?? status ?? ""
            throw ServiceError.videoUnavailable(reason)
        }

        let streaming = json["streamingData"] as? [String: Any]
        let adaptive = streaming?["adaptiveFormats"] as? [[String: Any]] ?? []
        let progressive = streaming?["formats"] as? [[String: Any]] ?? []
        let allFormats = adaptive + progressive

        func isAudioMP4(_ f: [String: Any]) -> Bool {
            guard let mime = f["mimeType"] as? String else { return false }
            return mime.hasPrefix("audio/mp4") && f["url"] is String
        }
        // Progressive MP4s contain AAC audio too, so they are a usable last resort.
        func isMuxedMP4(_ f: [String: Any]) -> Bool {
            guard let mime = f["mimeType"] as? String else { return false }
            return mime.hasPrefix("video/mp4") && mime.contains("mp4a") && f["url"] is String
        }

        var candidates = allFormats.filter(isAudioMP4)
        if candidates.isEmpty {
            candidates = allFormats.filter(isMuxedMP4)
        }
        candidates.sort { bitrate($0) > bitrate($1) }

        guard let best = candidates.first,
              let s = best["url"] as? String, let url = URL(string: s) else {
            throw ServiceError.noAudioFormat
        }

        var duration: Double? = nil
        if let details = json["videoDetails"] as? [String: Any] {
            if let raw = details["lengthSeconds"] as? String, let d = Double(raw), d > 0 {
                duration = d
            } else if let d = details["lengthSeconds"] as? NSNumber, d.doubleValue > 0 {
                duration = d.doubleValue
            }
        }

        return AudioStream(url: url,
                           contentLength: contentLength(best),
                           userAgent: profile.userAgent,
                           durationSeconds: duration)
    }

    private func bitrate(_ f: [String: Any]) -> Int {
        if let n = f["bitrate"] as? Int { return n }
        if let n = f["bitrate"] as? NSNumber { return n.intValue }
        return 0
    }

    private func contentLength(_ f: [String: Any]) -> Int64? {
        if let s = f["contentLength"] as? String { return Int64(s) }
        if let n = f["contentLength"] as? NSNumber { return n.int64Value }
        if let n = f["contentLength"] as? Int64 { return n }
        return nil
    }

    public func resolveAudioStreamURL(videoId: String) async throws -> URL {
        try await resolveAudioStream(videoId: videoId).url
    }

    /// YouTube sometimes sends `simpleText`, sometimes `runs`.
    private static func simpleText(from value: Any?) -> String? {
        guard let dict = value as? [String: Any] else { return nil }
        if let simple = dict["simpleText"] as? String { return simple }
        if let runs = dict["runs"] as? [[String: Any]] {
            return runs.compactMap { $0["text"] as? String }.joined()
        }
        return nil
    }
}
