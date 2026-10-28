import SwiftUI

public struct SettingsView: View {
    @ObservedObject private var cache = CacheService.shared
    @ObservedObject private var storage = StorageService.shared
    @AppStorage(AudioPlayerService.autoDownloadOnPlayKey) private var autoDownloadOnPlay = false
    
    @State private var showingClearCacheAlert = false
    @State private var showingClearHistoryAlert = false
    
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
                
                Section(header: Text("Playback")) {
                    Toggle(isOn: $autoDownloadOnPlay) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Automatically Download Songs on Play")
                            Text("Songs are saved for offline playback as soon as you play them.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Section(header: Text("Listening History")) {
                    HStack {
                        Text("Songs in History")
                        Spacer()
                        Text("\(storage.history.count)")
                            .foregroundColor(.secondary)
                    }
                    Button(role: .destructive, action: {
                        showingClearHistoryAlert = true
                    }) {
                        Label("Clear Listening History", systemImage: "clock.arrow.circlepath")
                            .foregroundColor(.red)
                    }
                    .disabled(storage.history.isEmpty)
                }
                
                Section(header: Text("Offline Cache Storage")) {
                    Button(role: .destructive, action: {
                        showingClearCacheAlert = true
                    }) {
                        Label("Clear Downloaded Audio Cache", systemImage: "trash")
                            .foregroundColor(.red)
                    }
                }
                
                Section(header: Text("About iPipe")) {
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
            #if os(macOS)
            .formStyle(.grouped)
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            #endif
            .alert("Clear Offline Cache", isPresented: $showingClearCacheAlert) {
                Button("Delete All Audio", role: .destructive) {
                    cache.clearAllCache()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove all downloaded offline audio files from this device.")
            }
            .alert("Clear Listening History", isPresented: $showingClearHistoryAlert) {
                Button("Clear History", role: .destructive) {
                    storage.clearHistory()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes every song from the History list. Your library and playlists are not affected.")
            }
        }
    }
}
