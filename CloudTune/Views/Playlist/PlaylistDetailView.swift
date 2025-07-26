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
                ZStack(alignment: .bottomLeading) {
                    if let filename = playlist.coverArtFilename,
                       let image = loadCoverImage(filename: filename) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 300)
                            .clipped()
                            .overlay(
                                LinearGradient(
                                    gradient: Gradient(colors: [Color.black.opacity(0.6), Color.clear]),
                                    startPoint: .bottom,
                                    endPoint: .top
                                )
                            )
                    } else {
                        Image("DefaultCover")
                            .resizable()
                            .scaledToFill()
                            .frame(height: 300)
                            .clipped()
                            .overlay(
                                LinearGradient(
                                    gradient: Gradient(colors: [Color.black.opacity(0.6), Color.clear]),
                                    startPoint: .bottom,
                                    endPoint: .top
                                )
                            )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(playlist.name)
                            .font(.largeTitle.bold())
                            .foregroundColor(.white)

                        Text("\(matchedSongs.count) song\(matchedSongs.count == 1 ? "" : "s")")
                            .foregroundColor(.white.opacity(0.8))
                            .font(.subheadline)

                        Button(action: {
                            guard let firstSong = matchedSongs.first else { return }
                            playbackVM.play(song: firstSong, in: matchedSongs, contextName: playlist.name)
                            playbackVM.showPlayer = true
                        }) {
                            Label("Play", systemImage: "play.fill")
                                .font(.headline)
                                .foregroundColor(Color(UIColor { $0.userInterfaceStyle == .dark ? .black : .white }))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(Color("appAccent"))
                                .cornerRadius(20)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20)
                                        .stroke(Color.white.opacity(0.4), lineWidth: 1)
                                )
                                .shadow(color: Color.black.opacity(0.4), radius: 4, x: 0, y: 2)
                        }
                    }
                    .padding()
                }

                // MARK: - Song List
                VStack(spacing: 12) {
                    ForEach(matchedSongs) { song in
                        Button(action: {
                            print("🎶 Playing: \(song.title) from playlist: \(playlist.name)")
                            playbackVM.play(song: song, in: matchedSongs, contextName: playlist.name)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                playbackVM.showPlayer = true
                            }
                        }) {
                            HStack(spacing: 12) {
                                if let data = song.artwork, let uiImage = UIImage(data: data) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 60, height: 60)
                                        .cornerRadius(10)
                                        .clipped()
                                } else {
                                    Image("DefaultCover")
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 60, height: 60)
                                        .cornerRadius(10)
                                        .clipped()
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(song.displayTitle)
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                        .lineLimit(nil)
                                    Text(song.displayArtist)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .background(.thinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(Rectangle())
                        }
                    }
                }
            }
        }
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
