import SwiftUI
import UIKit

struct SongsView: View {
    @EnvironmentObject var libraryVM: LibraryViewModel
    @EnvironmentObject var playbackVM: PlaybackViewModel

    @State private var selectedSort: SongSortOption = .recent
    @State private var isPresentingPlayer: Bool = false

    // Use one consistent, memoized view of the list for this render pass to
    // avoid re-sorting in multiple places (index mismatches/glitches).
    private var sortedSongs: [Song] {
        sorted(libraryVM.songs)
    }

    // Strip leading punctuation/underscores/spaces (but keep letters/numbers)
    // strips leading punctuation, track numbers (only when followed by -, _, or .), and common articles like "The").
    private func normalizedSortKey(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip leading punctuation/underscores/spaces
        t = t.replacingOccurrences(of: "^[\\s\\W_]+", with: "", options: .regularExpression)
        // Strip leading track numbers like "01 - ", "1.", "07_" (only when followed by -, _, or .)
        t = t.replacingOccurrences(of: "^(?:[0-9]{1,3})(?:[._-]+\\s*)", with: "", options: .regularExpression)
        // Strip leading articles (The, A, An)
        t = t.replacingOccurrences(of: "(?i)^(?:the|a|an)\\s+", with: "", options: .regularExpression)
        // Fold case/diacritics for locale-aware compare later
        return t.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func titleSortKey(for song: Song) -> String {
        let metaTitle = libraryVM.songMetadataCache[song.id]?.title ?? song.title
        return normalizedSortKey(metaTitle)
    }

    private func artistSortKey(for song: Song) -> String {
        let metaArtist = libraryVM.songMetadataCache[song.id]?.artist ?? song.artist
        return normalizedSortKey(metaArtist)
    }

    // Computed-on-access; relies only on value types and cached metadata lookups
    private func sorted(_ songs: [Song]) -> [Song] {
        switch selectedSort {
        case .recent:
            return songs.reversed()
            case .title:
                return songs.sorted { (lhs: Song, rhs: Song) in
                    let l = titleSortKey(for: lhs)
                    let r = titleSortKey(for: rhs)
                    let primary = l.localizedStandardCompare(r)
                    if primary != .orderedSame { return primary == .orderedAscending }
                    // Stable tiebreaker by artist, then by original title
                    let la = artistSortKey(for: lhs)
                    let ra = artistSortKey(for: rhs)
                    let secondary = la.localizedStandardCompare(ra)
                    if secondary != .orderedSame { return secondary == .orderedAscending }
                    
                    let lt = libraryVM.songMetadataCache[lhs.id]?.title ?? lhs.title
                    let rt = libraryVM.songMetadataCache[rhs.id]?.title ?? rhs.title
                    let final = lt.localizedStandardCompare(rt)
                    if final != .orderedSame { return final == .orderedAscending }
                    return String(describing: lhs.id) < String(describing: rhs.id)
                }
        case .artist:
            return songs.sorted { (lhs: Song, rhs: Song) in
                let l = artistSortKey(for: lhs)
                let r = artistSortKey(for: rhs)
                let primary = l.localizedStandardCompare(r)
                if primary != .orderedSame { return primary == .orderedAscending }
                // Tiebreak by title
                let lt = titleSortKey(for: lhs)
                let rt = titleSortKey(for: rhs)
                let final = lt.localizedStandardCompare(rt)
                if final != .orderedSame { return final == .orderedAscending }
                return String(describing: lhs.id) < String(describing: rhs.id)
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
        .cornerRadius(8)
        .clipped()
    }
}
