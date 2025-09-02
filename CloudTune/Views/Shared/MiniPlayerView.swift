import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject var playbackVM: PlaybackViewModel

    var body: some View {
        if let song = playbackVM.currentSong {
            HStack(spacing: 14) {
                // Artwork thumbnail
                if let data = song.artwork, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 46, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Image("DefaultCover")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 46, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                // Song info
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.subheadline.weight(.semibold))
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
                HStack(spacing: 28) {
                    Button {
                        playbackVM.skipBackward()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.title3)
                    }

                    Button {
                        playbackVM.togglePlayPause()
                    } label: {
                        Image(systemName: playbackVM.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .scaleEffect(playbackVM.isPlaying ? 1.05 : 1.0)
                            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: playbackVM.isPlaying)
                    }

                    Button {
                        playbackVM.skipForward()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.title3)
                    }
                }
                .foregroundColor(.appAccent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.appAccent.opacity(0.3), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 1)
            .padding(.horizontal)
            .onTapGesture {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    playbackVM.showPlayer = true
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
