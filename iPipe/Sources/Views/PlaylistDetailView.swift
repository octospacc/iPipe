import SwiftUI

public struct PlaylistDetailView: View {
    public let playlistId: UUID
    @ObservedObject private var storage = StorageService.shared
    @ObservedObject private var player = AudioPlayerService.shared
    
    @Environment(\.dismiss) private var dismiss
    @State private var showingDeleteConfirmation = false
    @State private var selectedTrackForPlaylist: Track?
    @State private var playlistTitle: String = ""
    @State private var isNowPlayingExpanded: Bool = false
    
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
        guard let pl = playlist else { return nil }
        let currentTitle = playlistTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleToUse = currentTitle.isEmpty ? pl.title : currentTitle
        return Playlist.youTubeMusicLink(videoIds: tracks.map(\.id), title: titleToUse)
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
        #if os(macOS)
        VStack(spacing: 0) {
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            
            if player.currentTrack != nil {
                MiniPlayerView(onExpand: {
                    isNowPlayingExpanded = true
                })
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $isNowPlayingExpanded) {
            NowPlayingView()
                .frame(minWidth: 440, idealWidth: 480, minHeight: 620, idealHeight: 720)
        }
        #else
        mainContent
        #endif
    }
    
    @ViewBuilder
    private var mainContent: some View {
        Group {
            if let pl = playlist {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Playlist Name", text: $playlistTitle)
                                .font(.title.bold())
                                .textFieldStyle(.plain)
                                .onSubmit {
                                    saveTitle()
                                }
                                .onChange(of: playlistTitle) { _ in
                                    saveTitle()
                                }
                            
                            if !pl.description.isEmpty {
                                Text(pl.description)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            Text("\(tracks.count) songs")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                            
                            if !tracks.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 12) {
                                        Button(action: {
                                            // "Play All" means in order, so honour that explicitly.
                                            player.isShuffle = false
                                            player.playQueue(tracks: tracks, startIndex: 0)
                                        }) {
                                            Label("Play All", systemImage: "play.fill")
                                                .font(.headline)
                                                .lineLimit(1)
                                                .fixedSize(horizontal: true, vertical: false)
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
                                                .lineLimit(1)
                                                .fixedSize(horizontal: true, vertical: false)
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
                                                .lineLimit(1)
                                                .fixedSize(horizontal: true, vertical: false)
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
                                .contextMenu {
                                    if index > 0 {
                                        Button {
                                            storage.moveTrackInPlaylist(playlistId: playlistId, from: IndexSet(integer: index), to: index - 1)
                                        } label: {
                                            Label("Move Up", systemImage: "arrow.up")
                                        }
                                    }
                                    if index < tracks.count - 1 {
                                        Button {
                                            storage.moveTrackInPlaylist(playlistId: playlistId, from: IndexSet(integer: index), to: index + 2)
                                        } label: {
                                            Label("Move Down", systemImage: "arrow.down")
                                        }
                                    }
                                    Divider()
                                    Button(role: .destructive) {
                                        storage.removeTrackFromPlaylist(trackId: track.id, playlistId: playlistId)
                                    } label: {
                                        Label("Remove from Playlist", systemImage: "trash")
                                    }
                                }
                            }
                            .onDelete { indexSet in
                                for index in indexSet {
                                    let trackId = tracks[index].id
                                    storage.removeTrackFromPlaylist(trackId: trackId, playlistId: playlistId)
                                }
                            }
                            .onMove { indices, newOffset in
                                storage.moveTrackInPlaylist(playlistId: playlistId, from: indices, to: newOffset)
                            }
                        }
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #else
                .listStyle(.inset)
                #endif
                .navigationTitle(playlistTitle.isEmpty ? pl.title : playlistTitle)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
            } else {
                Text("Playlist not found")
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            if let pl = playlist {
                playlistTitle = pl.title
            }
        }
        .onChange(of: playlist?.title) { newTitle in
            if let newTitle = newTitle, playlistTitle != newTitle {
                playlistTitle = newTitle
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                #if os(iOS)
                if !tracks.isEmpty {
                    EditButton()
                }
                #endif
                
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
    
    private func saveTitle() {
        let trimmed = playlistTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let current = playlist, current.title != trimmed {
            storage.renamePlaylist(id: playlistId, newTitle: trimmed)
        }
    }
}
