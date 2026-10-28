import SwiftUI

public struct NowPlayingView: View {
    @ObservedObject private var player = AudioPlayerService.shared
    @ObservedObject private var cacheService = CacheService.shared
    @ObservedObject private var storageService = StorageService.shared
    @Environment(\.dismiss) private var dismiss
    
    @State private var sliderValue: Double = 0
    @State private var isDragging: Bool = false
    @State private var showingAddToPlaylist = false
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 22) {
                        if let track = player.currentTrack {
                            artwork(for: track)
                            metadata(for: track)
                            
                            if let error = player.errorMessage {
                                errorBanner(error, actionTitle: "Try Again") {
                                    player.playTrack(track)
                                }
                            }
                            
                            if let downloadError = cacheService.lastError {
                                errorBanner(downloadError, actionTitle: "Dismiss") {
                                    cacheService.clearError()
                                }
                            }
                            
                            timeline
                            controls
                            bottomActions(for: track)
                        } else {
                            Text("No track playing")
                                .foregroundColor(.secondary)
                                .padding(.vertical, 60)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
                }
            }
        }
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #endif
        .sheet(isPresented: $showingAddToPlaylist) {
            if let track = player.currentTrack {
                AddToPlaylistSheet(track: track)
            }
        }
    }
    
    private var header: some View {
        HStack {
            Text("Now Playing")
                .font(.headline)
            Spacer()
            Button(action: {
                dismiss()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
    
    @ViewBuilder
    private func artwork(for track: Track) -> some View {
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
    }
    
    @ViewBuilder
    private func metadata(for track: Track) -> some View {
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
    }
    
    private func errorBanner(_ message: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Text(message)
                .font(.footnote)
                .foregroundColor(.red)
                .multilineTextAlignment(.center)
            Button(actionTitle, action: action)
                .font(.footnote)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 24)
    }
    
    private var timeline: some View {
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
    }
    
    private var controls: some View {
        HStack(spacing: 40) {
            Button(action: {
                player.isShuffle.toggle()
            }) {
                Image(systemName: "shuffle")
                    .font(.title3)
                    .foregroundColor(player.isShuffle ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(player.isShuffle ? "Shuffle: on" : "Shuffle: off")
            
            Button(action: {
                player.previous()
            }) {
                Image(systemName: "backward.fill")
                    .font(.title)
            }
            .buttonStyle(.plain)
            .help("Previous")
            
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
            .help(player.isPlaying ? "Pause" : "Play")
            
            Button(action: {
                player.next()
            }) {
                Image(systemName: "forward.fill")
                    .font(.title)
            }
            .buttonStyle(.plain)
            .help("Next")
            
            Button(action: {
                player.cycleRepeatMode()
            }) {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.title3)
                    .foregroundColor(player.repeatMode == .off ? .secondary : .accentColor)
            }
            .buttonStyle(.plain)
            .help(repeatLabel)
            .accessibilityLabel(repeatLabel)
        }
        .padding(.vertical, 8)
    }
    
    @ViewBuilder
    private func bottomActions(for track: Track) -> some View {
        let isDownloaded = cacheService.isTrackDownloaded(trackId: track.id)
        let isDownloading = cacheService.activeDownloads.contains(track.id)
        
        HStack(spacing: 16) {
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
            .help(isDownloaded ? "Remove download" : "Download for offline playback")
            
            Button(action: {
                showingAddToPlaylist = true
            }) {
                Label("Add to Playlist", systemImage: "plus.circle")
                    .font(.footnote)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.gray.opacity(0.15))
                    .cornerRadius(20)
            }
            .buttonStyle(.plain)
            .help("Add to playlist")
        }
        .padding(.top, 4)
    }
    
    private var repeatLabel: String {
        switch player.repeatMode {
        case .off: return "Repeat: off"
        case .all: return "Repeat: all songs"
        case .one: return "Repeat: this song"
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
