import SwiftUI

public struct ContentView: View {
    @State private var selectedTab: TabItem = .search
    @State private var isNowPlayingExpanded: Bool = false
    @ObservedObject private var player = AudioPlayerService.shared
    @ObservedObject private var cache = CacheService.shared

    public enum TabItem: Hashable {
        case search
        case library
        case settings
    }

    public init() {}

    private var isPlaybackErrorPresented: Binding<Bool> {
        Binding(
            get: { player.errorMessage != nil },
            set: { if !$0 { player.clearError() } }
        )
    }

    private var isDownloadErrorPresented: Binding<Bool> {
        Binding(
            get: { cache.lastError != nil },
            set: { if !$0 { cache.clearError() } }
        )
    }

    public var body: some View {
        content
            .alert("Playback Error", isPresented: isPlaybackErrorPresented) {
                Button("OK", role: .cancel) { player.clearError() }
            } message: {
                Text(player.errorMessage ?? "Unknown error.")
            }
            .alert("Download Failed", isPresented: isDownloadErrorPresented) {
                Button("OK", role: .cancel) { cache.clearError() }
            } message: {
                Text(cache.lastError ?? "Unknown error.")
            }
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        // macOS Split / Sidebar layout
        NavigationSplitView {
            List(selection: $selectedTab) {
                NavigationLink(value: TabItem.search) {
                    Label("Search", systemImage: "magnifyingglass")
                }
                NavigationLink(value: TabItem.library) {
                    Label("Library", systemImage: "music.note.list")
                }
                NavigationLink(value: TabItem.settings) {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            .navigationTitle("iPipe")
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch selectedTab {
                    case .search:
                        SearchView()
                    case .library:
                        LibraryView()
                    case .settings:
                        SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                if player.currentTrack != nil {
                    MiniPlayerView(onExpand: {
                        isNowPlayingExpanded = true
                    })
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .sheet(isPresented: $isNowPlayingExpanded) {
            NowPlayingView()
                .frame(minWidth: 440, idealWidth: 480, minHeight: 620, idealHeight: 720)
        }
        #else
        // iOS TabView layout
        TabView(selection: $selectedTab) {
            withMiniPlayer(SearchView())
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .tag(TabItem.search)

            withMiniPlayer(LibraryView())
                .tabItem {
                    Label("Library", systemImage: "music.note.list")
                }
                .tag(TabItem.library)

            withMiniPlayer(SettingsView())
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(TabItem.settings)
        }
        .sheet(isPresented: $isNowPlayingExpanded) {
            NowPlayingView()
                .presentationDragIndicator(.visible)
        }
        #endif
    }
    
    /// The mini player is a safe-area inset on every tab, so scrollable screens
    /// (especially Settings) keep all of their content above it.
    @ViewBuilder
    private func withMiniPlayer<Content: View>(_ content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if player.currentTrack != nil {
                MiniPlayerView(onExpand: {
                    isNowPlayingExpanded = true
                })
            }
        }
    }
}
