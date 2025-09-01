import SwiftUI
import UIKit

struct PlaylistDetailView: View {
    let playlist: Playlist

    @EnvironmentObject var libraryVM: LibraryViewModel
    @EnvironmentObject var playbackVM: PlaybackViewModel
    @EnvironmentObject var playlistVM: PlaylistViewModel

    @State private var showEditSheet = false
    @State private var matchedSongs: [Song] = []

    var body: some View {
        VStack(spacing: 16) {
            headerSection
            // Match FolderDetailView: scrollable song list area
            ScrollView {
                songsSection
                    .padding(.horizontal)
                    .padding(.bottom, 100)
            }
            Spacer(minLength: 0)
        }
        .navigationTitle("Playlists")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Color("appAccent"))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showEditSheet = true } label: { Image(systemName: "pencil") }
            }
        }
        .sheet(isPresented: $showEditSheet) {
            PlaylistEditView(playlist: playlist)
                .environmentObject(playlistVM)
                .environmentObject(libraryVM)
        }
        .onAppear(perform: loadPlaylistSongs)
        .onChange(of: libraryVM.songs) { _ in loadPlaylistSongs() }
        .onChange(of: playlist.songIDs) { _ in loadPlaylistSongs() }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(spacing: 12) {
            // Inline header like Folders: artwork on the left, title/details on the right
            HStack(spacing: 12) {
                coverThumb(side: 64)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color("appAccent").opacity(0.15), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(playlist.name)
                        .font(.title2.bold())
                        .foregroundColor(.primary)
                        .lineLimit(2)

                    Text("\(matchedSongs.count) song\(matchedSongs.count == 1 ? "" : "s")")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // (Optional) space for future sort menu to mirror Folders
            }
            .padding(.horizontal)

            // Buttons below, matching Folders look/feel
            headerButtons
                .padding(.horizontal)
        }
        .padding(.top, 6)
    }

    private var songsSection: some View {
        LazyVStack(spacing: 14) {
            ForEach(matchedSongs) { song in
                InlinePlaylistSongRow(
                    song: song,
                    isPlaying: playbackVM.currentSong?.id == song.id
                )
                .environmentObject(libraryVM)
                .environmentObject(playbackVM)
                .onTapGesture {
                    let list = matchedSongs
                    if playbackVM.currentSong?.id == song.id {
                        playbackVM.showPlayer = true
                    } else {
                        if let idx = list.firstIndex(of: song) {
                            playbackVM.currentIndex = idx
                        }
                        playbackVM.play(song: song, in: list, contextName: playlist.name)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            playbackVM.showPlayer = true
                        }
                    }
                }
            }
        }
    }

    // MARK: - Header buttons (match FolderDetailView style)

    private var headerButtons: some View {
        HStack(spacing: 12) {
            Button {
                let list = matchedSongs
                guard let first = list.first else { return }
                playbackVM.play(song: first, in: list, contextName: playlist.name)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { playbackVM.showPlayer = true }
            } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.callout.weight(.semibold))
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)
                    .background(Color("appAccent").opacity(0.15), in: Capsule())
            }

            Button {
                let list = matchedSongs.shuffled()
                guard let first = list.first else { return }
                playbackVM.play(song: first, in: list, contextName: playlist.name + " • Shuffled")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { playbackVM.showPlayer = true }
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .font(.callout.weight(.semibold))
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)
                    .background(Color("appAccent").opacity(0.15), in: Capsule())
            }

            Spacer()
        }
    }

    // MARK: - Views

    @ViewBuilder
    private func coverThumb(side: CGFloat) -> some View {
        // Draw a stroked container similar to Folders, with the image inside
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color("appAccent"), lineWidth: 1)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )

            if let filename = playlist.coverArtFilename,
               let ui = loadCoverImage(filename: filename) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(4)
            } else {
                Image("DefaultCover")
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(4)
            }
        }
    }

    // MARK: - Data

    private func loadCoverImage(filename: String) -> UIImage? {
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent(filename)
        return UIImage(contentsOfFile: path.path)
    }

    private func loadPlaylistSongs() {
        // Fast map lookup to avoid O(n^2)
        let map = Dictionary(uniqueKeysWithValues: libraryVM.songs.map { ($0.id, $0) })
        matchedSongs = playlist.songIDs.compactMap { map[$0] }
    }
}

// MARK: - Inline row (matches Folder feel; private to this file)
private struct InlinePlaylistSongRow: View {
    let song: Song
    let isPlaying: Bool

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
        .task(id: song.id) {
            // Use VM thumbnail helper if available; else fall back to inline decode.
            if let thumb = await libraryVM.thumbnailFor(song: song, side: CGSize(width: side, height: side)) {
                await MainActor.run { self.thumb = thumb }
            } else if let data = song.artwork, let img = UIImage(data: data) {
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
