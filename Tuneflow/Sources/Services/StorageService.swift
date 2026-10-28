import Foundation
import Combine

public final class StorageService: ObservableObject, @unchecked Sendable {
    public static let shared = StorageService()
    
    @Published public private(set) var savedTracks: [String: Track] = [:]
    @Published public private(set) var playlists: [Playlist] = []
    
    private let tracksFileURL: URL
    private let playlistsFileURL: URL
    private let queue = DispatchQueue(label: "com.tuneflow.storage", qos: .utility)
    
    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.tracksFileURL = docs.appendingPathComponent("library_tracks.json")
        self.playlistsFileURL = docs.appendingPathComponent("library_playlists.json")
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
    }
    
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
    
    public func removeTrackFromPlaylist(trackId: String, playlistId: UUID) {
        if let index = playlists.firstIndex(where: { $0.id == playlistId }) {
            playlists[index].trackIds.removeAll { $0 == trackId }
            playlists[index].updatedAt = Date()
            persistPlaylists()
        }
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
}
