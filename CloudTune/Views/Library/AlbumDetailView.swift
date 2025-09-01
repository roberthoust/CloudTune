import SwiftUI
import ImageIO
import UniformTypeIdentifiers

// MARK: - Sort options (scoped to this file)
private enum AlbumSongSort: String, CaseIterable, Identifiable {
    case recent = "Recent"
    case title  = "Title"
    case artist = "Artist"
    case track  = "Track #"

    var id: String { rawValue }
}

// MARK: - Small header art with safe placeholder & off-main decode
private struct AlbumHeaderArt: View {
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
        guard let data = artworkData, !data.isEmpty else { return }
        let decoded = await Task.detached(priority: .utility) { UIImage(data: data) }.value
        await MainActor.run { image = decoded }
    }
}

// MARK: - Song row styled like Folder detail
private struct AlbumSongRow: View {
    let song: Song
    let isCurrent: Bool

    @EnvironmentObject var libraryVM: LibraryViewModel
    @EnvironmentObject var playbackVM: PlaybackViewModel

    @State private var thumb: UIImage?
    private let side: CGFloat = 60

    private var metadata: SongMetadata {
        libraryVM.songMetadataCache[song.id] ?? SongMetadata(
            title: song.title,
            artist: song.artist,
            album: song.album,
            genre: song.genre,
            year: song.year,
            trackNumber: song.trackNumber,
            discNumber: song.discNumber
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            artwork
                .frame(width: side, height: side)
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

            if isCurrent {
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
        .contextMenu {
            Button {
                playbackVM.songToAddToPlaylist = song
                playbackVM.showAddToPlaylistSheet = true
            } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }
        }
        .task(id: song.id) {
            // Prefer VM thumbnail cache; fallback to direct decode
            if let thumb = await libraryVM.thumbnailFor(song: song, side: CGSize(width: side, height: side)) {
                await MainActor.run { self.thumb = thumb }
            } else if let data = song.artwork, let img = await Task.detached(priority: .utility, operation: { UIImage(data: data) }).value {
                await MainActor.run { self.thumb = img }
            }
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let img = thumb {
            Image(uiImage: img).resizable().scaledToFill()
        } else if let data = song.artwork, let img = UIImage(data: data) {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            Image("DefaultCover").resizable().scaledToFill().redacted(reason: .placeholder)
        }
    }
}

struct AlbumDetailView: View {
    let albumName: String
    /// Pass in unsorted songs from the caller.
    let songs: [Song]

    @EnvironmentObject private var libraryVM: LibraryViewModel
    @EnvironmentObject private var playbackVM: PlaybackViewModel

    @State private var selectedSort: AlbumSongSort = .track
    @State private var isPresentingPlayer = false
    @State private var selectedPlaylist: Playlist? = nil

    // MARK: - Sorting like FolderDetailView (but album-centric)
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
                if lhs.discNumber != rhs.discNumber { return lhs.discNumber < rhs.discNumber }
                if lhs.trackNumber != rhs.trackNumber { return lhs.trackNumber < rhs.trackNumber }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
    }

    private var headerArtworkData: Data? { songs.first?.artwork }

    var body: some View {
        VStack(spacing: 16) {
            // Header inline like Folders
            HStack(alignment: .center, spacing: 12) {
                AlbumHeaderArt(artworkData: headerArtworkData, side: 64)

                VStack(alignment: .leading, spacing: 4) {
                    Text(albumName)
                        .font(.title2.bold())
                        .lineLimit(2)
                    Text("\(songs.count) item\(songs.count == 1 ? "" : "s")")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Sort menu to match FolderDetailView
                Menu {
                    ForEach(AlbumSongSort.allCases) { option in
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

            // Quick actions (Play / Shuffle) matching FolderDetailView
            HStack(spacing: 12) {
                Button {
                    let list = sorted(songs)
                    guard let first = list.first else { return }
                    playbackVM.play(song: first, in: list, contextName: albumName)
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
                    playbackVM.play(song: first, in: list, contextName: albumName + " • Shuffled")
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

            // Songs list styled like FolderDetailView
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(sorted(songs)) { song in
                        AlbumSongRow(
                            song: song,
                            isCurrent: playbackVM.currentSong?.id == song.id
                        )
                        .environmentObject(libraryVM)
                        .environmentObject(playbackVM)
                        .onTapGesture {
                            let list = sorted(songs)
                            if playbackVM.currentSong?.id == song.id {
                                isPresentingPlayer = true
                            } else {
                                if let idx = list.firstIndex(of: song) { playbackVM.currentIndex = idx }
                                playbackVM.play(song: song, in: list, contextName: albumName)
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
        .navigationTitle(albumName)
        .navigationBarTitleDisplayMode(.inline)
        .tint(Color("appAccent"))
        .sheet(isPresented: $playbackVM.showAddToPlaylistSheet) {
            if let song = playbackVM.songToAddToPlaylist {
                AddToPlaylistSheet(song: song, selectedPlaylist: $selectedPlaylist)
                    .environmentObject(playbackVM)
            }
        }
        .fullScreenCover(isPresented: $isPresentingPlayer) {
            PlayerView().environmentObject(playbackVM)
        }
    }
}
