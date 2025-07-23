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
            VStack {
                // Top Header
                HStack {
                    Text("Songs")
                        .font(.largeTitle)
                        .bold()

                    Spacer()

                    // Sort Menu
                    Menu {
                        ForEach(SongSortOption.allCases, id: \.self) { option in
                            Button(option.rawValue) {
                                selectedSort = option
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .padding(8)
                            .background(Color(.systemGray6))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal)

                // Song List
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(sortedSongs) { song in
                            SongRow(song: song)
                                .onTapGesture {
                                    print("🎵 Playing: \(song.title) by \(song.artist)")
                                    playbackVM.play(song: song, in: sortedSongs)

                                    // Delay to ensure state is set before presenting
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        isPresentingPlayer = true
                                    }
                                }
                        }
                    }
                    .padding(.bottom, 100)
                }

                Spacer()
            }
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
        HStack(spacing: 12) {
            if let data = song.artwork, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 60, height: 60)
                    .cornerRadius(8)
            } else {
                Image("DefaultCover")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 60, height: 60)
                    .cornerRadius(8)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(song.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(song.displayArtist)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal)
    }
}
