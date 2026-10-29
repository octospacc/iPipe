import Foundation
import AVFoundation
import MediaPlayer
import Combine

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Coordinates playback.
///
/// Online tracks play through AVPlayer using the direct audio stream resolved by
/// `YouTubeDirectService` (this is the reliable path). If stream resolution fails,
/// playback falls back to the official YouTube IFrame player in `EmbedStreamPlayer`.
public final class AudioPlayerService: ObservableObject, @unchecked Sendable {
    public static let shared = AudioPlayerService()

    /// `UserDefaults` key backing the "Automatically download songs on play" setting.
    public static let autoDownloadOnPlayKey = "auto_download_on_play"

    @Published public private(set) var currentTrack: Track?
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var currentTime: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var errorMessage: String?

    @Published public var queue: [Track] = []
    @Published public var currentIndex: Int = 0
    @Published public var isShuffle: Bool = false

    /// Off → repeat all → repeat the current song.
    public enum RepeatMode: String, Codable, Sendable {
        case off
        case all
        case one
    }

    @Published public var repeatMode: RepeatMode = .off

    public func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    // Underlying playback engine
    private var avPlayer: AVPlayer?
    private var avPlayerItem: AVPlayerItem?
    private var timeObserverToken: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var isUsingEmbedPlayer: Bool = false
    private var didFallBackToEmbed: Bool = false
    private var embedCallbacksConfigured: Bool = false
    private var didHandleEnd = false
    private var historyRecorded = false

    // Stale-work guards
    private var loadToken = UUID()
    private var watchdogToken = UUID()
    private var suppressSessionPersistence = false

    private init() {
        configureAudioSession()
        setupRemoteCommandCenter()
        restorePlaybackSession()
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

    // MARK: - Playback Control

    public func playQueue(tracks: [Track], startIndex: Int = 0) {
        guard !tracks.isEmpty, startIndex >= 0, startIndex < tracks.count else { return }
        self.suppressSessionPersistence = false
        self.queue = tracks
        self.currentIndex = startIndex
        playTrack(tracks[startIndex])
        persistCurrentSession()
    }

    public func playTrack(_ track: Track) {
        // Cancel any in-flight resolution for the previous track.
        loadToken = UUID()
        stopWatchdog()
        didHandleEnd = false
        historyRecorded = false
        suppressSessionPersistence = false

        let previousWasEmbed = isUsingEmbedPlayer
        isUsingEmbedPlayer = false
        didFallBackToEmbed = false
        stopAVPlayer()
        if previousWasEmbed {
            EmbedStreamPlayer.shared.stop()
        }

        self.currentTrack = track
        self.isLoading = true
        self.isPlaying = false
        self.errorMessage = nil
        persistCurrentSession()
        self.currentTime = 0
        self.duration = track.durationSeconds > 0 ? track.durationSeconds : 0

        // Cached locally: instant offline AVPlayer playback.
        if let localURL = CacheService.shared.getLocalAudioURL(trackId: track.id) {
            setupAVPlayerWithURL(localURL, for: track, isRemote: false)
            return
        }

        startDirectPlayback(for: track)
    }

    private func startDirectPlayback(for track: Track) {
        let token = loadToken
        isLoading = true

        Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await YouTubeDirectService.shared.resolveAudioStream(videoId: track.id)
                try Task.checkCancellation()
                DispatchQueue.main.async {
                    guard self.loadToken == token, self.currentTrack?.id == track.id else { return }
                    if let length = stream.durationSeconds, length > 0 {
                        self.duration = length
                    }
                    self.setupAVPlayerWithRemoteStream(stream, for: track)
                }
            } catch {
                let cancelled = (error is CancellationError) || (error as? URLError)?.code == .cancelled
                DispatchQueue.main.async {
                    guard !cancelled, self.loadToken == token, self.currentTrack?.id == track.id else { return }
                    #if DEBUG
                    print("[iPipe] direct stream resolution failed for \(track.id): \(error.localizedDescription)")
                    #endif
                    self.startEmbedFallback(for: track, reason: error.localizedDescription)
                }
            }
        }

