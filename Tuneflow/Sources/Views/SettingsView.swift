import SwiftUI

public struct SettingsView: View {
    @ObservedObject private var cache = CacheService.shared
    @State private var showingClearCacheAlert = false
    @State private var cacheClearedMessage = false
    
    public init() {}
    
    public var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Privacy & Anonymity")) {
                    HStack {
                        Image(systemName: "lock.shield.fill")
                            .foregroundColor(.green)
                            .font(.title2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("100% Anonymous & Local")
                                .font(.headline)
                            Text("No Google login or telemetry. Playlists and listening history stay strictly on your local device.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                Section(header: Text("Offline Cache Storage")) {
                    Button(role: .destructive, action: {
                        showingClearCacheAlert = true
                    }) {
                        Label("Clear Downloaded Audio Cache", systemImage: "trash")
                            .foregroundColor(.red)
                    }
                }
                
                Section(header: Text("About Tuneflow")) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0 (Native SwiftUI)")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Platform")
                        Spacer()
                        #if os(iOS)
                        Text("iOS Native")
                            .foregroundColor(.secondary)
                        #elseif os(macOS)
                        Text("macOS Native")
                            .foregroundColor(.secondary)
                        #endif
                    }
                    HStack {
                        Text("Background Audio")
                        Spacer()
                        Text("AVPlayer + MPNowPlayingInfo")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .alert("Clear Offline Cache", isPresented: $showingClearCacheAlert) {
                Button("Delete All Audio", role: .destructive) {
                    cache.clearAllCache()
                    cacheClearedMessage = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove all downloaded offline audio files from this device.")
            }
        }
    }
}
