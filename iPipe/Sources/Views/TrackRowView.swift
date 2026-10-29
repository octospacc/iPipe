import SwiftUI

public struct TrackRowView: View {
    public let track: Track
    public let onPlay: () -> Void
    public var onAddToPlaylist: (() -> Void)? = nil
    public var onRemove: (() -> Void)? = nil
    public var removeHelpText: String = "Remove"
    
    @ObservedObject private var cacheService = CacheService.shared
    @ObservedObject private var storageService = StorageService.shared
    
    public init(
        track: Track,
        onPlay: @escaping () -> Void,
        onAddToPlaylist: (() -> Void)? = nil,
        onRemove: (() -> Void)? = nil,
        removeHelpText: String = "Remove"
    ) {
        self.track = track
        self.onPlay = onPlay
        self.onAddToPlaylist = onAddToPlaylist
        self.onRemove = onRemove
        self.removeHelpText = removeHelpText
    }
    
    private var isDownloaded: Bool {
        cacheService.isTrackDownloaded(trackId: track.id)
    }
    
    private var isDownloading: Bool {
        cacheService.activeDownloads.contains(track.id)
    }
    
    private var progress: Double {
        cacheService.downloadProgress[track.id] ?? 0.0
    }
    
    public var body: some View {
        HStack(spacing: 12) {
            // Artwork
            CachedArtworkView(url: track.thumbnailUrl, cornerRadius: 8, contentMode: .fill)
                .frame(width: 52, height: 52)
            
            // Track Info
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                
                HStack(spacing: 6) {
                    Text(track.artist)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    
                    if track.durationSeconds > 0 {
                        Text("•")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(track.formattedDuration)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    if isDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                    }
                }
            }
            
            Spacer()
            
            // Actions
            HStack(spacing: 14) {
                // Download button
                if isDownloading {
                    ProgressView(value: progress)
                        .progressViewStyle(CircularProgressViewStyle())
                        .frame(width: 24, height: 24)
                } else if isDownloaded {
                    Button(action: {
                        cacheService.deleteTrackAudio(trackId: track.id)
                        storageService.updateTrackLocalPath(trackId: track.id, relativePath: nil)
                    }) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Remove downloaded file")
                } else {
                    Button(action: {
                        Task {
                            storageService.saveTrack(track)
                            if let path = try? await cacheService.downloadTrack(track: track) {
                                storageService.updateTrackLocalPath(trackId: track.id, relativePath: path)
                            }
                        }
                    }) {
                        Image(systemName: "arrow.down.circle")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Download for offline playback")
                }
                
                // Add to playlist
                if let onAddToPlaylist = onAddToPlaylist {
                    Button(action: onAddToPlaylist) {
                        Image(systemName: "plus.circle")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Add to playlist")
                }
                
                // Share
                if let shareURL = track.shareURL {
                    ShareLink(item: shareURL) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Share YouTube Music link")
                }
                
                // Remove from the current list
                if let onRemove = onRemove {
                    Button(action: onRemove) {
                        Image(systemName: "trash")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(removeHelpText)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onPlay()
        }
        .padding(.vertical, 4)
    }
}
