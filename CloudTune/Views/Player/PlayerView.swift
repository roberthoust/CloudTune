import SwiftUI

struct PlayerView: View {
    @EnvironmentObject var playbackVM: PlaybackViewModel
    @EnvironmentObject var playlistVM: PlaylistViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showMoreActions = false
    @State private var activeSheet: ActiveSheet?

    enum ActiveSheet: Identifiable {
        case eq
        case addToPlaylist(Song)

        var id: Int {
            switch self {
            case .eq:
                return 0
            case .addToPlaylist(let song):
                return song.id.hashValue
            }
        }
    }
    
    // Bindings to split presentation styles: sheet for EQ, full-screen for AddToPlaylist
    private var eqSheetBinding: Binding<ActiveSheet?> {
        Binding(
            get: {
                if case .eq = activeSheet { return activeSheet } else { return nil }
            },
            set: { newValue in
                if newValue == nil { activeSheet = nil }
            }
        )
    }
    
    private var addToPlaylistSheetBinding: Binding<ActiveSheet?> {
        Binding(
            get: {
                if case .addToPlaylist = activeSheet { return activeSheet } else { return nil }
            },
            set: { newValue in
                if newValue == nil { activeSheet = nil }
            }
        )
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }


    var body: some View {
        VStack(spacing: 24) {
            // Top Bar
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.down")
                        .font(.title2)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
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
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            .padding(.horizontal)

            // Artwork and Track Info
            if let song = playbackVM.currentSong {
                VStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color("appAccent"), lineWidth: 2)
                            .background(RoundedRectangle(cornerRadius: 24).fill(Color(.secondarySystemBackground)))
                            .shadow(color: Color("appAccent").opacity(0.3), radius: 8, x: 0, y: 4)
                            .frame(width: 260, height: 260)

                        if let data = song.artwork, let img = UIImage(data: data) {
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
                    onSeek: { newTime in playbackVM.seek(to: newTime) }
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

            // Playback Buttons
            HStack(spacing: 80) {
                Button(action: {
                    playbackVM.skipBackward()
                }) {
                    Image(systemName: "backward.fill")
                        .font(.title2)
                }

                Button(action: {
                    playbackVM.togglePlayPause()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }) {
                    Image(systemName: playbackVM.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 70, height: 70)
                        .scaleEffect(playbackVM.isPlaying ? 1.0 : 0.95)
                        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: playbackVM.isPlaying)
                }

                Button(action: {
                    playbackVM.skipForward()
                }) {
                    Image(systemName: "forward.fill")
                        .font(.title2)
                }
            }
            .padding(.vertical, 8)

            // EQ Status Label (Tappable)
            Button(action: {
                activeSheet = .eq
            }) {
                Text("EQ: \(EQManager.shared.activePresetName.uppercased())")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.top, -8)
            }

            // Shuffle / Repeat / EQ Controls
            HStack(spacing: 40) {
                Button(action: {
                    playbackVM.toggleShuffle()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }) {
                    Image(systemName: playbackVM.isShuffle ? "shuffle.circle.fill" : "shuffle.circle")
                        .font(.title3)
                        .foregroundStyle(playbackVM.isShuffle ? Color("appAccent") : Color.gray.opacity(0.5))

                        .scaleEffect(playbackVM.isShuffle ? 1.1 : 1.0)
                        .animation(.easeInOut(duration: 0.2), value: playbackVM.isShuffle)
                }

                Button(action: {
                    playbackVM.toggleRepeatMode()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }) {
                    Image(systemName:
                        playbackVM.repeatMode == .repeatAll ? "repeat.circle.fill" :
                        playbackVM.repeatMode == .repeatOne ? "repeat.1.circle.fill" :
                        "repeat.circle"
                    )
                    .font(.title3)
                    .foregroundStyle(playbackVM.repeatMode == .off ? Color.gray.opacity(0.5) : Color("appAccent"))
                    .scaleEffect(playbackVM.repeatMode != .off ? 1.1 : 1.0)
                    .animation(.easeInOut(duration: 0.2), value: playbackVM.repeatMode)
                }

                Button(action: { activeSheet = .eq }) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.title3)
                }
            }
            .padding(.top, 4)

            Spacer(minLength: 40)
        }
        .padding()
        .background(.ultraThinMaterial)
        .edgesIgnoringSafeArea(.bottom)
        .ignoresSafeArea(.keyboard)
        
        .confirmationDialog("More Actions", isPresented: $showMoreActions, titleVisibility: .visible) {
            if let current = playbackVM.currentSong {
                Button("Add to Playlist", systemImage: "text.badge.plus") {
                    activeSheet = .addToPlaylist(current)
                }

            }

            Button("Cancel", role: .cancel) {
                showMoreActions = false
            }
        }
        // Keep EQ as a regular sheet (no background movement expected)
        .sheet(item: eqSheetBinding) { _ in
            EQSettingsView()
                .ignoresSafeArea(.keyboard)
                .presentationDetents([.large])
                .presentationBackgroundInteraction(.disabled)
        }
        
        // Present Add To Playlist as a full-screen cover to fully decouple the background
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
