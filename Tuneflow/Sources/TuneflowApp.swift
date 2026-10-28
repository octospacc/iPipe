import SwiftUI

@main
struct TuneflowApp: App {
    init() {
        // Pre-warm audio session and storage
        _ = StorageService.shared
        _ = CacheService.shared
        _ = AudioPlayerService.shared
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 650)
        #endif
    }
}
