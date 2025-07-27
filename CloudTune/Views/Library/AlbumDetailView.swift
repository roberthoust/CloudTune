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
                        if playbackVM.currentSong?.id == song.id {
                            playbackVM.showPlayer = true
                        } else {
                            print("🎵 Playing: \(song.title) from album: \(albumName)")
                            playbackVM.play(song: song, in: songs)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                playbackVM.showPlayer = true
                            }
                        }
                    }) {
                        HStack(spacing: 8) {
                            if let data = song.artwork, let uiImage = UIImage(data: data) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 60, height: 60)
                                    .cornerRadius(8)
                                    .clipped()
                            } else {
                                Image("DefaultCover")
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 60, height: 60)
                                    .cornerRadius(8)
                                    .clipped()
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.displayTitle)
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                    .lineLimit(2)
                                Text(song.displayArtist)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            if playbackVM.currentSong?.id == song.id {
                                Image(systemName: "waveform.circle.fill")
                                    .foregroundColor(.appAccent)
                                    .imageScale(.medium)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .cornerRadius(14)
                        .shadow(color: Color.black.opacity(0.05), radius: 1, x: 0, y: 1)
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.top)
        }
        .navigationTitle(albumName)
    }
}