        scheduleWatchdog()
    }

    // MARK: - AVPlayer setup

    /// Header key accepted by AVURLAsset (undocumented but widely used and harmless
    /// if ignored). YouTube CDN URLs are signed, so this is only a nicety.
    private static let httpHeaderFieldsKey = "AVURLAssetHTTPHeaderFieldsKey"

    private func setupAVPlayerWithRemoteStream(_ stream: YouTubeDirectService.AudioStream, for track: Track) {
        let options: [String: Any] = [
            Self.httpHeaderFieldsKey: [
                "User-Agent": stream.userAgent,
                "Referer": "https://www.youtube.com/"
            ]
        ]
        let asset = AVURLAsset(url: stream.url, options: options)
        setupAVPlayer(with: asset, for: track, isRemote: true)
    }

    private func setupAVPlayerWithURL(_ url: URL, for track: Track, isRemote: Bool) {
        setupAVPlayer(with: AVURLAsset(url: url), for: track, isRemote: isRemote)
    }

    private func setupAVPlayer(with asset: AVURLAsset, for track: Track, isRemote: Bool) {
        stopAVPlayer()

        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 10
        avPlayerItem = item

        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = true
        avPlayer = player

        itemStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] observed, _ in
            DispatchQueue.main.async {
                guard let self, self.avPlayerItem === observed else { return }
                self.handleItemStatus(observed.status, error: observed.error, isRemote: isRemote, track: track)
            }
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
            DispatchQueue.main.async {
                guard let self, self.avPlayer === observed else { return }
                switch observed.timeControlStatus {
                case .playing:
                    self.isPlaying = true
                    self.isLoading = false
                    self.stopWatchdog()
                    self.recordHistoryIfNeeded()
                case .waitingToPlayAtSpecifiedRate:
                    if self.currentTrack?.id == track.id { self.isLoading = true }
                case .paused:
                    self.isPlaying = false
                @unknown default:
                    break
                }
                self.updateNowPlayingPlaybackInfo()
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidReachEnd),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )

        addPeriodicTimeObserver()
        player.play()
        // Playback is confirmed through the time-control observer once audio really starts.
        updateNowPlayingInfo()
    }

    private func handleItemStatus(_ status: AVPlayerItem.Status, error: Error?, isRemote: Bool, track: Track) {
        switch status {
        case .readyToPlay:
            if duration <= 0, let itemDuration = avPlayerItem?.duration,
               itemDuration.isValid, !itemDuration.isIndefinite {
                duration = itemDuration.seconds
            }
        case .failed:
            let message = error?.localizedDescription ?? "Unknown playback error."
            #if DEBUG
            print("[iPipe] AVPlayer item failed for \(track.id) (remote: \(isRemote)): \(message)")
            #endif
            if isRemote && !didFallBackToEmbed {
                startEmbedFallback(for: track, reason: message)
            } else {
                errorMessage = "Playback failed: \(message)"
                isLoading = false
                isPlaying = false
            }
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func startEmbedFallback(for track: Track, reason: String?) {
        guard currentTrack?.id == track.id else { return }
        if didFallBackToEmbed {
            errorMessage = reason.map { "Unable to play this track: \($0)" } ?? "Unable to play this track."
            isLoading = false
            isPlaying = false
            return
        }
        didFallBackToEmbed = true
        isUsingEmbedPlayer = true
        // Ignore any direct-resolution result that is still in flight.
        loadToken = UUID()
        stopAVPlayer()
        configureEmbedCallbacksIfNeeded()

        print("[iPipe] falling back to the YouTube embed player for \(track.id): \(reason ?? "")")
        isLoading = true
        isPlaying = false
        EmbedStreamPlayer.shared.playVideo(videoId: track.id)
        scheduleWatchdog()
    }

    private func configureEmbedCallbacksIfNeeded() {
        guard !embedCallbacksConfigured else { return }
        embedCallbacksConfigured = true

        EmbedStreamPlayer.shared.setCallbacks(
            onPlayingChange: { [weak self] playing in
                DispatchQueue.main.async {
                    guard let self = self, self.isUsingEmbedPlayer else { return }
                    self.isPlaying = playing
                    if playing {
                        self.isLoading = false
                        self.recordHistoryIfNeeded()
                    }
                    self.updateNowPlayingPlaybackInfo()
                }
            },
            onTimeUpdate: { [weak self] current, dur in
                DispatchQueue.main.async {
                    guard let self = self, self.isUsingEmbedPlayer else { return }
                    self.currentTime = current
                    if dur > 0 { self.duration = dur }
                    if current > 0 { self.isLoading = false }
                    self.updateNowPlayingPlaybackInfo()
                }
            },
            onEnded: { [weak self] in
                DispatchQueue.main.async {
                    guard let self = self, self.isUsingEmbedPlayer else { return }
                    self.handlePlaybackEnded()
                }
            }
        )

        EmbedStreamPlayer.shared.errorHandler = { [weak self] msg in
            DispatchQueue.main.async {
                guard let self = self, self.isUsingEmbedPlayer || self.didFallBackToEmbed else { return }
                print("[iPipe] embed player error: \(msg)")
                self.errorMessage = msg
                self.isLoading = false
                self.isPlaying = false
            }
        }
    }

    private func stopAVPlayer() {
        removeTimeObserver()
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        if let item = avPlayerItem {
            NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: item)
        }
        avPlayer?.pause()
        avPlayer = nil
        avPlayerItem = nil
    }

    // MARK: - Loading watchdog

    /// Stops the spinner from running forever when neither engine reports progress.
    private func scheduleWatchdog() {
        let token = UUID()
        watchdogToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self, self.watchdogToken == token else { return }
            guard self.isLoading, !self.isPlaying else { return }
            if self.isUsingEmbedPlayer {
                self.errorMessage = "Playback timed out. The YouTube player did not start; check your connection and try again."
                self.isLoading = false
            } else if let track = self.currentTrack, !self.didFallBackToEmbed {
                self.startEmbedFallback(for: track, reason: "Playback timed out.")
            }
        }
    }

    private func stopWatchdog() {
        watchdogToken = UUID()
    }

    // MARK: - Transport

    public func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    public func play() {
        // Restart from the beginning when playback was stopped at the end.
        if duration > 0, currentTime >= duration - 0.35, !isUsingEmbedPlayer {
            seek(to: 0)
        }
        if isUsingEmbedPlayer {
            EmbedStreamPlayer.shared.play()
        } else if let player = avPlayer {
            player.play()
        } else if let track = currentTrack {
            playTrack(track)
            return
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
        isLoading = false
        updateNowPlayingPlaybackInfo()
        persistCurrentSession()
    }

    public func seek(to seconds: Double) {
        if duration > 0, seconds < duration - 1 {
            didHandleEnd = false
        }
        if isUsingEmbedPlayer {
            EmbedStreamPlayer.shared.seek(to: seconds)
            self.currentTime = seconds
            updateNowPlayingPlaybackInfo()
        } else if let player = avPlayer {
            let target = CMTime(seconds: seconds, preferredTimescale: 600)
            player.seek(to: target) { [weak self] _ in
                self?.updateNowPlayingPlaybackInfo()
            }
            self.currentTime = seconds
        }
    }

    public func next() {
        guard !queue.isEmpty else { return }
        if isShuffle && queue.count > 1 {
            var index = currentIndex
            while index == currentIndex { index = Int.random(in: 0..<queue.count) }
            currentIndex = index
            playTrack(queue[index])
        } else if currentIndex + 1 < queue.count {
            currentIndex += 1
            playTrack(queue[currentIndex])
        } else if repeatMode == .all {
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

    public func clearError() {
        errorMessage = nil
    }

    private func restorePlaybackSession() {
        guard let session = StorageService.shared.loadPlaybackSession(), !session.queue.isEmpty else { return }
        let index = (session.currentIndex >= 0 && session.currentIndex < session.queue.count) ? session.currentIndex : 0
        self.queue = session.queue
        self.currentIndex = index
        let track = session.queue[index]
        self.currentTrack = track
        self.currentTime = max(0, session.currentTime)
        self.duration = track.durationSeconds
        self.isPlaying = false
        self.isLoading = false
        updateNowPlayingInfo()
    }

    public func persistCurrentSession() {
        guard !queue.isEmpty, !suppressSessionPersistence else { return }
        StorageService.shared.savePlaybackSession(queue: queue, currentIndex: currentIndex, currentTime: currentTime)
    }

    public func clearSavedPlaybackSession() {
        suppressSessionPersistence = true
        StorageService.shared.deletePlaybackSession()
    }

    @objc private func playerItemDidReachEnd(notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.handlePlaybackEnded()
        }
    }

    /// Shared end-of-track handling for AVPlayer and the embed fallback.
    /// It advances the queue, loops the single repeated track, or stops cleanly.
    private func handlePlaybackEnded() {
        guard !didHandleEnd else { return }
        didHandleEnd = true

        if repeatMode == .one {
            seek(to: 0)
            play()
            return
        }

        let hasNextTrack = isShuffle ? queue.count > 1 : currentIndex + 1 < queue.count
        if !queue.isEmpty && (hasNextTrack || repeatMode == .all) {
            next()
        } else {
            pause()
            if duration > 0 { currentTime = duration }
        }
    }

    private func recordHistoryIfNeeded() {
        guard !historyRecorded, let track = currentTrack else { return }
        historyRecorded = true
        StorageService.shared.recordPlayed(track)
        autoDownloadIfEnabled(track)
    }

    private func autoDownloadIfEnabled(_ track: Track) {
        guard UserDefaults.standard.bool(forKey: Self.autoDownloadOnPlayKey) else { return }
        guard !CacheService.shared.isTrackDownloaded(trackId: track.id),
              !CacheService.shared.activeDownloads.contains(track.id) else { return }
        Task {
            do {
                _ = try await CacheService.shared.downloadTrack(track: track, reportErrors: false)
            } catch {
                // Downloads occasionally fail on a transient CDN response; retry once.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !CacheService.shared.isTrackDownloaded(trackId: track.id) {
                    _ = try? await CacheService.shared.downloadTrack(track: track, reportErrors: false)
                }
            }
        }
    }

    private func addPeriodicTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserverToken = avPlayer?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self, !self.isUsingEmbedPlayer else { return }

            // Do not infer "playing" from elapsed time: a paused player keeps its time.
            if let player = self.avPlayer {
                let playing = player.timeControlStatus == .playing
                if self.isPlaying != playing {
                    self.isPlaying = playing
                }
                if playing {
                    self.isLoading = false
                    self.stopWatchdog()
                    self.recordHistoryIfNeeded()
                }
            }

            if self.duration > 0 {
                // Never let the displayed timer run past the known duration.
                self.currentTime = min(max(time.seconds, 0), self.duration)
                if time.seconds < self.duration - 1 {
                    self.didHandleEnd = false
                }
                if time.seconds >= self.duration - 0.35,
                   self.avPlayer?.timeControlStatus != .paused {
                    self.handlePlaybackEnded()
                }
            } else {
                self.currentTime = max(time.seconds, 0)
            }

            if self.duration <= 0, let d = self.avPlayerItem?.duration, d.isValid, !d.isIndefinite {
                self.duration = d.seconds
            } else if self.duration <= 0, let td = self.currentTrack?.durationSeconds, td > 0 {
                self.duration = td
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
        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.isEnabled = true
        cc.playCommand.addTarget { [weak self] _ in self?.play(); return .success }

        cc.pauseCommand.isEnabled = true
        cc.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }

        cc.togglePlayPauseCommand.isEnabled = true
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }

        cc.nextTrackCommand.isEnabled = true
        cc.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }

        cc.previousTrackCommand.isEnabled = true
        cc.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }

        cc.changePlaybackPositionCommand.isEnabled = true
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let e = event as? MPChangePlaybackPositionCommandEvent {
                self?.seek(to: e.positionTime)
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

        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = track.title
        info[MPMediaItemPropertyArtist] = track.artist
        info[MPMediaItemPropertyPlaybackDuration] = track.durationSeconds > 0 ? track.durationSeconds : duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        if let thumbURL = track.thumbnailUrl {
            Task {
                if let image = await ImageCacheService.shared.loadImage(for: thumbURL) {
                    let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    await MainActor.run {
                        var cur = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                        cur[MPMediaItemPropertyArtwork] = artwork
                        MPNowPlayingInfoCenter.default().nowPlayingInfo = cur
                    }
                }
            }
        }
    }

    private func updateNowPlayingPlaybackInfo() {
        guard var cur = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        cur[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        cur[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = cur
    }
}
