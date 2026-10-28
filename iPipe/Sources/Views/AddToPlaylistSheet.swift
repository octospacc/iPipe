import SwiftUI

public struct AddToPlaylistSheet: View {
    public let track: Track
    @ObservedObject private var storage = StorageService.shared
    @Environment(\.dismiss) private var dismiss
    
    @State private var showNewPlaylistAlert: Bool = false
    @State private var newPlaylistTitle: String = ""
    
    public init(track: Track) {
        self.track = track
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header (works the same on macOS sheets and iOS).
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add to Playlist")
                        .font(.title2.bold())
                    Text(track.title)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            
            Divider()
            
            if storage.playlists.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("No playlists yet")
                        .font(.headline)
                    Text("Create a playlist to add this song.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                List {
                    Section(header: Text("Your Playlists")) {
                        ForEach(storage.playlists) { playlist in
                            let containsTrack = playlist.trackIds.contains(track.id)
                            Button(action: {
                                if containsTrack {
                                    storage.removeTrackFromPlaylist(trackId: track.id, playlistId: playlist.id)
                                } else {
                                    storage.addTrackToPlaylist(track: track, playlistId: playlist.id)
                                }
                            }) {
                                HStack(spacing: 12) {
                                    Image(systemName: containsTrack ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(containsTrack ? .accentColor : .secondary)
                                        .font(.title3)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(playlist.title)
                                            .font(.headline)
                                            .foregroundColor(.primary)
                                        Text("\(playlist.trackIds.count) tracks")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #else
                .listStyle(.inset)
                #endif
            }
            
            Divider()
            
            Button(action: {
                showNewPlaylistAlert = true
            }) {
                Label("New Playlist", systemImage: "plus")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .padding(16)
        }
        #if os(macOS)
        .frame(minWidth: 400, idealWidth: 440, minHeight: 440, idealHeight: 520)
        #endif
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #endif
        .alert("New Playlist", isPresented: $showNewPlaylistAlert) {
            TextField("Playlist name", text: $newPlaylistTitle)
            Button("Create", action: {
                let trimmed = newPlaylistTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let newPlaylist = storage.createPlaylist(title: trimmed)
                    storage.addTrackToPlaylist(track: track, playlistId: newPlaylist.id)
                    newPlaylistTitle = ""
                }
            })
            Button("Cancel", role: .cancel) {
                newPlaylistTitle = ""
            }
        }
    }
}
