import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject var playbackVM: PlaybackViewModel

    var body: some View {
        if let song = playbackVM.currentSong {
            Button(action: {
                playbackVM.showPlayer = true
            }) {
                HStack(spacing: 14) {
                    // Artwork thumbnail
                    if let data = song.artwork, let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.appAccent.opacity(0.7), lineWidth: 1)
                            )
                    } else {
                        Image("DefaultCover")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.appAccent.opacity(0.7), lineWidth: 1)
                            )
                    }

                    // Song info
                    VStack(alignment: .leading, spacing: 4) {
                        Text(song.title)
                            .font(.callout)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        Text(song.artist)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    // Controls
                    HStack(spacing: 20) {
                        Button(action: {
                            playbackVM.togglePlayPause()
                        }) {
                            Image(systemName: playbackVM.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                        }

                        Button(action: {
                            playbackVM.skipForward()
                        }) {
                            Image(systemName: "forward.fill")
                                .font(.title2)
                        }
                    }
                    .foregroundColor(.appAccent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .background(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(Color.appAccent.opacity(0.5), lineWidth: 0.75)
                        )
                )
                .shadow(color: .black.opacity(0.05), radius: 6, x: 0, y: 2)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .transition(.move(edge: .bottom))
        }
    }
}
