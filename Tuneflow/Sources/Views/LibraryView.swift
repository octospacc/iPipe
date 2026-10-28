import SwiftUI

public struct LibraryView: View {
    @ObservedObject private var storage = StorageService.shared
    @ObservedObject private var cache = CacheService.shared
    @ObservedObject private var player = AudioPlayerService.shared
    
    @State private var showingCreatePlaylist = false
    @State private var newPlaylistTitle = ""
    @State private var selectedFilter: LibraryFilter = .all
    @State private var selectedTrackForPlaylist: Track?
    
    public enum LibraryFilter: String, CaseIterable, Identifiable {
        case all = "All Songs"
        case downloaded = "Downloaded"
        case playlists = "Playlists"
        case history = "History"
        
        public var id: String { rawValue }
    }
    
    public init() {}
    
    private var allSavedTracks: [Track] {
        Array(storage.savedTracks.values).sorted { $0.dateAdded > $1.dateAdded }
    }
    
    private var downloadedTracks: [Track] {
        allSavedTracks.filter { cache.isTrackDownloaded(trackId: $0.id) }
    }
    
    private var historyTracks: [Track] {
        storage.history.map(\.track)
    }
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Filter Picker
                Picker("Filter", selection: $selectedFilter) {
                    ForEach(LibraryFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                
                // Content based on filter
                switch selectedFilter {
                case .all:
                    trackListView(
                        tracks: allSavedTracks,
                        emptyMessage: "No saved tracks yet. Search and play or download music to build your local library.",
                        emptyIcon: "music.note.list",
                        removeHelpText: "Remove from library",
                        onRemove: removeFromLibrary
                    )
                case .downloaded:
                    trackListView(
                        tracks: downloadedTracks,
                        emptyMessage: "No downloaded music for offline playback. Tap the download icon next to any song to store it locally.",
                        emptyIcon: "arrow.down.circle",
                        removeHelpText: "Remove download",
                        onRemove: removeDownload
                    )
                case .history:
                    trackListView(
                        tracks: historyTracks,
                        emptyMessage: "No listening history yet. Songs you play will show up here.",
                        emptyIcon: "clock.arrow.circlepath",
                        removeHelpText: "Remove from history",
                        onRemove: removeFromHistory
                    )
                case .playlists:
                    playlistListView
                }
            }
            .navigationTitle("Your Library")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: {
                        showingCreatePlaylist = true
                    }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("Create Playlist", isPresented: $showingCreatePlaylist) {
                TextField("Playlist Name", text: $newPlaylistTitle)
                Button("Create") {
                    let trimmed = newPlaylistTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        _ = storage.createPlaylist(title: trimmed)
                        newPlaylistTitle = ""
                    }
                }
                Button("Cancel", role: .cancel) {
                    newPlaylistTitle = ""
                }
            }
            .sheet(item: $selectedTrackForPlaylist) { track in
                AddToPlaylistSheet(track: track)
            }
        }
    }
    
    @ViewBuilder
    private func trackListView(
        tracks: [Track],
        emptyMessage: String,
        emptyIcon: String,
        removeHelpText: String,
        onRemove: @escaping (Track) -> Void
    ) -> some View {
        if tracks.isEmpty {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: emptyIcon)
                    .font(.system(size: 48))
                    .foregroundColor(.secondary.opacity(0.6))
                Text(emptyMessage)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
        } else {
            List {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    TrackRowView(
                        track: track,
                        onPlay: {
                            player.playQueue(tracks: tracks, startIndex: index)
                        },
                        onAddToPlaylist: {
                            selectedTrackForPlaylist = track
                        },
                        onRemove: {
                            onRemove(track)
                        },
                        removeHelpText: removeHelpText
                    )
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        onRemove(tracks[index])
                    }
                }
            }
            .listStyle(.plain)
        }
    }
    
    private var playlistListView: some View {
        List {
            ForEach(storage.playlists) { playlist in
                NavigationLink(destination: PlaylistDetailView(playlistId: playlist.id)) {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.accentColor.opacity(0.15))
                                .frame(width: 48, height: 48)
                            Image(systemName: "music.note.list")
                                .foregroundColor(.accentColor)
                                .font(.title3)
                        }
                        
                        VStack(alignment: .leading, spacing: 3) {
                            Text(playlist.title)
                                .font(.headline)
                            Text("\(playlist.trackIds.count) tracks")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    let playlist = storage.playlists[index]
                    storage.deletePlaylist(id: playlist.id)
                }
            }
        }
        .listStyle(.plain)
    }
    
    // MARK: - Removal
    
    private func removeFromLibrary(_ track: Track) {
        cache.deleteTrackAudio(trackId: track.id)
        storage.removeTrack(trackId: track.id)
    }
    
    private func removeDownload(_ track: Track) {
        cache.deleteTrackAudio(trackId: track.id)
        storage.updateTrackLocalPath(trackId: track.id, relativePath: nil)
    }
    
    private func removeFromHistory(_ track: Track) {
        storage.removeHistoryEntry(trackId: track.id)
    }
}
