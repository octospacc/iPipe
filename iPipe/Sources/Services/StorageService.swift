import Foundation
import Combine

public final class StorageService: ObservableObject, @unchecked Sendable {
    public static let shared = StorageService()

    @Published public private(set) var savedTracks: [String: Track] = [:]
    @Published public private(set) var playlists: [Playlist] = []
    @Published public private(set) var history: [PlaybackHistoryEntry] = []

    private let tracksFileURL: URL
    private let playlistsFileURL: URL
    private let historyFileURL: URL
    private let sessionFileURL: URL
    private let queue = DispatchQueue(label: "org.eu.octt.iPipe.storage", qos: .utility)

    private let maxHistoryEntries = 200

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.tracksFileURL = docs.appendingPathComponent("library_tracks.json")
        self.playlistsFileURL = docs.appendingPathComponent("library_playlists.json")
        self.historyFileURL = docs.appendingPathComponent("playback_history.json")
        self.sessionFileURL = docs.appendingPathComponent("last_playback_session.json")
        loadData()
    }

    private func loadData() {
        if let data = try? Data(contentsOf: tracksFileURL),
           let decoded = try? JSONDecoder().decode([String: Track].self, from: data) {
            self.savedTracks = decoded
        }

        if let data = try? Data(contentsOf: playlistsFileURL),
           let decoded = try? JSONDecoder().decode([Playlist].self, from: data) {
            self.playlists = decoded
        } else {
            // Seed a default "Favorites" playlist if brand new
            let favorites = Playlist(title: "Favorites", description: "Your favorite songs")
            self.playlists = [favorites]
            persistPlaylists()
        }

        if let data = try? Data(contentsOf: historyFileURL),
           let decoded = try? JSONDecoder().decode([PlaybackHistoryEntry].self, from: data) {
            self.history = decoded
        }
    }

    // MARK: - Library

    public func saveTrack(_ track: Track) {
        queue.async {
            DispatchQueue.main.async {
                self.savedTracks[track.id] = track
                self.persistTracks()
            }
        }
    }

    public func updateTrackLocalPath(trackId: String, relativePath: String?) {
        queue.async {
            DispatchQueue.main.async {
                if var track = self.savedTracks[trackId] {
                    track.localAudioRelativePath = relativePath
                    self.savedTracks[trackId] = track
                    self.persistTracks()
                }
            }
        }
    }

    public func removeTrack(trackId: String) {
        queue.async {
            DispatchQueue.main.async {
                self.savedTracks.removeValue(forKey: trackId)
                // Remove from all playlists
                for index in self.playlists.indices {
                    self.playlists[index].trackIds.removeAll { $0 == trackId }
                }
                self.persistTracks()
                self.persistPlaylists()
            }
        }
    }

    // MARK: - Playlists

    public func createPlaylist(title: String, description: String = "") -> Playlist {
        let newPlaylist = Playlist(title: title, description: description)
        playlists.append(newPlaylist)
        persistPlaylists()
        return newPlaylist
    }

    public func updatePlaylist(_ playlist: Playlist) {
        if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[index] = playlist
            playlists[index].updatedAt = Date()
            persistPlaylists()
        }
    }

    public func renamePlaylist(id: UUID, newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let index = playlists.firstIndex(where: { $0.id == id }) {
            playlists[index].title = trimmed
            playlists[index].updatedAt = Date()
            persistPlaylists()
        }
    }

    public func moveTrackInPlaylist(playlistId: UUID, from source: IndexSet, to destination: Int) {
        if let index = playlists.firstIndex(where: { $0.id == playlistId }) {
            playlists[index].trackIds.move(fromOffsets: source, toOffset: destination)
            playlists[index].updatedAt = Date()
            persistPlaylists()
        }
    }

    public func deletePlaylist(id: UUID) {
        playlists.removeAll { $0.id == id }
        persistPlaylists()
    }

    public func addTrackToPlaylist(track: Track, playlistId: UUID) {
        saveTrack(track)
        if let index = playlists.firstIndex(where: { $0.id == playlistId }) {
            if !playlists[index].trackIds.contains(track.id) {
                playlists[index].trackIds.append(track.id)
                playlists[index].updatedAt = Date()
                persistPlaylists()
            }
        }
    }

    /// Saves the tracks and creates a playlist in one step (used by playlist import).
    @discardableResult
    public func importPlaylist(title: String, tracks: [Track], description: String = "Imported from YouTube") -> Playlist {
        var seen = Set<String>()
        var ordered: [Track] = []
        for track in tracks where seen.insert(track.id).inserted {
            ordered.append(track)
        }
        for track in ordered {
            self.savedTracks[track.id] = track
        }
        persistTracks()

        let playlist = Playlist(title: title, description: description, trackIds: ordered.map(\.id))
        playlists.append(playlist)
        persistPlaylists()
        return playlist
    }
    
    public func removeTrackFromPlaylist(trackId: String, playlistId: UUID) {
        if let index = playlists.firstIndex(where: { $0.id == playlistId }) {
            playlists[index].trackIds.removeAll { $0 == trackId }
            playlists[index].updatedAt = Date()
            persistPlaylists()
        }
    }

    // MARK: - Listening history

    /// Records a played track, moving it to the top if it is already in the history.
    public func recordPlayed(_ track: Track) {
        DispatchQueue.main.async {
            self.history.removeAll { $0.track.id == track.id }
            self.history.insert(PlaybackHistoryEntry(track: track), at: 0)
            if self.history.count > self.maxHistoryEntries {
                self.history = Array(self.history.prefix(self.maxHistoryEntries))
            }
            self.persistHistory()
        }
    }

    public func removeHistoryEntry(trackId: String) {
        DispatchQueue.main.async {
            self.history.removeAll { $0.track.id == trackId }
            self.persistHistory()
        }
    }

    public func clearHistory() {
        DispatchQueue.main.async {
            self.history = []
            self.persistHistory()
        }
    }

    // MARK: - Playback Session Persistence

    public struct PersistedPlaybackSession: Codable, Sendable {
        public let queue: [Track]
        public let currentIndex: Int
        public let currentTime: Double

        public init(queue: [Track], currentIndex: Int, currentTime: Double) {
            self.queue = queue
            self.currentIndex = currentIndex
            self.currentTime = currentTime
        }
    }

    public func savePlaybackSession(queue: [Track], currentIndex: Int, currentTime: Double) {
        guard !queue.isEmpty else {
            try? FileManager.default.removeItem(at: sessionFileURL)
            return
        }
        let session = PersistedPlaybackSession(queue: queue, currentIndex: currentIndex, currentTime: currentTime)
        self.queue.async {
            if let data = try? JSONEncoder().encode(session) {
                try? data.write(to: self.sessionFileURL, options: .atomic)
            }
        }
    }

    public func loadPlaybackSession() -> PersistedPlaybackSession? {
        guard let data = try? Data(contentsOf: sessionFileURL),
              let session = try? JSONDecoder().decode(PersistedPlaybackSession.self, from: data),
              !session.queue.isEmpty else {
            return nil
        }
        return session
    }

    private func persistTracks() {
        let tracksToSave = self.savedTracks
        queue.async {
            if let data = try? JSONEncoder().encode(tracksToSave) {
                try? data.write(to: self.tracksFileURL, options: .atomic)
            }
        }
    }

    private func persistPlaylists() {
        let playlistsToSave = self.playlists
        queue.async {
            if let data = try? JSONEncoder().encode(playlistsToSave) {
                try? data.write(to: self.playlistsFileURL, options: .atomic)
            }
        }
    }

    private func persistHistory() {
        let historyToSave = self.history
        queue.async {
            if let data = try? JSONEncoder().encode(historyToSave) {
                try? data.write(to: self.historyFileURL, options: .atomic)
            }
        }
    }
}
