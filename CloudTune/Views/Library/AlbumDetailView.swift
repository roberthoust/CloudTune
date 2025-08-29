import SwiftUI
import ImageIO
import UniformTypeIdentifiers

// MARK: - Tiny downscaler to avoid decoding full-size artwork on the main thread
private struct AlbumArt: View, Equatable {
    static func == (lhs: AlbumArt, rhs: AlbumArt) -> Bool {
        lhs.data?.count == rhs.data?.count && lhs.side == rhs.side
    }

    let data: Data?
    let side: CGFloat

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image("DefaultCover")
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .cornerRadius(10)
        .task(id: data?.count) {
            guard image == nil else { return }
            image = await downscale(data: data, to: CGSize(width: side * UIScreen.main.scale,
                                                           height: side * UIScreen.main.scale))
        }
    }

    private func downscale(data: Data?, to targetPx: CGSize) async -> UIImage? {
        guard let data, !data.isEmpty else { return nil }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let opts: [CFString: Any] = [
                    kCGImageSourceShouldCache: false
                ]
                guard let src = CGImageSourceCreateWithData(data as CFData, opts as CFDictionary) else {
                    cont.resume(returning: nil); return
                }
                let maxPx = max(targetPx.width, targetPx.height)
                let thumbOpts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceShouldCacheImmediately: false,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: Int(maxPx)
                ]
                if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) {
                    cont.resume(returning: UIImage(cgImage: cg))
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: - Row is Equatable so SwiftUI can skip re-rendering unchanged rows
private struct SongRowButton: View, Equatable {
    static func == (lhs: SongRowButton, rhs: SongRowButton) -> Bool {
        lhs.song.id == rhs.song.id &&
        lhs.isCurrent == rhs.isCurrent &&
        lhs.isPlaying == rhs.isPlaying
    }

    let song: Song
    let isCurrent: Bool
    let isPlaying: Bool
    let onTap: () -> Void
    let artworkSide: CGFloat

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                AlbumArt(data: song.artwork, side: artworkSide)
                    .equatable()

                VStack(alignment: .leading, spacing: 2) {
                    Text(song.displayTitle)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    Text(song.displayArtist)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isCurrent {
                    Image(systemName: isPlaying ? "waveform" : "waveform.circle.fill")
                        .foregroundColor(.appAccent)
                        .imageScale(.medium)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
    }
}

struct AlbumDetailView: View {
    let albumName: String
    /// Pass in unsorted songs; we sort once here to avoid per-render work.
    let songs: [Song]

    @EnvironmentObject private var playbackVM: PlaybackViewModel
    @State private var selectedPlaylist: Playlist? = nil

    // Sort once up-front; `songs` is immutable for the lifetime of this view.
    private let sortedSongs: [Song]

    init(albumName: String, songs: [Song]) {
        self.albumName = albumName
        self.songs = songs
        self.sortedSongs = songs.sorted {
            let d0 = $0.discNumber ?? 0
            let d1 = $1.discNumber ?? 0
            if d0 != d1 { return d0 < d1 }
            let t0 = $0.trackNumber ?? Int.max
            let t1 = $1.trackNumber ?? Int.max
            return t0 < t1
        }
    }

    var body: some View {
        // Use List for efficient cell reuse & diffing; avoid global animations.
        List {
            ForEach(sortedSongs, id: \.id) { song in
                SongRowButton(
                    song: song,
                    isCurrent: playbackVM.currentSong?.id == song.id,
                    isPlaying: playbackVM.isPlaying,
                    onTap: { handleTap(song) },
                    artworkSide: 56
                )
                .equatable()
                .contextMenu {
                    Button {
                        playbackVM.songToAddToPlaylist = song
                        playbackVM.showAddToPlaylistSheet = true
                    } label: {
                        Label("Add to Playlist", systemImage: "text.badge.plus")
                    }
                }
            }
        }
        .listStyle(.plain)
        .sheet(isPresented: $playbackVM.showAddToPlaylistSheet) {
            if let song = playbackVM.songToAddToPlaylist {
                AddToPlaylistSheet(song: song, selectedPlaylist: $selectedPlaylist)
                    .environmentObject(playbackVM)
            }
        }
        .navigationTitle(albumName)
    }

    private func handleTap(_ song: Song) {
        if playbackVM.currentSong?.id == song.id {
            playbackVM.showPlayer = true
            return
        }
        playbackVM.play(song: song, in: sortedSongs, contextName: albumName)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            playbackVM.showPlayer = true
        }
    }
}
