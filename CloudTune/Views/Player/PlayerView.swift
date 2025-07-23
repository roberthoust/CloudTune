import SwiftUI

struct PlayerView: View {
    @EnvironmentObject var playbackVM: PlaybackViewModel
    @EnvironmentObject var playlistVM: PlaylistViewModel
    @Environment(\.dismiss) private var dismiss

    @GestureState private var dragOffset = CGSize.zero
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
        VStack(spacing: 20) {
            // Top Bar
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.down")
                        .font(.title3.bold())
                        .foregroundColor(.primary)
                        .padding(8)
                        .background(Color(.systemGray5))
                        .clipShape(Circle())
                }

                Spacer()

                Button(action: { showMoreActions = true }) {
                    Image(systemName: "ellipsis")
                        .font(.title3.bold())
                        .foregroundColor(.primary)
                        .padding(8)
                        .background(Color(.systemGray5))
                        .clipShape(Circle())
                }
                Spacer()

                Button(action: {
                    showEQSheet = true
                }) {
                    Image(systemName: "slider.horizontal.3")
                        .imageScale(.large)
                }
                .sheet(isPresented: $showEQSheet) {
                    EQSettingsView()
                }
            }
            .padding(.horizontal)

            // Album Art Swipable
            if !playbackVM.songQueue.isEmpty {
                TabView(selection: $selectedIndex) {
                    ForEach(playbackVM.songQueue.indices, id: \.self) { index in
                        let song = playbackVM.songQueue[index]

                        VStack(spacing: 4) {
                            if let data = song.artwork, let img = UIImage(data: data) {
                                Image(uiImage: img)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 300, height: 300)
                                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                                    .shadow(radius: 12)
                            } else {
                                Image("DefaultCover")
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 300, height: 300)
                                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                                    .shadow(radius: 12)
                            }

                            Text(song.displayTitle)
                                .font(.title2.bold())
                                .multilineTextAlignment(.center)
                                .lineLimit(2)

                            Text(song.displayArtist)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.top, 8)
                        .padding(.horizontal)
                        .tag(index)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                .frame(height: 360)
                .onChange(of: selectedIndex) { newIndex in
                    if newIndex != playbackVM.currentIndex {
                        let newSong = playbackVM.songQueue[newIndex]
                        playbackVM.play(song: newSong, in: playbackVM.originalQueue)
                    }
                }
                .onAppear {
                    selectedIndex = playbackVM.currentIndex
                }
                .onReceive(playbackVM.$currentIndex) { newIndex in
                    selectedIndex = newIndex
                }
            }

            // Shuffle / Repeat Controls
            HStack(spacing: 28) {
                Button(action: { playbackVM.toggleShuffle() }) {
                    Image(systemName: playbackVM.isShuffle ? "shuffle.circle.fill" : "shuffle.circle")
                        .font(.title2)
                        .foregroundColor(playbackVM.isShuffle ? .blue : .gray)
                }

                Button(action: { playbackVM.toggleRepeatMode() }) {
                    Image(systemName:
                        playbackVM.repeatMode == .repeatAll ? "repeat.circle.fill" :
                        playbackVM.repeatMode == .repeatOne ? "repeat.1.circle.fill" :
                        "repeat.circle"
                    )
                    .font(.title2)
                    .foregroundColor(playbackVM.repeatMode == .off ? .gray : .blue)
                }
            }
            .padding(.top, 12)

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
                .font(.caption)
                .foregroundColor(.gray)
                .padding(.horizontal, 12)
            }

            // Playback Controls
            HStack(spacing: 50) {
                Button(action: {
                    playbackVM.skipBackward()
                    selectedIndex = playbackVM.currentIndex
                }) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 28))
                }

                Button(action: {
                    playbackVM.togglePlayPause()
                }) {
                    Image(systemName: playbackVM.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 70, height: 70)
                        .foregroundColor(.blue)
                        .shadow(radius: 6)
                }

                Button(action: {
                    playbackVM.skipForward()
                    selectedIndex = playbackVM.currentIndex
                }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 28))
                }
            }
            .padding(.top, 10)

            Spacer()

            // Stop & Close
            Button(action: {
                playbackVM.stop()
                dismiss()
            }) {
                Text("Stop & Close")
                    .fontWeight(.semibold)
                    .foregroundColor(.red)
            }
            .padding(.bottom, 16)
        }
        .padding()
        .background(Color(.systemBackground).ignoresSafeArea())
        .offset(y: dragOffset.height)
        .gesture(
            DragGesture().updating($dragOffset) { value, state, _ in
                if value.translation.height > 50 {
                    dismiss()
                }
            }
        )
        // Compact More Actions Menu
        .confirmationDialog("More Actions", isPresented: $showMoreActions, titleVisibility: .visible) {
            if let current = playbackVM.currentSong {
                Button("Add to Playlist", systemImage: "text.badge.plus") {
                    showAddToPlaylistSheet = true
                }

                Button("Edit Song Info", systemImage: "pencil") {
                    showEditMetadataSheet = true
                }
            }

            Button("Cancel", role: .cancel) {}
        }
        // Sheet for selecting playlist
        .sheet(isPresented: $showAddToPlaylistSheet) {
            if let current = playbackVM.currentSong {
                AddToPlaylistSheet(song: current)
                    .environmentObject(playlistVM)
            }
        }
        // Sheet for editing metadata
        .sheet(isPresented: $showEditMetadataSheet) {
            if let current = playbackVM.currentSong {
                EditMetadataView(song: current)
            }
        }
    }
}
