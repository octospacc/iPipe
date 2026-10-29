import SwiftUI

#if canImport(UIKit)
import UIKit
extension Image {
    init(platformImage: PlatformImage) {
        self.init(uiImage: platformImage)
    }
}
#elseif canImport(AppKit)
import AppKit
extension Image {
    init(platformImage: PlatformImage) {
        self.init(nsImage: platformImage)
    }
}
#endif

/// Displays an artwork thumbnail using persistent disk and memory caching.
/// If already cached on disk, loads immediately without delay or network request,
/// ensuring full offline support.
public struct CachedArtworkView: View {
    public let url: URL?
    public var cornerRadius: CGFloat
    public var placeholderIcon: String
    public var placeholderIconSize: CGFloat?
    public var contentMode: ContentMode

    @State private var image: PlatformImage?

    public init(
        url: URL?,
        cornerRadius: CGFloat = 8,
        placeholderIcon: String = "music.note",
        placeholderIconSize: CGFloat? = nil,
        contentMode: ContentMode = .fill
    ) {
        self.url = url
        self.cornerRadius = cornerRadius
        self.placeholderIcon = placeholderIcon
        self.placeholderIconSize = placeholderIconSize
        self.contentMode = contentMode
        _image = State(initialValue: ImageCacheService.shared.image(for: url))
    }

    public var body: some View {
        ZStack {
            if let image = image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                ZStack {
                    Color.gray.opacity(0.25)
                    if let size = placeholderIconSize {
                        Image(systemName: placeholderIcon)
                            .font(.system(size: size))
                            .foregroundColor(.secondary)
                    } else {
                        Image(systemName: placeholderIcon)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .onAppear {
            loadImageIfNeeded()
        }
        .onChange(of: url) { newUrl in
            image = ImageCacheService.shared.image(for: newUrl)
            loadImageIfNeeded()
        }
    }

    private func loadImageIfNeeded() {
        if image != nil { return }
        guard let url = url else { return }
        Task {
            if let loaded = await ImageCacheService.shared.loadImage(for: url) {
                await MainActor.run {
                    self.image = loaded
                }
            }
        }
    }
}
