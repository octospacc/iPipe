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
            .navigationTitle("Tuneflow")
        } detail: {
            VStack(spacing: 0) {
                switch selectedTab {
                case .search:
                    SearchView()
                case .library:
                    LibraryView()
                case .settings:
                    SettingsView()
                }

                if player.currentTrack != nil {
                    MiniPlayerView(onExpand: {
                        isNowPlayingExpanded = true
                    })
                }
            }
        }
        .sheet(isPresented: $isNowPlayingExpanded) {
            NowPlayingView()
                .frame(minWidth: 420, minHeight: 600)
        }
        #else
        // iOS TabView layout
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                SearchView()
                    .tabItem {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .tag(TabItem.search)

                LibraryView()
                    .tabItem {
                        Label("Library", systemImage: "music.note.list")
                    }
                    .tag(TabItem.library)

                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .tag(TabItem.settings)
            }

            // Floating MiniPlayer above TabBar
            if player.currentTrack != nil {
                MiniPlayerView(onExpand: {
                    isNowPlayingExpanded = true
                })
                .padding(.bottom, 49) // Height of iOS standard TabBar
            }
        }
        .sheet(isPresented: $isNowPlayingExpanded) {
            NowPlayingView()
        }
        #endif
    }
}
