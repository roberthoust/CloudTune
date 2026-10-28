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
    @State private var previousImage: UIImage?
    @State private var previousOpacity: Double = 0.0
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

            ZStack {
                if let previousImage {
                    Image(uiImage: previousImage)
                        .resizable()
                        .scaledToFill()
                        .opacity(previousOpacity)
                }
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .opacity(imageOpacity)
                }
            }
            .frame(width: side, height: side)
            .clipped()
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
            setImageWithCrossfade(cached)
            return
        }
        // 2) No artwork? show default and bail.
        guard let artworkData, hasArtwork else {
            setImageWithCrossfade(nil)
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
                setImageWithCrossfade(thumb)
            }
        }
    }

    private func setImageWithCrossfade(_ newImage: UIImage?) {
        // If bytes are identical, keep as-is (no animation)
        if let current = image, let next = newImage, current.pngData() == next.pngData() {
            previousImage = nil
            previousOpacity = 0.0
            image = next
            imageOpacity = 1.0
            return
        }

        // Prepare crossfade: current becomes 'previous', new becomes 'image'
        previousImage = image
        previousOpacity = (previousImage == nil) ? 0.0 : 1.0

        image = newImage
        imageOpacity = (newImage == nil) ? 0.0 : 0.0

        // Animate both layers for a smooth transition
        withAnimation(.easeInOut(duration: 0.25)) {
            previousOpacity = 0.0
            if newImage != nil { imageOpacity = 1.0 }
        }

        // Cleanup previous image after the animation completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            // Only clear if we haven't started another transition
            if previousOpacity == 0.0 {
                previousImage = nil
            }
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

    @EnvironmentObject var pro: ProStore

    @State private var showMoreActions = false
    @State private var activeSheet: ActiveSheet?
    @State private var paywallReason: PaywallReason?

    enum ActiveSheet: Identifiable {
        case eq
        case speedPitch
        case addToPlaylist(Song)

        var id: Int {
            switch self {
            case .eq: return 0
            case .speedPitch: return 1
            case .addToPlaylist(let s): return s.id.hashValue
            }
        }
    }

    // Full-screen covers: we split the binding so only one is active at a time
    private var eqSheetBinding: Binding<ActiveSheet?> {
        .init(
            get: { if case .eq = activeSheet { return activeSheet } else { return nil } },
            set: { if $0 == nil { activeSheet = nil } }
        )
    }
    private var speedPitchSheetBinding: Binding<ActiveSheet?> {
        .init(
            get: { if case .speedPitch = activeSheet { return activeSheet } else { return nil } },
            set: { if $0 == nil { activeSheet = nil } }
        )
    }
    private var addToPlaylistSheetBinding: Binding<ActiveSheet?> {
        .init(
            get: { if case .addToPlaylist = activeSheet { return activeSheet } else { return nil } },
            set: { if $0 == nil { activeSheet = nil } }
        )
    }

    private func proLabel(_ text: String, locked: Bool) -> some View {
        HStack(spacing: 4) {
            if locked { Image(systemName: "lock.fill").imageScale(.small) }
            Text(text)
        }
        .font(.footnote)
        .foregroundColor(.secondary)
        .padding(.top, -8)
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
                    hasArtwork: song.artworkID != nil
                )
                .id(song.id) // ensure state is reset per track

                NowPlayingLabels(
                    title: song.displayTitle,
                    artist: song.displayArtist
                )
            }

            seekBar

            transport

            HStack(spacing: 12) {
                // EQ and speed/pitch are Pro; free users get speed/pitch on a few songs.
                Button(action: {
                    if pro.isPro { activeSheet = .eq } else { paywallReason = .equalizer }
                }) {
                    // Uppercased once per render (cheap), you can also store in VM if you prefer
                    proLabel("EQ: \(EQManager.shared.activePresetName.uppercased())", locked: !pro.isPro)
                }

                Button(action: {
                    if pro.canUseSpeedPitch(on: playbackVM.currentSong?.id) {
                        activeSheet = .speedPitch
                    } else {
                        paywallReason = .speedPitch
                    }
                }) {
                    let mode = playbackVM.linkSpeedToPitch ? "TAPE" : "SPEED"
                    proLabel(String(format: "\(mode): %.2fx", playbackVM.playbackRate),
                             locked: !pro.canUseSpeedPitch(on: playbackVM.currentSong?.id))
                }
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
        .sheet(item: $paywallReason) { reason in
            PaywallView(reason: reason)
                .environmentObject(pro)
        }
        .fullScreenCover(item: eqSheetBinding) { _ in
            EQSettingsView()
                .ignoresSafeArea(.keyboard)
                .background(Color(.systemBackground).ignoresSafeArea())
        }
        .fullScreenCover(item: speedPitchSheetBinding) { _ in
            SpeedPitchSheet(
                playbackRate: $playbackVM.playbackRate,
                linkSpeedToPitch: $playbackVM.linkSpeedToPitch,
                semitones: $playbackVM.semitones,
                fineCents: $playbackVM.fineCents,
                totalPitchCents: $playbackVM.pitchCents
            )
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

private struct SpeedPitchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var pro: ProStore

    @Binding var playbackRate: Float

    /// When ON, speed drives pitch (tape behavior): pitchCents = 1200 * log2(rate)
    @Binding var linkSpeedToPitch: Bool

    // UI-friendly pitch controls (S/P Changer style)
    @Binding var semitones: Int
    @Binding var fineCents: Float

    // Derived/combined pitch in cents (engine-facing)
    // We accept it as a binding so the sheet can display it and reset it cleanly.
    @Binding var totalPitchCents: Float

    private let minRate: Float = 0.2
    private let maxRate: Float = 5.0

    private let minSemitones: Int = -24
    private let maxSemitones: Int = 24

    private let minFine: Float = -50
    private let maxFine: Float = 50

    // One-press steps (S/P Changer feel)
    private let speedStep: Float = 0.05   // each tap adjusts speed by 0.05x
    private let fineStep: Float = 10      // each tap adjusts fine pitch by 10 cents

    var body: some View {
        NavigationStack {
            Form {
                if !pro.isPro {
                    Section {
                        Label(pro.trialSongsLeft == 1
                              ? "Free trial: 1 more song with custom speed or pitch."
                              : "Free trial: \(pro.trialSongsLeft) more songs with custom speed or pitch.",
                              systemImage: "sparkles")
                            .font(.subheadline)
                            .foregroundStyle(Color("appAccent"))
                    } footer: {
                        Text("Replaying a trial song is free. CloudTune Pro unlocks speed & pitch for every song.")
                    }
                }

                Section {
                    Toggle("Link Speed & Pitch", isOn: $linkSpeedToPitch)
                } footer: {
                    Text("When enabled, changing speed also changes pitch (tape / slowed behavior).")
                }

                Section("Speed") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(String(format: "%.2fx", playbackRate))
                            .font(.headline)

                        // One-press controls (no slider)
                        HStack(spacing: 12) {
                            Button("−") {
                                playbackRate = clamp(playbackRate - speedStep, minRate, maxRate)
                            }
                            .buttonStyle(.borderedProminent)

                            Button("+") {
                                playbackRate = clamp(playbackRate + speedStep, minRate, maxRate)
                            }
                            .buttonStyle(.borderedProminent)

                            Spacer()

                            Button("1.00x") {
                                playbackRate = 1.0
                            }
                            .buttonStyle(.bordered)
                        }

                        // Quick presets
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Presets")
                                .font(.subheadline)
                                .foregroundColor(.secondary)

                            HStack {
                                presetButton(0.75)
                                presetButton(0.85)
                                presetButton(1.0)
                                presetButton(1.15)
                            }
                            HStack {
                                presetButton(1.25)
                                presetButton(1.5)
                                presetButton(2.0)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Pitch") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(String(format: "%+d st  %+0.0f cents   (Total: %+0.0f)", semitones, fineCents, totalPitchCents))
                            .font(.headline)

                        if linkSpeedToPitch {
                            // In linked mode, pitch is derived from speed; show it as read-only.
                            Text("Pitch is linked to speed. Disable Link to adjust pitch manually.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            HStack {
                                Text("Semitones")
                                Spacer()
                                Stepper(value: $semitones, in: minSemitones...maxSemitones) {
                                    Text(String(format: "%+d", semitones))
                                        .monospacedDigit()
                                }
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("Fine")
                                    Spacer()
                                    Text(String(format: "%+0.0f", fineCents))
                                        .monospacedDigit()
                                        .foregroundColor(.secondary)
                                }

                                HStack(spacing: 12) {
                                    Button("−") {
                                        fineCents = clamp(fineCents - fineStep, minFine, maxFine)
                                    }
                                    .buttonStyle(.bordered)

                                    Button("+") {
                                        fineCents = clamp(fineCents + fineStep, minFine, maxFine)
                                    }
                                    .buttonStyle(.bordered)

                                    Spacer()

                                    Button("0") {
                                        fineCents = 0
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }

                            Text("Tip: ‘Slowed’ usually feels good around -2 to -6 semitones.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Button("Reset", role: .destructive) {
                        playbackRate = 1.0
                        semitones = 0
                        fineCents = 0
                        totalPitchCents = 0
                    }
                }
            }
            .navigationTitle("Speed / Pitch")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func presetButton(_ value: Float) -> some View {
        Button(String(format: "%.2g×", Double(value))) {
            playbackRate = clamp(value, minRate, maxRate)
        }
        .buttonStyle(.bordered)
    }

    private func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float {
        max(lo, min(v, hi))
    }
}
