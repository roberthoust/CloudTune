import SwiftUI

struct SongsView: View {
    @EnvironmentObject var libraryVM: LibraryViewModel
    @EnvironmentObject var playbackVM: PlaybackViewModel

    @State private var selectedSort: SongSortOption = .recent
    @State private var isPresentingPlayer: Bool = false

    var sortedSongs: [Song] {
        switch selectedSort {
        case .recent:
            return libraryVM.songs.reversed()
        case .title:
            return libraryVM.songs.sorted { $0.title < $1.title }
        case .artist:
            return libraryVM.songs.sorted { $0.artist < $1.artist }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Top Header
                HStack {
                    Text("Songs")
                        .font(.largeTitle.bold())
                        .foregroundColor(.primary)

                    Spacer()

                    Menu {
                        ForEach(SongSortOption.allCases, id: \.self) { option in
                            Button(option.rawValue) {
                                selectedSort = option
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.headline)
                            .padding(10)
                            .background(.thinMaterial)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.appAccent, lineWidth: 1.5))
                            .shadow(radius: 4)
                    }
                }
                .padding(.horizontal)

                // Song List
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(sortedSongs) { song in
                            SongRow(song: song)
                                .onTapGesture {
                                    print("🎵 Playing: \(song.title) by \(song.artist)")
                                    if let index = sortedSongs.firstIndex(of: song) {
                                        playbackVM.currentIndex = index
                                    }
                                    playbackVM.play(song: song, in: sortedSongs)

                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        isPresentingPlayer = true
                                    }
                                }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 100)
                }

                Spacer()
            }
            .padding(.top)
            .fullScreenCover(isPresented: $isPresentingPlayer) {
                PlayerView()
                    .environmentObject(playbackVM)
            }
        }
    }
}

// MARK: - SongRow (Inline)
struct SongRow: View {
    let song: Song

    var body: some View {
        HStack(spacing: 14) {
            if let data = song.artwork, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 60, height: 60)
                    .cornerRadius(10)
                    .clipped()
            } else {
                Image("DefaultCover")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 60, height: 60)
                    .cornerRadius(10)
                    .clipped()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(song.displayTitle)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(song.displayArtist)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.appAccent.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 5, x: 0, y: 2)
    }
}
