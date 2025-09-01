import SwiftUI
import Combine

// (Optional) Keep the observer for future use, but the lighter view below
// doesn’t depend on keyboard state to avoid layout/animation churn.
final class KeyboardObserver: ObservableObject {
    @Published var isVisible: Bool = false
    private var cancellables = Set<AnyCancellable>()

    init() {
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
            .sink { [weak self] _ in self?.isVisible = true }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
            .sink { [weak self] _ in self?.isVisible = false }
            .store(in: &cancellables)
    }
}

struct PlayerView: View {
    @EnvironmentObject var playbackVM: PlaybackViewModel
    @EnvironmentObject var playlistVM: PlaylistViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showMoreActions = false
    @State private var activeSheet: ActiveSheet?
    @State private var cachedArtwork: UIImage?

    enum ActiveSheet: Identifiable {
        case eq
        case addToPlaylist(Song)

        var id: Int {
            switch self {
            case .eq: return 0
            case .addToPlaylist(let song): return song.id.hashValue
            }
        }
    }

    // Split bindings so each cover presents independently
    private var eqSheetBinding: Binding<ActiveSheet?> {
        Binding(
            get: { if case .eq = activeSheet { return activeSheet } else { return nil } },
            set: { if $0 == nil { activeSheet = nil } }
        )
    }

    private var addToPlaylistSheetBinding: Binding<ActiveSheet?> {
        Binding(
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
        // NOTE: No ZStacks, materials, shadows, or opacity tricks.
        // Covers are full-screen and fully occlude this view when active,
        // so nothing behind will animate or re-layout during keyboard show.
        VStack(spacing: 24) {
            // Top Bar
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

            // Artwork and Track Info
            if let song = playbackVM.currentSong {
                VStack(spacing: 12) {
                    // Lightweight artwork: no shadow, no material, fixed layout
                    ZStack {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color("appAccent"), lineWidth: 2)
                            .background(
                                RoundedRectangle(cornerRadius: 24)
                                    .fill(Color(UIColor.secondarySystemBackground))
                            )
                            .frame(width: 260, height: 260)

                        if let img = cachedArtwork {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 240, height: 240)
                                .clipShape(RoundedRectangle(cornerRadius: 20))
                        } else {
                            Image("DefaultCover")
                                .resizable()
                                .scaledToFill()
                                .frame(width: 240, height: 240)
                                .clipShape(RoundedRectangle(cornerRadius: 20))
                        }
                    }
                    .task(id: playbackVM.currentSong?.id) {
                        // Decode artwork off-main exactly once per track
                        if let data = playbackVM.currentSong?.artwork {
                            let decoded = await Task.detached(priority: .utility) { UIImage(data: data) }.value
                            await MainActor.run { cachedArtwork = decoded }
                        } else {
                            await MainActor.run { cachedArtwork = nil }
                        }
                    }

                    Text(song.displayTitle)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal)

                    Text(song.displayArtist)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            // Seek Bar and Time Labels
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

            // Playback Buttons (no animations)
            HStack(spacing: 80) {
                Button(action: { playbackVM.skipBackward() }) {
                    Image(systemName: "backward.fill").font(.title2)
                }
                Button(action: {
                    playbackVM.togglePlayPause()
                }) {
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

            // EQ Status Label (Tappable)
            Button(action: { activeSheet = .eq }) {
                Text("EQ: \(EQManager.shared.activePresetName.uppercased())")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.top, -8)
            }

            // Shuffle / Repeat / EQ Controls (no animations)
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

            Spacer(minLength: 40)
        }
        .padding()
        .background(Color(.systemBackground)) // opaque & cheap
        .ignoresSafeArea(.keyboard)
        .confirmationDialog("More Actions", isPresented: $showMoreActions, titleVisibility: .visible) {
            if let current = playbackVM.currentSong {
                Button("Add to Playlist", systemImage: "text.badge.plus") {
                    activeSheet = .addToPlaylist(current)
                }
            }
            Button("Cancel", role: .cancel) { showMoreActions = false }
        }
        // Present EQ as a full-screen cover: completely hides PlayerView while typing
        .fullScreenCover(item: eqSheetBinding) { _ in
            EQSettingsView()
                .ignoresSafeArea(.keyboard)
                .background(Color(.systemBackground).ignoresSafeArea())
        }
        // Present Add To Playlist as a full-screen cover as well
        .fullScreenCover(item: addToPlaylistSheetBinding) { sheet in
            if case .addToPlaylist(let song) = sheet {
                AddToPlaylistSheet(song: song, selectedPlaylist: .constant(nil))
                    .environmentObject(playlistVM)
                    .environmentObject(playbackVM)
                    .ignoresSafeArea(.keyboard)
            }
        }
    }
}
