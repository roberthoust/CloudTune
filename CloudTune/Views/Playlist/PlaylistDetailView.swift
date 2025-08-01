import SwiftUI

struct PlaylistDetailView: View {
    let playlist: Playlist

    @EnvironmentObject var libraryVM: LibraryViewModel
    @EnvironmentObject var playbackVM: PlaybackViewModel
    @EnvironmentObject var playlistVM: PlaylistViewModel
    
    @State private var showEditSheet = false
    @State private var matchedSongs: [Song] = []

    // Removed the computed property to avoid repeated computation

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // MARK: - Header with Cover Art and Info
                VStack(alignment: .leading, spacing: 16) {
                    if let filename = playlist.coverArtFilename,
                       let image = loadCoverImage(filename: filename) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 240)
                            .clipped()
                            .cornerRadius(20)
                            .shadow(radius: 6)
                            .padding(.horizontal)
                    } else {
                        Image("DefaultCover")
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 240)
                            .clipped()
                            .cornerRadius(20)
                            .shadow(radius: 6)
                            .padding(.horizontal)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(playlist.name)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                            .padding(.horizontal)

                        Text("\(matchedSongs.count) song\(matchedSongs.count == 1 ? "" : "s")")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.horizontal)

                        Button(action: {
                            guard let firstSong = matchedSongs.first else { return }
                            playbackVM.play(song: firstSong, in: matchedSongs, contextName: playlist.name)
                            playbackVM.showPlayer = true
                        }) {
                            Label("Play", systemImage: "play.fill")
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(Color("appAccent"))
                                .cornerRadius(20)
                        }
                        .padding(.horizontal)
                    }
                    .padding(.top, 8)
                }

                // MARK: - Song List
                LazyVStack(spacing: 22) {
                    ForEach(matchedSongs) { song in
                        SongRowView(
                            song: song,
                            isPlaying: playbackVM.currentSong?.id == song.id,
                            onTap: {
                                if playbackVM.currentSong?.id == song.id {
                                    playbackVM.showPlayer = true
                                } else {
                                    playbackVM.play(song: song, in: matchedSongs, contextName: playlist.name)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        playbackVM.showPlayer = true
                                    }
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 100)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear(perform: loadPlaylistSongs)
        .onChange(of: libraryVM.songs) { _ in
            loadPlaylistSongs()
        }
        .onChange(of: playlist.songIDs) { _ in
            loadPlaylistSongs()
        }
        .background(Color(.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    showEditSheet = true
                }) {
                    Image(systemName: "pencil")
                }
            }
        }
        .sheet(isPresented: $showEditSheet) {
            PlaylistEditView(playlist: playlist)
                .environmentObject(playlistVM)
                .environmentObject(libraryVM)
        }
    }

    private func loadCoverImage(filename: String) -> UIImage? {
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent(filename)
        return UIImage(contentsOfFile: path.path)
    }
    
    private func loadPlaylistSongs() {
        var matched: [Song] = []
        for id in playlist.songIDs {
            if let found = libraryVM.songs.first(where: { $0.id == id }) {
                matched.append(found)
            } else {
                print("⚠️ Playlist '\(playlist.name)' missing song with ID: \(id)")
            }
        }
        print("🎧 Playlist '\(playlist.name)' loaded \(matched.count) of \(playlist.songIDs.count) songs.")
        matchedSongs = matched
    }
}
