import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject var playbackVM: PlaybackViewModel

    var body: some View {
        if let song = playbackVM.currentSong {
            Button(action: {
                playbackVM.showPlayer = true
            }) {
                HStack(spacing: 12) {
                    // Artwork thumbnail
                    if let data = song.artwork, let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                        Image("DefaultCover")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    // Song info
                    VStack(alignment: .leading, spacing: 3) {
                        Text(song.title)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text(song.artist)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer()

                    // Controls
                    HStack(spacing: 20) {
                        Button(action: {
                            playbackVM.togglePlayPause()
                        }) {
                            Image(systemName: playbackVM.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title3)
                                .padding(6)
                        }

                        Button(action: {
                            playbackVM.skipForward()
                        }) {
                            Image(systemName: "forward.fill")
                                .font(.title3)
                                .padding(6)
                        }
                    }
                    .foregroundColor(.primary)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(.ultraThinMaterial)
                .cornerRadius(16)
                .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .transition(.move(edge: .bottom))
        }
    }
}
