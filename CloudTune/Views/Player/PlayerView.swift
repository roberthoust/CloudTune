import SwiftUI

// MARK: - Lightweight artwork cache (tiny & safe)
final class ArtworkCache: NSCache<NSString, UIImage> {
    static let shared = ArtworkCache()
    private override init() {
        super.init()
        name = "PlayerView.ArtworkCache"
        countLimit = 200          // tune as needed
        totalCostLimit = 16 * 1_024 * 1_024 // ~16MB
    }
}

// MARK: - Small, focused subviews keep PlayerView “quiet”
private struct ArtworkView: View, Equatable {
    static func == (lhs: ArtworkView, rhs: ArtworkView) -> Bool {
        // Only re-render if the song id or placeholder size changes
        lhs.songKey == rhs.songKey && lhs.side == rhs.side && lhs.hasArtwork == rhs.hasArtwork
    }

    let songKey: String
    let artworkData: Data?
    let side: CGFloat
    let hasArtwork: Bool

    @State private var image: UIImage?
    @State private var imageOpacity: Double = 0.0
    @State private var pendingKey: String?
    @State private var decodeToken = UUID()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color("appAccent"), lineWidth: 2)
                .background(
                    RoundedRectangle(cornerRadius: 24)
                        .fill(Color(UIColor.secondarySystemBackground))
                )
                .frame(width: side + 20, height: side + 20)

            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .opacity(imageOpacity)
                        .transition(.opacity)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .onAppear(perform: decodeIfNeeded)
        .onChange(of: songKey) { _ in
            decodeToken = UUID()   // invalidate any in-flight decode
            decodeIfNeeded()
        }
        .onChange(of: artworkData?.count) { _ in
            decodeToken = UUID()   // invalidate in-flight decode because data changed
            decodeIfNeeded()
        }
    }

    private func decodeIfNeeded() {
        // 1) Cache hit?
        let cacheKey = NSString(string: "\(songKey)-\(Int(side))")
        let keyForThisDecode = "\(songKey)-\(Int(side))"
        let tokenForThisDecode = decodeToken
        pendingKey = keyForThisDecode
        if let cached = ArtworkCache.shared.object(forKey: cacheKey) {
            pendingKey = keyForThisDecode
            // Only apply if we're still decoding for the same song
            guard tokenForThisDecode == decodeToken else { return }
            setImageWithFade(cached)
            return
        }
        // 2) No artwork? show default and bail.
        guard let artworkData, hasArtwork else {
            setImageWithFade(nil)
            return
        }
        // 3) Decode off-main, generate a sized thumbnail, then cache.
        let sideCopy = side
        let scale = UIScreen.main.scale
        Task.detached(priority: .utility) {
            guard let full = UIImage(data: artworkData) else { return }
            let target = CGSize(width: sideCopy * scale, height: sideCopy * scale)
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: target, format: format)
            let thumb = renderer.image { _ in
                full.draw(in: CGRect(origin: .zero, size: target))
            }
            await MainActor.run {
                // Bail if a newer song arrived while we were decoding
                guard pendingKey == keyForThisDecode, tokenForThisDecode == decodeToken else { return }
                ArtworkCache.shared.setObject(
                    thumb,
                    forKey: cacheKey,
                    cost: (thumb.cgImage?.bytesPerRow ?? 0) * (thumb.cgImage?.height ?? 0)
                )
                setImageWithFade(thumb)
            }
        }
    }

    private func setImageWithFade(_ newImage: UIImage?) {
        // If nothing changed, skip animations
        if let current = image, let next = newImage, current.pngData() == next.pngData() {
            imageOpacity = 1.0
            image = next
            return
        }
        image = newImage
        // Start from transparent and fade in
        imageOpacity = 0.0
        withAnimation(.easeInOut(duration: 0.25)) {
            imageOpacity = 1.0
        }
    }
}

private struct NowPlayingLabels: View, Equatable {
    let title: String
    let artist: String

    static func == (lhs: NowPlayingLabels, rhs: NowPlayingLabels) -> Bool {
        lhs.title == rhs.title && lhs.artist == rhs.artist
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal)

            Text(artist)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - PlayerView
struct PlayerView: View {
    @EnvironmentObject var playbackVM: PlaybackViewModel
    @EnvironmentObject var playlistVM: PlaylistViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showMoreActions = false
    @State private var activeSheet: ActiveSheet?

    enum ActiveSheet: Identifiable {
        case eq
        case addToPlaylist(Song)
        var id: Int { switch self { case .eq: 0; case .addToPlaylist(let s): s.id.hashValue } }
    }

