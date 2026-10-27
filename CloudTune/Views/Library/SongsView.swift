import SwiftUI
import UIKit

struct SongsView: View {
    @EnvironmentObject var libraryVM: LibraryViewModel
    @EnvironmentObject var playbackVM: PlaybackViewModel

    @State private var selectedSort: SongSortOption = .recent
    @State private var isPresentingPlayer: Bool = false

    /// Songs in the selected order, from the database. nil until the first query returns.
    @State private var orderedSongs: [Song]?
    @State private var orderedSort: SongSortOption?

    /// What's shown: the database order, or (before it arrives) newest first, which is the default sort.
    private var sortedSongs: [Song] {
        orderedSongs ?? libraryVM.songs.reversed()
    }

    private struct ListQuery: Equatable {
        let sort: SongSortOption
        let version: Int
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Top Header
                HStack {
                    Text("Your Songs")
                        .font(.largeTitle.bold())
                        .padding(.horizontal)

                    Spacer()

                    Menu {
                        ForEach(SongSortOption.allCases, id: \.self) { option in
                            Button(option.rawValue) { selectedSort = option }
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
                    LazyVStack(spacing: 16) {
                        ForEach(sortedSongs) { song in
                            SongRow(song: song)
                                .environmentObject(libraryVM)
                                .environmentObject(playbackVM)
                                .onTapGesture {
                                    if playbackVM.currentSong?.id == song.id {
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

                Spacer(minLength: 0)
            }
            .padding(.top)
            .fullScreenCover(isPresented: $isPresentingPlayer) {
                PlayerView().environmentObject(playbackVM)
            }
            // Re-query when the sort or the library changes. Lookups during an import change
            // songs many times in a row, so for those wait briefly and let newer changes cancel this one.
            .task(id: ListQuery(sort: selectedSort, version: libraryVM.songsVersion)) {
                let sort = selectedSort
                if orderedSort == sort {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    if Task.isCancelled { return }
                }
                let result = await libraryVM.songs(sortedBy: sort)
                if !Task.isCancelled {
                    orderedSongs = result
                    orderedSort = sort
                }
            }
        }
    }
}

// MARK: - SongRow (Optimized artwork loading)
struct SongRow: View {
    let song: Song
    @EnvironmentObject var libraryVM: LibraryViewModel
    @EnvironmentObject var playbackVM: PlaybackViewModel

    private let artSide: CGFloat = 60

    var isPlaying: Bool { playbackVM.currentSong?.id == song.id }

    private var metadata: SongMetadata {
        if let meta = libraryVM.songMetadataCache[song.id] {
            return meta
        } else {
            return SongMetadata(
                title: song.title,
                artist: song.artist,
                album: song.album,
                genre: song.genre,
                year: song.year,
                trackNumber: song.trackNumber,
                discNumber: song.discNumber
            )
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            SongArtThumb(song: song, side: artSide)
                .frame(width: artSide, height: artSide)
                .cornerRadius(8)
                .clipped()

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
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color("appAccent").opacity(0.2), lineWidth: 1))
                .shadow(color: Color("appAccent").opacity(0.25), radius: 4, x: 0, y: 2)
        )
    }
}

/// Tiny async artwork loader that uses LibraryViewModel's thumbnail cache to avoid UI hitches.
private struct SongArtThumb: View {
    let song: Song
    let side: CGFloat
    var body: some View {
        ArtworkThumbView(artworkID: song.artworkID)
            .cornerRadius(8)
            .clipped()
    }
}
