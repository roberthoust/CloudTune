extension String {
    func ifEmpty(_ fallback: String) -> String {
        self.isEmpty ? fallback : self
    }
}


import SwiftUI
import Combine
import UIKit

// Lightweight shared thumbnail cache (LRU via NSCache)
final class ImageThumbCache: NSCache<NSString, UIImage> {
    static let shared = ImageThumbCache()
    private override init() {
        super.init()
        name = "ImageThumbCache"
        // Tune to your app; these are conservative defaults.
        countLimit = 600                 // max number of thumbnails
        totalCostLimit = 24 * 1024 * 1024 // ~24 MB budget
    }
}

fileprivate func imageCost(_ image: UIImage) -> Int {
    if let cg = image.cgImage {
        return cg.bytesPerRow * cg.height // rough byte size
    }
    // Fallback estimate (RGBA)
    let px = Int(image.size.width * image.scale) * Int(image.size.height * image.scale)
    return px * 4
}

// Free helpers so they are NOT MainActor-isolated and can run off the main thread
fileprivate func albumCacheKey(for data: Data) -> NSString {
    // Use first 32 bytes as a cheap pseudo-hash key; good enough for thumbnail caching.
    let prefix = data.prefix(32)
    return NSString(string: prefix.base64EncodedString())
}

fileprivate func makeAlbumThumbnail(from data: Data, side: CGFloat, scale: CGFloat) -> UIImage? {
    guard let full = UIImage(data: data) else { return nil }
    let target = CGSize(width: side * scale, height: side * scale)
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: target, format: format)
    let img = renderer.image { _ in
        full.draw(in: CGRect(origin: .zero, size: target))
    }
    return img
}

@MainActor
private struct AlbumArtwork: View {
    let data: Data?
    let side: CGFloat

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image("DefaultCover")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .redacted(reason: .placeholder)
                    .task { await decodeIfNeeded() }
            }
        }
        .frame(width: side, height: side)
        .cornerRadius(side * 0.1)
        .clipped()
    }

    private func decodeIfNeeded() async {
        guard let data else { return }

        // Compute cache key and grab cached image on the main actor first.
        let key = albumCacheKey(for: data)
        if let cached = ImageThumbCache.shared.object(forKey: key) {
            self.image = cached
            return
        }

        // Capture simple values, then generate thumbnail off the main thread.
        let sideCopy = side
        let scale = UIScreen.main.scale

        let thumb = await Task.detached(priority: .utility) {
            makeAlbumThumbnail(from: data, side: sideCopy, scale: scale)
        }.value

        if let thumb {
            ImageThumbCache.shared.setObject(thumb, forKey: key, cost: imageCost(thumb))
            self.image = thumb
        }
    }
}

struct AlbumsView: View {
    @EnvironmentObject var libraryVM: LibraryViewModel
    @State private var isGridView = true
    @State private var groupedAlbums: [(album: String, songs: [Song])] = []

    let columns = [
        GridItem(.flexible(), spacing: 20),
        GridItem(.flexible(), spacing: 20)
    ]

    var body: some View {
        VStack {
            HStack {
                Spacer()
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isGridView.toggle()
                    }
                }) {
                    Image(systemName: isGridView ? "list.bullet" : "square.grid.2x2")
                        .imageScale(.large)
                        .foregroundColor(Color("appAccent"))
                }
                .padding(.trailing, 20)
            }

            ScrollView {
                if isGridView {
                    LazyVGrid(columns: columns, spacing: 24) {
                        albumItems
                    }
                    .transition(.opacity.combined(with: .scale))
                    .animation(.easeInOut(duration: 0.3), value: isGridView)
                } else {
                    LazyVStack(spacing: 16) {
                        albumItems
                    }
                    .padding(.horizontal, 12)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: isGridView)
                }

                Spacer(minLength: 100) // extra scroll space so MiniPlayer doesn't overlap last albums
            }
            .padding(.top, 6)
            .onAppear { rebuildGroupedAlbums() }
            .onChange(of: libraryVM.songs) { _, _ in rebuildGroupedAlbums() }
            .onReceive(libraryVM.$songMetadataCache) { _ in rebuildGroupedAlbums() }
        }
        .navigationTitle("Albums")
        .tint(Color("appAccent"))
    }

    private var albumItems: some View {
        ForEach(groupedAlbums, id: \.album) { albumGroup in
            let firstSong = albumGroup.songs.first
            let metadata = firstSong.flatMap { libraryVM.songMetadataCache[$0.id] }

            NavigationLink(destination: AlbumDetailView(albumName: albumGroup.album, songs: albumGroup.songs)) {
                if isGridView {
                    VStack(spacing: 10) {
                        AlbumArtwork(data: firstSong?.artwork, side: 140)

                        Text(metadata?.album ?? albumGroup.album)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundColor(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(width: 140)
                    }
                    .padding(.vertical, 6)
                    .frame(width: 160)
                    .contentShape(Rectangle())
                } else {
                    HStack {
                        AlbumArtwork(data: firstSong?.artwork, side: 70)

                        Text(metadata?.album ?? albumGroup.album)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .shadow(color: Color.primary.opacity(0.06), radius: 1, x: 0, y: 1)

                        Spacer()
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(.systemBackground).opacity(0.7))
                            .shadow(color: Color("appAccent").opacity(0.08), radius: 4, x: 0, y: 2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color("appAccent").opacity(0.11), lineWidth: 0.7)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                }
            }
            .tint(Color("appAccent"))
        }
    }

    private func rebuildGroupedAlbums() {
        let songs = libraryVM.songs
        let meta = libraryVM.songMetadataCache

        Task.detached(priority: .utility) {
            let groupedDict = Dictionary(grouping: songs, by: { song in
                let m = meta[song.id]
                let albumName = (m?.album ?? song.album).trimmingCharacters(in: .whitespacesAndNewlines)
                return albumName.isEmpty ? "No Album" : albumName
            })
            let result = groupedDict
                .map { (key, value) in (album: key, songs: value) }
                .sorted { $0.album.localizedCaseInsensitiveCompare($1.album) == .orderedAscending }

            await MainActor.run {
                self.groupedAlbums = result
            }
        }
    }
}
