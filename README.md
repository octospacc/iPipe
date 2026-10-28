# iPipe 🎵

iPipe (a play on YouTube) is a native **SwiftUI** music player for **iOS and macOS** that talks directly to YouTube — no proxies, no API keys, no login.

- **Anonymous & private**: no Google account, no telemetry. Playlists and library stay on your device.
- **Direct YouTube**: search via YouTube's public web client endpoint; online playback through AVPlayer using a signed audio stream resolved from YouTube's player endpoint (the official YouTube IFrame player is only a fallback); downloads via direct, chunked Range requests to YouTube's CDN.
- **Offline**: one-tap download to `Documents/DownloadedAudio/<id>.m4a`; downloaded tracks play instantly through AVPlayer. Optional auto-download on play (off by default).
- **Listening history**: every played song is listed under Library → History and can be cleared in Settings.
- **Background audio & lock screen** controls (`AVFoundation`, `MediaPlayer`).
- **Local playlists & library** persisted as JSON.

## Project Structure

```
├── Tuneflow.xcodeproj
├── Tuneflow
│   ├── Resources            # Info.plist, entitlements, Assets.xcassets (iPipe icon)
│   └── Sources
│       ├── Models           # Track, Playlist
│       ├── Services
│       │   ├── YouTubeDirectService.swift  # Search, oEmbed, visitor session, audio stream resolution
│       │   ├── EmbedStreamPlayer.swift     # Optional fallback: WKWebView + YouTube IFrame API
│       │   ├── CacheService.swift          # Chunked downloads & offline storage
│       │   ├── StorageService.swift        # Library/playlist/history persistence
│       │   └── AudioPlayerService.swift    # AVPlayer playback with embed fallback, lock screen
│       ├── ViewModels       # SearchViewModel
│       └── Views
```

## Getting Started

Open `Tuneflow.xcodeproj` in Xcode 15+, pick a device or Mac, and run (⌘R).
