import SwiftUI


struct SongsView: View {
    @EnvironmentObject var libraryVM: LibraryViewModel
    @EnvironmentObject var playbackVM: PlaybackViewModel

    @State private var selectedSort: SongSortOption = .recent
    @State private var isPresentingPlayer: Bool = false

    var body: some View {
        let sortedSongs: [Song] = {
            switch selectedSort {
            case .recent:
                return libraryVM.songs.reversed()
            case .title:
                return libraryVM.songs.sorted {
                    let m1 = (libraryVM as LibraryViewModel).songMetadataCache[$0.id]
                    let m2 = (libraryVM as LibraryViewModel).songMetadataCache[$1.id]
                    return (m1?.title ?? $0.title) < (m2?.title ?? $1.title)
                }
            case .artist:
                return libraryVM.songs.sorted {
                    let m1 = (libraryVM as LibraryViewModel).songMetadataCache[$0.id]
                    let m2 = (libraryVM as LibraryViewModel).songMetadataCache[$1.id]
                    return (m1?.artist ?? $0.artist) < (m2?.artist ?? $1.artist)
                }
            default:
                return libraryVM.songs
            }
        }()
        return NavigationStack {
            VStack(spacing: 16) {
                // Top Header
                HStack {
                    Text("Your Songs")
                        .font(.largeTitle.bold())
                        .padding(.horizontal)

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
                            .padding(8)
                            .background(Color.appAccent.opacity(0.2))
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.appAccent, lineWidth: 1.5))
                            .shadow(color: Color.appAccent.opacity(0.3), radius: 4, x: 0, y: 2)
                    }
                }
                .padding(.horizontal)

                // Song List
                ScrollView {
                    LazyVStack(spacing: 22) {
                        ForEach(sortedSongs) { song in
                            SongRow(song: song, libraryVM: libraryVM)
                                .environmentObject(playbackVM)
                                .onTapGesture {
                                    if playbackVM.currentSong?.id == song.id {
                                        // Already playing this song, just present player
                                        isPresentingPlayer = true
                                    } else {
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
    @ObservedObject var libraryVM: LibraryViewModel
    @EnvironmentObject var playbackVM: PlaybackViewModel

    var isPlaying: Bool {
        playbackVM.currentSong?.id == song.id
    }
    
    var metadata: SongMetadata {
        if let meta = libraryVM.songMetadataCache[song.id] {
            return meta
        } else {
            return SongMetadata(title: song.title, artist: song.artist, album: song.album,
                                genre: song.genre, year: song.year,
                                trackNumber: song.trackNumber, discNumber: song.discNumber)
        }
    }
    var body: some View {
        HStack(spacing: 12) {
            if let data = song.artwork, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 60, height: 60)
                    .cornerRadius(8)
                    .clipped()
            } else {
                Image("DefaultCover")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 60, height: 60)
                    .cornerRadius(8)
                    .clipped()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(metadata.title)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                Text(metadata.artist ?? "Unknown Artist")
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
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemGray5))
                .shadow(color: Color.black.opacity(0.04), radius: 2, x: 0, y: 1)
        )
    }
}
