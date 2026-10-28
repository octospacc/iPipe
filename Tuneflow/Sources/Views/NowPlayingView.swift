import SwiftUI

public struct NowPlayingView: View {
    @ObservedObject private var player = AudioPlayerService.shared
    @ObservedObject private var cacheService = CacheService.shared
    @ObservedObject private var storageService = StorageService.shared
    @Environment(\.dismiss) private var dismiss
    
    @State private var sliderValue: Double = 0
    @State private var isDragging: Bool = false
    
    public init() {}
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                
                // Big Album Art
                if let track = player.currentTrack {
                    AsyncImage(url: track.thumbnailUrl) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFit()
                        default:
                            ZStack {
                                Color.gray.opacity(0.2)
                                Image(systemName: "music.note")
                                    .font(.system(size: 64))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: 320, maxHeight: 320)
                    .cornerRadius(16)
                    .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 8)
                    
                    // Metadata
                    VStack(spacing: 6) {
                        Text(track.title)
                            .font(.title2)
                            .fontWeight(.bold)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                        
                        Text(track.artist)
                            .font(.title3)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 24)
                    
                    // Timeline & Slider
                    VStack(spacing: 8) {
                        Slider(
                            value: $sliderValue,
                            in: 0...max(player.duration, 1),
                            onEditingChanged: { editing in
                                isDragging = editing
                                if !editing {
                                    player.seek(to: sliderValue)
                                }
                            }
                        )
                        .accentColor(.accentColor)
                        .onReceive(player.$currentTime) { newTime in
                            if !isDragging {
                                sliderValue = newTime
                            }
                        }
                        
                        HStack {
                            Text(formatTime(isDragging ? sliderValue : player.currentTime))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(formatTime(player.duration))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 28)
                    
                    // Main Controls
                    HStack(spacing: 40) {
                        Button(action: {
                            player.isShuffle.toggle()
                        }) {
                            Image(systemName: "shuffle")
                                .font(.title3)
                                .foregroundColor(player.isShuffle ? .accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: {
                            player.previous()
                        }) {
                            Image(systemName: "backward.fill")
                                .font(.title)
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: {
                            player.togglePlayPause()
                        }) {
                            ZStack {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 68, height: 68)
                                
                                if player.isLoading {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                } else {
                                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                        .font(.title)
                                        .foregroundColor(.white)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: {
                            player.next()
                        }) {
                            Image(systemName: "forward.fill")
                                .font(.title)
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: {
                            player.isRepeat.toggle()
                        }) {
                            Image(systemName: "repeat")
                                .font(.title3)
                                .foregroundColor(player.isRepeat ? .accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 8)
                    
                    // Bottom Actions: Offline cache status & Add to favorites
                    HStack(spacing: 24) {
                        let isDownloaded = cacheService.isTrackDownloaded(trackId: track.id)
                        let isDownloading = cacheService.activeDownloads.contains(track.id)
                        
                        Button(action: {
                            if isDownloaded {
                                cacheService.deleteTrackAudio(trackId: track.id)
                                storageService.updateTrackLocalPath(trackId: track.id, relativePath: nil)
                            } else {
                                Task {
                                    storageService.saveTrack(track)
                                    if let path = try? await cacheService.downloadTrack(track: track) {
                                        storageService.updateTrackLocalPath(trackId: track.id, relativePath: path)
                                    }
                                }
                            }
                        }) {
                            Label(
                                isDownloaded ? "Downloaded" : (isDownloading ? "Downloading..." : "Download"),
                                systemImage: isDownloaded ? "checkmark.circle.fill" : (isDownloading ? "arrow.down.circle.dotted" : "arrow.down.circle")
                            )
                            .font(.footnote)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.gray.opacity(0.15))
                            .cornerRadius(20)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 4)
                } else {
                    Text("No track playing")
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Dismiss") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite else { return "0:00" }
        let total = Int(max(0, seconds))
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
