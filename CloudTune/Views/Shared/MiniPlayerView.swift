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
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.appAccent.opacity(0.7), lineWidth: 1)
                            )
                    } else {
                        Image("DefaultCover")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.appAccent.opacity(0.7), lineWidth: 1)
                            )
                    }

                    // Song info
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title)
                            .font(.callout)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

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
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
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

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}
