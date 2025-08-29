import SwiftUI

struct AlbumDetailView: View {
    let albumName: String
    let songs: [Song]

    @EnvironmentObject var playbackVM: PlaybackViewModel
    @State private var selectedPlaylist: Playlist? = nil

    var sortedSongs: [Song] {
        return songs.sorted {
            let disc0 = $0.discNumber ?? 0
            let disc1 = $1.discNumber ?? 0
            if disc0 != disc1 {
                return disc0 < disc1
            } else {
                let track0 = $0.trackNumber ?? Int.max
                let track1 = $1.trackNumber ?? Int.max
                return track0 < track1
            }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(sortedSongs, id: \.url) { song in
                    SongRowButton(song: song, albumName: albumName, songs: sortedSongs)
                        .environmentObject(playbackVM)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.top)
            .animation(.spring(), value: sortedSongs)
        }
        .navigationTitle(albumName)
        .sheet(isPresented: $playbackVM.showAddToPlaylistSheet) {
            if let song = playbackVM.songToAddToPlaylist {
                AddToPlaylistSheet(song: song, selectedPlaylist: $selectedPlaylist)
                    .environmentObject(playbackVM)
            }
        }
    }
}

struct SongRowButton: View {
    let song: Song
    let albumName: String
    let songs: [Song]

    @EnvironmentObject var playbackVM: PlaybackViewModel

    var isCurrentSong: Bool {
        playbackVM.currentSong?.id == song.id
    }

    var body: some View {
        Button(action: {
            if isCurrentSong {
                playbackVM.showPlayer = true
            } else {
                playbackVM.play(song: song, in: songs, contextName: albumName)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    playbackVM.showPlayer = true
                }
            }
        }) {
            HStack(spacing: 8) {
                Group {
                    if let data = song.artwork, let uiImage = UIImage(data: data) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image("DefaultCover")
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(width: 50, height: 50)
                .cornerRadius(10)
                .clipped()

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

                if isCurrentSong {
                    Image(systemName: playbackVM.isPlaying ? "waveform" : "waveform.circle.fill")
                        .foregroundColor(.appAccent)
                        .imageScale(.medium)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial)
            .cornerRadius(10)
            .shadow(color: Color.black.opacity(0.05), radius: 0.5, x: 0, y: 1)
        }
        .padding(.horizontal)
        .transition(.move(edge: .trailing).combined(with: .opacity))
        .contextMenu {
            Button {
                DispatchQueue.main.async {
                    playbackVM.songToAddToPlaylist = song
                    playbackVM.showAddToPlaylistSheet = true
                }
            } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }
        }
    }
}
