//
//  FolderDetailView.swift
//  CloudTune
//

import SwiftUI
import UIKit

// MARK: - Sort options (reuse your app's if you already have one)
private enum FolderSongSort: String, CaseIterable, Identifiable {
    case recent = "Recent"
    case title  = "Title"
    case artist = "Artist"
    case track  = "Track #"

    var id: String { rawValue }
}

struct FolderDetailView: View {
    let folder: URL
    let songs: [Song]

    @EnvironmentObject var libraryVM: LibraryViewModel
    @EnvironmentObject var playbackVM: PlaybackViewModel

    @State private var selectedSort: FolderSongSort = .recent
    @State private var isPresentingPlayer = false

    // MARK: - Sorting using cached metadata when available
    private func sorted(_ input: [Song]) -> [Song] {
        switch selectedSort {
        case .recent:
            return input.reversed()
        case .title:
            return input.sorted { lhs, rhs in
                let m1 = libraryVM.songMetadataCache[lhs.id]
                let m2 = libraryVM.songMetadataCache[rhs.id]
                return (m1?.title ?? lhs.title)
                    .localizedCaseInsensitiveCompare(m2?.title ?? rhs.title) == .orderedAscending
            }
        case .artist:
            return input.sorted { lhs, rhs in
                let m1 = libraryVM.songMetadataCache[lhs.id]
                let m2 = libraryVM.songMetadataCache[rhs.id]
                return (m1?.artist ?? lhs.artist)
                    .localizedCaseInsensitiveCompare(m2?.artist ?? rhs.artist) == .orderedAscending
            }
        case .track:
            return input.sorted { lhs, rhs in
                let t1 = libraryVM.songMetadataCache[lhs.id]?.trackNumber ?? lhs.trackNumber
                let t2 = libraryVM.songMetadataCache[rhs.id]?.trackNumber ?? rhs.trackNumber
                if t1 == t2 {
                    // tie-break by title
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return t1 < t2
            }
        }
    }

    // First artwork in the folder (nice touch for header)
    private var headerArtworkData: Data? { songs.first?.artwork }

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack(alignment: .center, spacing: 12) {
                FolderHeaderArt(artworkData: headerArtworkData, side: 64)

                VStack(alignment: .leading, spacing: 4) {
                    Text(folder.lastPathComponent)
                        .font(.title2.bold())
                        .lineLimit(2)
                    Text("\(songs.count) item\(songs.count == 1 ? "" : "s")")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Sort menu (matches Songs screen behavior)
                Menu {
                    ForEach(FolderSongSort.allCases) { option in
                        Button(option.rawValue) { selectedSort = option }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.headline)
                        .padding(8)
                        .background(Color("appAccent").opacity(0.2), in: Circle())
                        .overlay(Circle().stroke(Color("appAccent"), lineWidth: 1.5))
                        .shadow(color: Color("appAccent").opacity(0.25), radius: 4, x: 0, y: 2)
                }
                .tint(Color("appAccent"))
            }
            .padding(.horizontal)

            // Quick actions
            HStack(spacing: 12) {
                Button {
                    let list = sorted(songs)
                    guard let first = list.first else { return }
                    playbackVM.play(song: first, in: list)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { isPresentingPlayer = true }
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.callout.weight(.semibold))
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)
                        .background(Color("appAccent").opacity(0.15), in: Capsule())
                }

                Button {
                    let list = sorted(songs).shuffled()
                    guard let first = list.first else { return }
                    playbackVM.play(song: first, in: list)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { isPresentingPlayer = true }
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .font(.callout.weight(.semibold))
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)
                        .background(Color("appAccent").opacity(0.15), in: Capsule())
                }

                Spacer()
            }
            .padding(.horizontal)

            // List of songs
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(sorted(songs)) { song in
                        FolderSongRow(song: song)
                            .environmentObject(libraryVM)
                            .environmentObject(playbackVM)
                            .onTapGesture {
                                let list = sorted(songs)
                                if playbackVM.currentSong?.id == song.id {
                                    isPresentingPlayer = true
                                } else {
                                    if let idx = list.firstIndex(of: song) {
                                        playbackVM.currentIndex = idx
                                    }
                                    playbackVM.play(song: song, in: list)
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
        .navigationTitle(folder.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .tint(Color("appAccent"))
        .fullScreenCover(isPresented: $isPresentingPlayer) {
            PlayerView()
                .environmentObject(playbackVM)
        }
    }
}

// MARK: - Header art (uses DefaultCover as placeholder, decodes off-main)
private struct FolderHeaderArt: View {
    let artworkData: Data?
    let side: CGFloat

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image("DefaultCover").resizable().scaledToFill()
                    .redacted(reason: .placeholder)
                    .task { await decodeIfNeeded() }
            }
        }
        .frame(width: side, height: side)
        .cornerRadius(12)
        .clipped()
    }

    private func decodeIfNeeded() async {
        guard let data = artworkData else { return }
        // light off-main decode
        let thumb = await Task.detached(priority: .utility) { UIImage(data: data) }.value
        await MainActor.run { image = thumb }
    }
}

// MARK: - Song Row (optimized; mirrors your Songs row styling)
private struct FolderSongRow: View {
    let song: Song
    @EnvironmentObject var libraryVM: LibraryViewModel
    @EnvironmentObject var playbackVM: PlaybackViewModel

    private let artSide: CGFloat = 60

    private var isPlaying: Bool { playbackVM.currentSong?.id == song.id }

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
            FolderSongArtThumb(song: song, side: artSide)
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
                    .foregroundColor(Color("appAccent"))
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

// MARK: - Tiny async artwork loader with fallback to DefaultCover
private struct FolderSongArtThumb: View {
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
                Image("DefaultCover")
                    .resizable()
                    .scaledToFill()
                    .redacted(reason: .placeholder)
                    .task(id: song.id) {
                        // Use VM thumbnail cache if you have it; else decode here
                        let size = CGSize(width: side, height: side)
                        if let thumb = await libraryVM.thumbnailFor(song: song, side: size) {
                            await MainActor.run { self.image = thumb }
                        } else if let data = song.artwork, let decoded = await Task.detached(priority: .utility, operation: { UIImage(data: data) }).value {
                            await MainActor.run { self.image = decoded }
                        }
                    }
            }
        }
    }
}
