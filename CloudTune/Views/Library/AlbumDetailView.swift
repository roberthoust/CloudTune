import SwiftUI

struct AlbumDetailView: View {
    let albumName: String
    let songs: [Song]

    @EnvironmentObject var playbackVM: PlaybackViewModel

    var body: some View {
        List(songs) { song in
            HStack {
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

                VStack(alignment: .leading) {
                    Text(song.displayTitle)
                    Text(song.displayArtist)
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }

                Spacer()
            }
            .contentShape(Rectangle()) // Makes whole row tappable
            .onTapGesture {
                print("🎵 Playing: \(song.title) from album: \(albumName)")
                playbackVM.play(song: song, in: songs)

                // Delay showPlayer to avoid premature dismissal
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    playbackVM.showPlayer = true
                }
            }
        }
        .navigationTitle(albumName)
    }
}
