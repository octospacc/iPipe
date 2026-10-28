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
        NavigationStack {
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
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.title)
                                        .font(.headline)
                                    Text("\(playlist.trackIds.count) tracks")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                if containsTrack {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .foregroundColor(.primary)
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .navigationTitle("Add to Playlist")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .primaryAction) {
                    Button(action: {
                        showNewPlaylistAlert = true
                    }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("New Playlist", isPresented: $showNewPlaylistAlert) {
                TextField("Playlist name", text: $newPlaylistTitle)
                Button("Create", action: {
                    let trimmed = newPlaylistTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        let newPl = storage.createPlaylist(title: trimmed)
                        storage.addTrackToPlaylist(track: track, playlistId: newPl.id)
                        newPlaylistTitle = ""
                    }
                })
                Button("Cancel", role: .cancel) {
                    newPlaylistTitle = ""
                }
            }
        }
    }
}
