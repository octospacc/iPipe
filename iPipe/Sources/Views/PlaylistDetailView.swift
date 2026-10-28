import SwiftUI

public struct PlaylistDetailView: View {
    public let playlistId: UUID
    @ObservedObject private var storage = StorageService.shared
    @ObservedObject private var player = AudioPlayerService.shared
    
    @Environment(\.dismiss) private var dismiss
    @State private var showingDeleteConfirmation = false
    @State private var selectedTrackForPlaylist: Track?
    
    public init(playlistId: UUID) {
        self.playlistId = playlistId
    }
    
    private var playlist: Playlist? {
        storage.playlists.first(where: { $0.id == playlistId })
    }
    
    private var tracks: [Track] {
        guard let pl = playlist else { return [] }
        return pl.trackIds.compactMap { storage.savedTracks[$0] }
    }
    
    private var playlistShareURL: URL? {
        Playlist.youTubeMusicLink(videoIds: tracks.map(\.id))
    }
    
    private var repeatTitle: String {
        switch player.repeatMode {
        case .off: return "Repeat"
        case .all: return "Repeat All"
        case .one: return "Repeat One"
        }
    }
    
    private var repeatHelp: String {
        switch player.repeatMode {
        case .off: return "Repeat is off"
        case .all: return "Repeating the whole playlist"
        case .one: return "Repeating the current song"
        }
    }
    
    public var body: some View {
        Group {
            if let pl = playlist {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(pl.title)
                                .font(.title.bold())
                            if !pl.description.isEmpty {
                                Text(pl.description)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            Text("\(tracks.count) songs")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                            
                            if !tracks.isEmpty {
                                HStack(spacing: 12) {
                                    Button(action: {
                                        // "Play All" means in order, so honour that explicitly.
                                        player.isShuffle = false
                                        player.playQueue(tracks: tracks, startIndex: 0)
                                    }) {
                                        Label("Play All", systemImage: "play.fill")
                                            .font(.headline)
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                            .background(Color.accentColor)
                                            .foregroundColor(.white)
                                            .cornerRadius(20)
                                    }
                                    .buttonStyle(.plain)
                                    
                                    Button(action: {
                                        player.isShuffle = true
                                        let shuffled = tracks.shuffled()
                                        player.playQueue(tracks: shuffled, startIndex: 0)
                                    }) {
                                        Label("Shuffle", systemImage: "shuffle")
                                            .font(.headline)
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                            .background(Color.gray.opacity(0.15))
                                            .cornerRadius(20)
                                    }
                                    .buttonStyle(.plain)
                                    
                                    Button(action: {
                                        player.cycleRepeatMode()
                                    }) {
                                        Label(repeatTitle, systemImage: player.repeatMode == .one ? "repeat.1" : "repeat")
                                            .font(.headline)
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                            .background(player.repeatMode == .off ? Color.gray.opacity(0.15) : Color.accentColor.opacity(0.15))
                                            .foregroundColor(player.repeatMode == .off ? .primary : .accentColor)
                                            .cornerRadius(20)
                                    }
                                    .buttonStyle(.plain)
                                    .help(repeatHelp)
                                }
                                .padding(.top, 4)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    
                    Section(header: Text("Tracks")) {
                        if tracks.isEmpty {
                            Text("No tracks in this playlist yet. Search YouTube and tap '+' to add tracks.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding(.vertical, 12)
                        } else {
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                                TrackRowView(
                                    track: track,
                                    onPlay: {
                                        player.playQueue(tracks: tracks, startIndex: index)
                                    },
                                    onAddToPlaylist: {
                                        selectedTrackForPlaylist = track
                                    }
                                )
                            }
                            .onDelete { indexSet in
                                for index in indexSet {
                                    let trackId = tracks[index].id
                                    storage.removeTrackFromPlaylist(trackId: trackId, playlistId: playlistId)
                                }
                            }
                        }
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #else
                .listStyle(.inset)
                #endif
                .navigationTitle(pl.title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
            } else {
                Text("Playlist not found")
                    .foregroundColor(.secondary)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let shareURL = playlistShareURL {
                    ShareLink(item: shareURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .help("Share playlist as a YouTube Music link")
                }
                
                Button(role: .destructive, action: {
                    showingDeleteConfirmation = true
                }) {
                    Image(systemName: "trash")
                }
                .help("Delete playlist")
            }
        }
        .alert("Delete Playlist?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                storage.deletePlaylist(id: playlistId)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\"\(playlist?.title ?? "This playlist")\" will be deleted. The songs themselves stay in your library.")
        }
        .sheet(item: $selectedTrackForPlaylist) { track in
            AddToPlaylistSheet(track: track)
        }
    }
}
