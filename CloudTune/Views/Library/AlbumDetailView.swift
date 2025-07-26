import SwiftUI

struct AlbumDetailView: View {
    let albumName: String
    let songs: [Song]

    @EnvironmentObject var playbackVM: PlaybackViewModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(songs) { song in
                    Button(action: {
                        print("🎵 Playing: \(song.title) from album: \(albumName)")
                        playbackVM.play(song: song, in: songs)

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            playbackVM.showPlayer = true
                        }
                    }) {
                        HStack(spacing: 12) {
                            if let data = song.artwork, let uiImage = UIImage(data: data) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 80, height: 80)
                                    .cornerRadius(8)
                                    .clipped()
                            } else {
                                Image("DefaultCover")
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 80, height: 80)
                                    .cornerRadius(8)
                                    .clipped()
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(song.displayTitle)
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                    .lineLimit(2)
                                Text(song.displayArtist)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            if playbackVM.currentSong?.id == song.id {
                                Image(systemName: "waveform.circle.fill")
                                    .foregroundColor(.appAccent)
                                    .imageScale(.large)
                            }
                        }
                        .padding()
                        .background(Color(.systemBackground).opacity(0.8))
                        .cornerRadius(14)
                        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
                    }
                    .padding(.horizontal)
                }
            }
        }
        .navigationTitle(albumName)
    }
}
