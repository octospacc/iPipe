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
/// Strictly enforces a consistent square aspect ratio within its bounds so that
/// widescreen thumbnails never deform or overflow the layout.
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
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                GeometryReader { geo in
                    ZStack {
                        if let image = image {
                            Image(platformImage: image)
                                .resizable()
                                .aspectRatio(contentMode: contentMode)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
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
                            .frame(width: geo.size.width, height: geo.size.height)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
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
