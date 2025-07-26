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
                    LazyVStack(spacing: 22) {
                        ForEach(sortedSongs) { song in
                            SongRow(song: song)
                                .environmentObject(playbackVM)
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

// MARK: - SongRow (Updated)
struct SongRow: View {
    let song: Song
    @EnvironmentObject var playbackVM: PlaybackViewModel

    var isPlaying: Bool {
        playbackVM.currentSong?.id == song.id
    }

    var body: some View {
        HStack(spacing: 12) {
            if let data = song.artwork, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 70, height: 70)
                    .cornerRadius(10)
                    .clipped()
            } else {
                Image("DefaultCover")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 70, height: 70)
                    .cornerRadius(10)
                    .clipped()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(song.displayTitle)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                Text(song.displayArtist)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isPlaying {
                Image(systemName: "waveform.circle.fill")
                    .foregroundColor(.appAccent)
                    .imageScale(.large)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
        )
        .padding(.horizontal)
    }
}
