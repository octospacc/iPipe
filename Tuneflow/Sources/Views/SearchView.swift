import SwiftUI

public struct SearchView: View {
    @StateObject private var viewModel = SearchViewModel()
    @ObservedObject private var player = AudioPlayerService.shared
    @State private var selectedTrackForPlaylist: Track?
    
    public init() {}
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    
                    TextField("Search songs, artists, albums...", text: $viewModel.query)
                        .textFieldStyle(.plain)
                        .onSubmit {
                            viewModel.performSearch()
                        }
                    
                    if !viewModel.query.isEmpty {
                        Button(action: {
                            viewModel.query = ""
                            viewModel.searchResults = []
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(Color.gray.opacity(0.12))
                .cornerRadius(10)
                .padding(.horizontal)
                .padding(.vertical, 8)
                
                // Content
                if viewModel.isSearching {
                    Spacer()
                    ProgressView("Searching YouTube...")
                    Spacer()
                } else if let error = viewModel.errorMessage {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text(error)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    Spacer()
                } else if viewModel.searchResults.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary.opacity(0.6))
                        Text("Search for any music")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Anonymous, privacy-preserving music playback")
                            .font(.footnote)
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(Array(viewModel.searchResults.enumerated()), id: \.element.id) { index, track in
                            TrackRowView(
                                track: track,
                                onPlay: {
                                    player.playQueue(tracks: viewModel.searchResults, startIndex: index)
                                },
                                onAddToPlaylist: {
                                    selectedTrackForPlaylist = track
                                }
                            )
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Search")
            .sheet(item: $selectedTrackForPlaylist) { track in
                AddToPlaylistSheet(track: track)
            }
        }
    }
}
