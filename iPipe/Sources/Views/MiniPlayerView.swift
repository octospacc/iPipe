import SwiftUI

public struct MiniPlayerView: View {
    @ObservedObject private var player = AudioPlayerService.shared
    public let onExpand: () -> Void
    
    public var body: some View {
        if let track = player.currentTrack {
            VStack(spacing: 0) {
                // Progress bar line
                GeometryReader { geo in
                    let progress = player.duration > 0 ? player.currentTime / player.duration : 0
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 2)
                        
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * CGFloat(progress), height: 2)
                    }
                }
                .frame(height: 2)
                
                HStack(spacing: 12) {
                    // Artwork
                    CachedArtworkView(url: track.thumbnailUrl, cornerRadius: 6, contentMode: .fill)
                        .frame(width: 44, height: 44)
                    
                    // Titles
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        
                        Text(track.artist)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    
                    Spacer()
                    
                    // Controls
                    HStack(spacing: 16) {
                        if player.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button(action: {
                                player.togglePlayPause()
                            }) {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)
                        }
                        
                        Button(action: {
                            player.next()
                        }) {
                            Image(systemName: "forward.fill")
                                .font(.body)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.trailing, 8)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onExpand()
            }
        }
    }
}
