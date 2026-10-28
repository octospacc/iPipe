# Tuneflow 🎵

A native **SwiftUI** music player for **iOS and macOS** powered by an anonymous YouTube backend (via public, federated Invidious/Piped API endpoints). It provides:

- **100% Anonymous & Private**: No Google / YouTube account login required. Zero tracking, telemetry, or server-side user data.
- **Full Offline Caching**: Download songs with one tap for instant offline playback. All media is saved locally to your device storage.
- **Background Audio & Lock Screen**: Powered by `AVFoundation`, `AVAudioSession`, and `MediaPlayer` (`MPNowPlayingInfoCenter` & `MPRemoteCommandCenter`). Control music from the iOS Lock Screen, Dynamic Island, Control Center, or macOS Media Keys.
- **Local Playlists & Library**: Create, edit, and organize custom playlists and manage your library offline with JSON-persisted local storage.
- **Native Dual-Platform UI**:
  - **iOS**: TabView with floating interactive Mini Player and expanding full-screen Now Playing sheet.
  - **macOS**: Native NavigationSplitView sidebar layout with integrated player bar and custom controls.
- **Custom Backend Instance**: Easily switch to your own private Invidious/Piped server or use the built-in redundant fallback instances.

---

## Project Structure

```
├── Tuneflow.xcodeproj          # Xcode Project file (iOS 16+ & macOS 13+)
├── Tuneflow
│   ├── Resources
│   │   ├── Info.plist          # Background audio mode (UIBackgroundModes) & ATS config
│   │   └── Tuneflow.entitlements # Sandbox & network client capabilities
│   └── Sources
│       ├── TuneflowApp.swift   # App entry point
│       ├── Models
│       │   ├── Track.swift     # Track entity (id, title, artist, audio URLs)
│       │   └── Playlist.swift  # Local playlist entity
│       ├── Services
│       │   ├── YouTubeBackendService.swift # Anonymous YouTube streaming & search
│       │   ├── CacheService.swift         # Background download & offline storage manager
│       │   ├── StorageService.swift       # Local JSON persistence for library & playlists
│       │   └── AudioPlayerService.swift   # AVPlayer, audio session & Lock Screen controls
│       ├── ViewModels
│       │   └── SearchViewModel.swift      # Search state & asynchronous queries
│       └── Views
│           ├── ContentView.swift          # Main dual-platform container
│           ├── SearchView.swift           # YouTube search view
│           ├── TrackRowView.swift         # Track list item with offline download button
│           ├── MiniPlayerView.swift       # Sticky mini player with controls
│           ├── NowPlayingView.swift       # Full player with scrubber, artwork & queue
│           ├── LibraryView.swift          # Local library, downloaded tracks & playlists
│           ├── PlaylistDetailView.swift   # Playlist tracks, reordering & play controls
│           ├── AddToPlaylistSheet.swift   # Quick add song to playlist sheet
│           └── SettingsView.swift         # Backend instance & storage management
```

---

## Getting Started

1. Open `Tuneflow.xcodeproj` in **Xcode 15+** or **Xcode 16+**.
2. Select your target device or simulator (iPhone or Mac).
3. Build and Run (`⌘R`).
