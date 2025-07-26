import SwiftUI

struct PlaylistDetailView: View {
    let playlist: Playlist

    @EnvironmentObject var libraryVM: LibraryViewModel
    @EnvironmentObject var playbackVM: PlaybackViewModel
    @EnvironmentObject var playlistVM: PlaylistViewModel
    
    @State private var showEditSheet = false

    var playlistSongs: [Song] {
        let matched = playlist.songIDs.compactMap { id in
            if let found = libraryVM.songs.first(where: { $0.id == id }) {
                return found
            } else {
                print("⚠️ Playlist '\(playlist.name)' missing song with ID: \(id)")
                return nil
            }
        }
        print("🎧 Playlist '\(playlist.name)' loaded \(matched.count) of \(playlist.songIDs.count) songs.")
        return matched
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // MARK: - Stylized Cover Image
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color("AppAccent"), lineWidth: 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(.ultraThinMaterial)
                        )
                        .frame(height: 250)
                        .padding([.horizontal, .top])
                        .overlay(
                            Group {
                                if let filename = playlist.coverArtFilename,
                                   let image = loadCoverImage(filename: filename) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    Image("DefaultCover")
                                        .resizable()
                                        .scaledToFill()
                                }
                            }
                            .clipped()
                            .cornerRadius(16)
                            .padding([.horizontal, .top])
                        )

                    // MARK: - Edit Button
                    Button(action: {
                        showEditSheet = true
                    }) {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 26))
                            .foregroundColor(.white)
                            .shadow(radius: 4)
                            .padding()
                    }
                }

                // MARK: - Playlist Info
                VStack(alignment: .leading, spacing: 4) {
                    Text(playlist.name)
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(Color("AppAccent"))
                        .padding(.horizontal)

                    Text("\(playlistSongs.count) Song\(playlistSongs.count == 1 ? "" : "s")")
                        .foregroundColor(.gray)
                        .font(.subheadline)
                        .padding(.horizontal)
                }

                // MARK: - Songs List
                VStack(spacing: 0) {
                    ForEach(playlistSongs) { song in
                        Button(action: {
                            print("🎶 Playing: \(song.title) from playlist: \(playlist.name)")
                            playbackVM.play(song: song, in: playlistSongs, contextName: playlist.name)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                playbackVM.showPlayer = true
                            }
                        }) {
                            HStack(spacing: 12) {
                                if let data = song.artwork, let uiImage = UIImage(data: data) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .frame(width: 50, height: 50)
                                        .cornerRadius(8)
                                } else {
                                    Image("DefaultCover")
                                        .resizable()
                                        .frame(width: 50, height: 50)
                                        .cornerRadius(8)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(song.displayTitle)
                                        .foregroundColor(.primary)
                                    Text(song.displayArtist)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color("AppAccent").opacity(0.15))
                            )
                        }

                        Divider()
                            .padding(.leading, 70)
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
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
}
