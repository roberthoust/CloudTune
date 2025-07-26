import SwiftUI

struct PlayerView: View {
    @EnvironmentObject var playbackVM: PlaybackViewModel
    @EnvironmentObject var playlistVM: PlaylistViewModel
    @Environment(\.dismiss) private var dismiss

    @GestureState private var dragOffset = CGSize.zero
    @State private var artworkOffset: CGFloat = 0
    @State private var selectedIndex: Int = 0
    @State private var showMoreActions = false
    @State private var showAddToPlaylistSheet = false
    @State private var showEditMetadataSheet = false
    @State private var showEQSheet = false

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

            // Artwork
            if playbackVM.currentSong != nil {
                VStack(spacing: 10) {
                    GeometryReader { geometry in
                        let drag = DragGesture()
                            .onChanged { value in
                                // Optionally handle drag updates if needed
                            }
                        withAnimation(.interactiveSpring(response: 0.4, dampingFraction: 0.75, blendDuration: 0.25)) {
                            TabView(selection: $playbackVM.currentIndex) {
                                ForEach(playbackVM.songQueue.indices, id: \.self) { index in
                                    let song = playbackVM.songQueue[index]
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 24)
                                            .fill(.ultraThinMaterial)
                                            .frame(width: geometry.size.width * 0.8, height: geometry.size.width * 0.8)
                                            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color("appAccent"), lineWidth: 1.5))
                                            .shadow(radius: 10)

                                        if let data = song.artwork, let img = UIImage(data: data) {
                                            Image(uiImage: img)
                                                .resizable()
                                                .scaledToFill()
                                                .frame(width: geometry.size.width * 0.75, height: geometry.size.width * 0.75)
                                                .clipShape(RoundedRectangle(cornerRadius: 20))
                                        } else {
                                            Image("DefaultCover")
                                                .resizable()
                                                .scaledToFill()
                                                .frame(width: geometry.size.width * 0.75, height: geometry.size.width * 0.75)
                                                .clipShape(RoundedRectangle(cornerRadius: 20))
                                        }
                                    }
                                    .tag(index)
                                    .onTapGesture {
                                        if index != playbackVM.currentIndex {
                                            playbackVM.play(song: song, in: playbackVM.originalQueue, contextName: playbackVM.currentContextName)
                                            playbackVM.currentIndex = index
                                        }
                                    }
                                }
                            }
                            .tabViewStyle(.page(indexDisplayMode: .never))
                            .onChange(of: playbackVM.currentIndex) { newIndex in
                                let newSong = playbackVM.songQueue[newIndex]
                                if playbackVM.currentSong?.url != newSong.url {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        playbackVM.play(song: newSong, in: playbackVM.originalQueue, contextName: playbackVM.currentContextName)
                                    }
                                }
                            }
                            .frame(height: geometry.size.width * 0.9)
                            .animation(.interactiveSpring(response: 0.4, dampingFraction: 0.75, blendDuration: 0.25), value: playbackVM.currentIndex)
                        }
                    }
                    .frame(height: 340)

                    if let song = playbackVM.currentSong {
                        Text(song.displayTitle)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                            .lineLimit(2)

                        Text(song.displayArtist)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Seek Bar
            VStack(spacing: 6) {
                SeekBarView(
                    currentTime: $playbackVM.currentTime,
                    duration: playbackVM.duration,
                    onSeek: { newTime in playbackVM.seek(to: newTime) }
                )
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

            // Playback Buttons
            HStack(spacing: 50) {
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
            .padding(.top)

            // Shuffle / Repeat / EQ
            HStack(spacing: 28) {
                Button(action: { playbackVM.toggleShuffle() }) {
                    Image(systemName: playbackVM.isShuffle ? "shuffle.circle.fill" : "shuffle.circle")
                        .font(.title3)
                        .foregroundColor(playbackVM.isShuffle ? Color("appAccent") : .gray)
                }

                Button(action: { playbackVM.toggleRepeatMode() }) {
                    Image(systemName:
                        playbackVM.repeatMode == .repeatAll ? "repeat.circle.fill" :
                        playbackVM.repeatMode == .repeatOne ? "repeat.1.circle.fill" :
                        "repeat.circle"
                    )
                    .font(.title3)
                    .foregroundColor(playbackVM.repeatMode == .off ? .gray : Color("appAccent"))
                }

                Button(action: { showEQSheet = true }) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.title3)
                }
                .sheet(isPresented: $showEQSheet) {
                    EQSettingsView()
                }
            }

            Spacer(minLength: 40)
        }
        .padding()
        .background(.ultraThinMaterial)
        .edgesIgnoringSafeArea(.bottom)
        .confirmationDialog("More Actions", isPresented: $showMoreActions, titleVisibility: .visible) {
            if let current = playbackVM.currentSong {
                Button("Add to Playlist", systemImage: "text.badge.plus") {
                    showAddToPlaylistSheet = true
                }

                Button("Edit Song Info", systemImage: "pencil") {
                    showEditMetadataSheet = true
                }
            }

            Button("Cancel", role: .cancel) {
                showMoreActions = false
            }
        }
        .sheet(isPresented: $showAddToPlaylistSheet) {
            if let current = playbackVM.currentSong {
                AddToPlaylistSheet(song: current)
                    .environmentObject(playlistVM)
            }
        }
        .sheet(isPresented: $showEditMetadataSheet) {
            if let current = playbackVM.currentSong {
                EditMetadataView(song: current)
            }
        }
    }
}
