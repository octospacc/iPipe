import Foundation
import AVFoundation
import MediaPlayer
import Combine

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public final class AudioPlayerService: ObservableObject, @unchecked Sendable {
    public static let shared = AudioPlayerService()
    
    @Published public private(set) var currentTrack: Track?
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var currentTime: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var errorMessage: String?
    
    @Published public var queue: [Track] = []
    @Published public var currentIndex: Int = 0
    @Published public var isShuffle: Bool = false
    @Published public var isRepeat: Bool = false
    
    // Underlying playback engine
    private var avPlayer: AVPlayer?
    private var avPlayerItem: AVPlayerItem?
    private var timeObserverToken: Any?
    private var isUsingEmbedPlayer: Bool = false
    
    private init() {
        configureAudioSession()
        setupRemoteCommandCenter()
        setupEmbedPlayerCallbacks()
    }
    
    deinit {
        removeTimeObserver()
    }
    
    private func configureAudioSession() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            try session.setActive(true)
        } catch {
            print("Failed to configure AVAudioSession: \(error)")
        }
        #endif
    }
    
    private func setupEmbedPlayerCallbacks() {
        EmbedStreamPlayer.shared.setCallbacks(
            onPlayingChange: { [weak self] playing in
                DispatchQueue.main.async {
                    guard let self = self, self.isUsingEmbedPlayer else { return }
                    self.isPlaying = playing
                    self.isLoading = false
                    self.updateNowPlayingPlaybackInfo()
                }
            },
            onTimeUpdate: { [weak self] current, dur in
                DispatchQueue.main.async {
                    guard let self = self, self.isUsingEmbedPlayer else { return }
                    self.currentTime = current
                    if dur > 0 { self.duration = dur }
                    self.updateNowPlayingPlaybackInfo()
                }
            },
            onEnded: { [weak self] in
                DispatchQueue.main.async {
                    guard let self = self, self.isUsingEmbedPlayer else { return }
                    if self.isRepeat && self.queue.count == 1 {
                        self.seek(to: 0)
                        self.play()
                    } else {
                        self.next()
                    }
                }
            }
        )
    }
    
    // MARK: - Playback Control
    
    public func playQueue(tracks: [Track], startIndex: Int = 0) {
        guard !tracks.isEmpty, startIndex >= 0, startIndex < tracks.count else { return }
        self.queue = tracks
        self.currentIndex = startIndex
        playTrack(tracks[startIndex])
    }
    
    public func playTrack(_ track: Track) {
        self.currentTrack = track
        self.isLoading = true
        self.errorMessage = nil
        self.currentTime = 0
        self.duration = track.durationSeconds > 0 ? track.durationSeconds : 0
        
        // Check if track is cached locally first (instant offline AVPlayer playback)
        if let localURL = CacheService.shared.getLocalAudioURL(trackId: track.id) {
            self.isUsingEmbedPlayer = false
            EmbedStreamPlayer.shared.stop()
            setupAVPlayerWithURL(localURL, for: track)
            return
        }
        
        // Track is online: stream directly via official, zero-API-key YouTube embed player
        self.isUsingEmbedPlayer = true
        stopAVPlayer()
        EmbedStreamPlayer.shared.playVideo(videoId: track.id)
        self.isPlaying = true
        updateNowPlayingInfo()
    }
    
    private func stopAVPlayer() {
        removeTimeObserver()
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: avPlayerItem)
        avPlayer?.pause()
        avPlayer = nil
        avPlayerItem = nil
    }
    
    private func setupAVPlayerWithURL(_ url: URL, for track: Track) {
        stopAVPlayer()
        
        let asset = AVURLAsset(url: url)
        avPlayerItem = AVPlayerItem(asset: asset)
        avPlayer = AVPlayer(playerItem: avPlayerItem)
        avPlayer?.actionAtItemEnd = .none
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidReachEnd),
            name: .AVPlayerItemDidPlayToEndTime,
            object: avPlayerItem
        )
        
        addPeriodicTimeObserver()
        avPlayer?.play()
        self.isPlaying = true
        self.isLoading = false
        
        updateNowPlayingInfo()
    }
    
    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    public func play() {
        if isUsingEmbedPlayer {
            EmbedStreamPlayer.shared.play()
        } else {
            avPlayer?.play()
        }
        isPlaying = true
        updateNowPlayingPlaybackInfo()
    }
    
    public func pause() {
        if isUsingEmbedPlayer {
            EmbedStreamPlayer.shared.pause()
        } else {
            avPlayer?.pause()
        }
        isPlaying = false
        updateNowPlayingPlaybackInfo()
    }
    
    public func seek(to seconds: Double) {
        if isUsingEmbedPlayer {
            EmbedStreamPlayer.shared.seek(to: seconds)
            self.currentTime = seconds
            updateNowPlayingPlaybackInfo()
        } else if let player = avPlayer {
            let targetCMTime = CMTime(seconds: seconds, preferredTimescale: 600)
            player.seek(to: targetCMTime) { [weak self] _ in
                self?.updateNowPlayingPlaybackInfo()
            }
        }
    }
    
    public func next() {
        guard !queue.isEmpty else { return }
        if currentIndex + 1 < queue.count {
            currentIndex += 1
            playTrack(queue[currentIndex])
        } else if isRepeat {
            currentIndex = 0
            playTrack(queue[currentIndex])
        }
    }
    
    public func previous() {
        guard !queue.isEmpty else { return }
        if currentTime > 3.0 {
            seek(to: 0)
        } else if currentIndex > 0 {
            currentIndex -= 1
            playTrack(queue[currentIndex])
        } else {
            seek(to: 0)
        }
    }
    
    @objc private func playerItemDidReachEnd(notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.isRepeat && self.queue.count == 1 {
                self.seek(to: 0)
                self.avPlayer?.play()
            } else {
                self.next()
            }
        }
    }
    
    private func addPeriodicTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserverToken = avPlayer?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self, !self.isUsingEmbedPlayer else { return }
            self.currentTime = time.seconds
            if let durationCM = self.avPlayerItem?.duration, durationCM.isValid && !durationCM.isIndefinite {
                self.duration = durationCM.seconds
            } else if let trackDuration = self.currentTrack?.durationSeconds, trackDuration > 0 {
                self.duration = trackDuration
            }
            self.updateNowPlayingPlaybackInfo()
        }
    }
    
    private func removeTimeObserver() {
        if let token = timeObserverToken {
            avPlayer?.removeTimeObserver(token)
            timeObserverToken = nil
        }
    }
    
    // MARK: - Now Playing Info & Lock Screen Controls
    
    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }
        
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.next()
            return .success
        }
        
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous()
            return .success
        }
        
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let positionEvent = event as? MPChangePlaybackPositionCommandEvent {
                self?.seek(to: positionEvent.positionTime)
                return .success
            }
            return .commandFailed
        }
    }
    
    private func updateNowPlayingInfo() {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = track.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = track.artist
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = track.durationSeconds > 0 ? track.durationSeconds : duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        
        // Fetch artwork asynchronously
        if let thumbURL = track.thumbnailUrl {
            Task {
                if let (data, _) = try? await URLSession.shared.data(from: thumbURL) {
                    #if canImport(UIKit)
                    if let image = UIImage(data: data) {
                        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                        await MainActor.run {
                            var currentInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                            currentInfo[MPMediaItemPropertyArtwork] = artwork
                            MPNowPlayingInfoCenter.default().nowPlayingInfo = currentInfo
                        }
                    }
                    #elseif canImport(AppKit)
                    if let image = NSImage(data: data) {
                        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                        await MainActor.run {
                            var currentInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                            currentInfo[MPMediaItemPropertyArtwork] = artwork
                            MPNowPlayingInfoCenter.default().nowPlayingInfo = currentInfo
                        }
                    }
                    #endif
                }
            }
        }
    }
    
    private func updateNowPlayingPlaybackInfo() {
        guard var currentInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        currentInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        currentInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = currentInfo
    }
}