    // Full-screen covers: we split the binding so only one is active at a time
    private var eqSheetBinding: Binding<ActiveSheet?> {
        .init(
            get: { if case .eq = activeSheet { return activeSheet } else { return nil } },
            set: { if $0 == nil { activeSheet = nil } }
        )
    }
    private var addToPlaylistSheetBinding: Binding<ActiveSheet?> {
        .init(
            get: { if case .addToPlaylist = activeSheet { return activeSheet } else { return nil } },
            set: { if $0 == nil { activeSheet = nil } }
        )
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    var body: some View {
        // No ZStacks/materials/shadows: keep layers simple for the compositor
        VStack(spacing: 24) {
            topBar

            if let song = playbackVM.currentSong {
                // Artwork + labels are Equatable subviews (don’t refresh unless their props change)
                ArtworkView(
                    songKey: song.id,
                    artworkData: song.artwork,
                    side: 240,
                    hasArtwork: song.artwork != nil
                )
                .id(song.id) // ensure state is reset per track

                NowPlayingLabels(
                    title: song.displayTitle,
                    artist: song.displayArtist
                )
            }

            seekBar

            transport

            Button(action: { activeSheet = .eq }) {
                // Uppercased once per render (cheap), you can also store in VM if you prefer
                Text("EQ: \(EQManager.shared.activePresetName.uppercased())")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.top, -8)
            }

            controlsRow

            Spacer(minLength: 40)
        }
        .padding()
        .background(Color(.systemBackground))     // opaque = cheap
        .ignoresSafeArea(.keyboard)               // avoid relayout during keyboard
        .confirmationDialog("More Actions", isPresented: $showMoreActions, titleVisibility: .visible) {
            if let current = playbackVM.currentSong {
                Button("Add to Playlist", systemImage: "text.badge.plus") {
                    activeSheet = .addToPlaylist(current)
                }
            }
            Button("Cancel", role: .cancel) { showMoreActions = false }
        }
        .fullScreenCover(item: eqSheetBinding) { _ in
            EQSettingsView()
                .ignoresSafeArea(.keyboard)
                .background(Color(.systemBackground).ignoresSafeArea())
        }
        .fullScreenCover(item: addToPlaylistSheetBinding) { sheet in
            if case .addToPlaylist(let song) = sheet {
                AddToPlaylistSheet(song: song, selectedPlaylist: .constant(nil))
                    .environmentObject(playlistVM)
                    .environmentObject(playbackVM)
                    .ignoresSafeArea(.keyboard)
            }
        }
    }

    // MARK: - Sections

    private var topBar: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.down")
                    .font(.title2)
                    .padding(8)
                    .background(Color(UIColor.secondarySystemBackground), in: Circle())
            }
            Spacer()
            Text("Now Playing")
                .font(.headline)
                .foregroundColor(.secondary)
            Spacer()
            Button(action: { showMoreActions = true }) {
                Image(systemName: "ellipsis")
                    .font(.title2)
                    .padding(8)
                    .background(Color(UIColor.secondarySystemBackground), in: Circle())
            }
        }
        .padding(.horizontal)
    }

    private var seekBar: some View {
        VStack(spacing: 8) {
            SeekBarView(
                currentTime: $playbackVM.currentTime,
                duration: playbackVM.duration,
                onSeek: { playbackVM.seek(to: $0) }
            )
            .tint(Color("appAccent"))
            .frame(height: 30)

            HStack {
                Text(formatTime(playbackVM.currentTime))
                Spacer()
                Text(formatTime(playbackVM.duration))
            }
            .font(.caption2)
            .foregroundColor(.gray)
            .padding(.horizontal, 12)
        }
        .padding(.horizontal)
    }

    private var transport: some View {
        HStack(spacing: 80) {
            Button(action: { playbackVM.skipBackward() }) {
                Image(systemName: "backward.fill").font(.title2)
            }
            Button(action: { playbackVM.togglePlayPause() }) {
                Image(systemName: playbackVM.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 70, height: 70)
            }
            Button(action: { playbackVM.skipForward() }) {
                Image(systemName: "forward.fill").font(.title2)
            }
        }
        .padding(.vertical, 8)
    }

    private var controlsRow: some View {
        HStack(spacing: 40) {
            Button(action: { playbackVM.toggleShuffle() }) {
                Image(systemName: playbackVM.isShuffle ? "shuffle.circle.fill" : "shuffle.circle")
                    .font(.title3)
                    .foregroundStyle(playbackVM.isShuffle ? Color("appAccent") : Color.gray.opacity(0.5))
            }
            Button(action: { playbackVM.toggleRepeatMode() }) {
                Image(systemName:
                        playbackVM.repeatMode == .repeatAll ? "repeat.circle.fill" :
                        playbackVM.repeatMode == .repeatOne ? "repeat.1.circle.fill" :
                        "repeat.circle"
                )
                .font(.title3)
                .foregroundStyle(playbackVM.repeatMode == .off ? Color.gray.opacity(0.5) : Color("appAccent"))
            }
            Button(action: { activeSheet = .eq }) {
                Image(systemName: "slider.horizontal.3").font(.title3)
            }
        }
        .padding(.top, 4)
    }
}
