import SwiftUI

struct AlbumDetailView: View {
    let albumName: String
    let songs: [Song]

    @EnvironmentObject var playbackVM: PlaybackViewModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(songs) { song in
                    HStack(spacing: 12) {
                        if let data = song.artwork, let uiImage = UIImage(data: data) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 60, height: 60)
                                .background(.ultraThinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color("appAccent"), lineWidth: 1.2)
                                )
                                .shadow(color: Color.black.opacity(0.2), radius: 5, x: 0, y: 2)
                        } else {
                            Image("DefaultCover")
                                .resizable()
                                .scaledToFill()
                                .frame(width: 60, height: 60)
                                .background(.ultraThinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color("appAccent"), lineWidth: 1.2)
                                )
                                .shadow(color: Color.black.opacity(0.2), radius: 5, x: 0, y: 2)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(song.displayTitle)
                                .font(.headline)
                            Text(song.displayArtist)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle()) // Makes whole row tappable
                    .onTapGesture {
                        print("🎵 Playing: \(song.title) from album: \(albumName)")
                        playbackVM.play(song: song, in: songs)

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            playbackVM.showPlayer = true
                        }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.top)
        }
        .navigationTitle(albumName)
    }
}
