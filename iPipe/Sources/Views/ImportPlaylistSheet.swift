import SwiftUI

/// Imports a public YouTube / YouTube Music playlist from a pasted URL.
public struct ImportPlaylistSheet: View {
    @ObservedObject private var storage = StorageService.shared
    @Environment(\.dismiss) private var dismiss
    
    @State private var urlText: String = ""
    @State private var isImporting: Bool = false
    @State private var errorMessage: String?
    @FocusState private var urlFieldFocused: Bool
    
    private let onImported: (Playlist) -> Void
    
    public init(onImported: @escaping (Playlist) -> Void = { _ in }) {
        self.onImported = onImported
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import Playlist")
                        .font(.title2.bold())
                    Text("from YouTube or YouTube Music")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Paste a playlist link to add its songs to your library.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    TextField("https://music.youtube.com/playlist?list=…", text: $urlText)
                        .textFieldStyle(.roundedBorder)
                        .focused($urlFieldFocused)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        #endif
                        .onSubmit {
                            startImport()
                        }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Label("playlist?list=… links", systemImage: "link")
                        Label("watch_videos?video_ids=… links", systemImage: "link")
                        Label("or a bare playlist ID", systemImage: "number")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    
                    if let errorMessage {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundColor(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                    }
                    
                    Button(action: startImport) {
                        HStack(spacing: 8) {
                            if isImporting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "square.and.arrow.down")
                            }
                            Text(isImporting ? "Importing…" : "Import Playlist")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isImporting || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(20)
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 500, minHeight: 360, idealHeight: 400)
        #endif
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #endif
        .onAppear {
            urlFieldFocused = true
        }
    }
    
    private func startImport() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isImporting else { return }
        isImporting = true
        errorMessage = nil
        
        Task {
            do {
                let imported = try await YouTubeDirectService.shared.importPlaylist(from: trimmed)
                let playlist = storage.importPlaylist(title: imported.title, tracks: imported.tracks)
                isImporting = false
                onImported(playlist)
                dismiss()
            } catch {
                isImporting = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
