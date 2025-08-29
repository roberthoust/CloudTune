import SwiftUI
import UIKit

struct SongsView: View {
    @EnvironmentObject var libraryVM: LibraryViewModel
    @EnvironmentObject var playbackVM: PlaybackViewModel

    @State private var selectedSort: SongSortOption = .recent
    @State private var isPresentingPlayer: Bool = false

    // Computed-on-access; relies only on value types and cached metadata lookups
    private func sorted(_ songs: [Song]) -> [Song] {
        switch selectedSort {
        case .recent:
            return songs.reversed()
        case .title:
            return songs.sorted { lhs, rhs in
                let m1 = libraryVM.songMetadataCache[lhs.id]
                let m2 = libraryVM.songMetadataCache[rhs.id]
                return (m1?.title ?? lhs.title) < (m2?.title ?? rhs.title)
            }
        case .artist:
            return songs.sorted { lhs, rhs in
                let m1 = libraryVM.songMetadataCache[lhs.id]
                let m2 = libraryVM.songMetadataCache[rhs.id]
                return (m1?.artist ?? lhs.artist) < (m2?.artist ?? rhs.artist)
            }
        default:
            return songs
        }
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
                        ForEach(sorted(libraryVM.songs)) { song in
                            SongRow(song: song)
                                .environmentObject(libraryVM)
                                .environmentObject(playbackVM)
                                .onTapGesture {
                                    if playbackVM.currentSong?.id == song.id {
                                        isPresentingPlayer = true
                                    } else {
                                        if let index = sorted(libraryVM.songs).firstIndex(of: song) {
                                            playbackVM.currentIndex = index
                                        }
                                        playbackVM.play(song: song, in: sorted(libraryVM.songs))
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
                .fill(Color(.systemGray5))
                .shadow(color: Color.black.opacity(0.04), radius: 2, x: 0, y: 1)
        )
    }
}

/// Tiny async artwork loader that uses LibraryViewModel's thumbnail cache to avoid UI hitches.
private struct SongArtThumb: View {
    let song: Song
    let side: CGFloat
    @EnvironmentObject var libraryVM: LibraryViewModel

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                // Lightweight placeholder while thumbnail is resolved
                Image("DefaultCover")
                    .resizable()
                    .scaledToFill()
                    .redacted(reason: .placeholder)
                    .task(id: song.id) {
                        let size = CGSize(width: side, height: side)
                        let vm: LibraryViewModel = libraryVM  // disambiguate EnvironmentObject wrapper
                        if let thumb = await vm.thumbnailFor(song: song, side: size) {
                            await MainActor.run { self.image = thumb }
                        }
                    }
            }
        }
    }
}
