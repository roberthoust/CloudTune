extension String {
    func ifEmpty(_ fallback: String) -> String {
        self.isEmpty ? fallback : self
    }
}


import SwiftUI
import Combine
import UIKit

private struct AlbumArtwork: View {
    let artworkID: String?
    let side: CGFloat

    var body: some View {
        ArtworkThumbView(artworkID: artworkID)
            .frame(width: side, height: side)
            .cornerRadius(side * 0.1)
            .clipped()
    }
}

struct AlbumsView: View {
    @EnvironmentObject var libraryVM: LibraryViewModel
    @State private var isGridView = true
    @State private var groupedAlbums: [(album: String, songs: [Song])] = []

    let columns = [
        GridItem(.flexible(), spacing: 20),
        GridItem(.flexible(), spacing: 20)
    ]

    var body: some View {
        VStack {
            HStack {
                Spacer()
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isGridView.toggle()
                    }
                }) {
                    Image(systemName: isGridView ? "list.bullet" : "square.grid.2x2")
                        .imageScale(.large)
                        .foregroundColor(Color("appAccent"))
                }
                .padding(.trailing, 20)
            }

            ScrollView {
                if isGridView {
                    LazyVGrid(columns: columns, spacing: 24) {
                        albumItems
                    }
                    .transition(.opacity.combined(with: .scale))
                    .animation(.easeInOut(duration: 0.3), value: isGridView)
                } else {
                    LazyVStack(spacing: 16) {
                        albumItems
                    }
                    .padding(.horizontal, 12)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: isGridView)
                }

                Spacer(minLength: 100) // extra scroll space so MiniPlayer doesn't overlap last albums
            }
            .padding(.top, 6)
            .onAppear { rebuildGroupedAlbums() }
            .onChange(of: libraryVM.songs) { _, _ in rebuildGroupedAlbums() }
            .onReceive(libraryVM.$songMetadataCache) { _ in rebuildGroupedAlbums() }
        }
        .navigationTitle("Albums")
        .tint(Color("appAccent"))
    }

    private var albumItems: some View {
        ForEach(groupedAlbums, id: \.album) { albumGroup in
            let firstSong = albumGroup.songs.first
            let metadata = firstSong.flatMap { libraryVM.songMetadataCache[$0.id] }

            NavigationLink(destination: AlbumDetailView(albumName: albumGroup.album, songs: albumGroup.songs)) {
                if isGridView {
                    VStack(spacing: 10) {
                        AlbumArtwork(artworkID: firstSong?.artworkID, side: 140)

                        Text(metadata?.album ?? albumGroup.album)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundColor(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(width: 140)
                    }
                    .padding(.vertical, 6)
                    .frame(width: 160)
                    .contentShape(Rectangle())
                } else {
                    HStack {
                        AlbumArtwork(artworkID: firstSong?.artworkID, side: 70)

                        Text(metadata?.album ?? albumGroup.album)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .shadow(color: Color.primary.opacity(0.06), radius: 1, x: 0, y: 1)

                        Spacer()
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(.systemBackground).opacity(0.7))
                            .shadow(color: Color("appAccent").opacity(0.08), radius: 4, x: 0, y: 2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color("appAccent").opacity(0.11), lineWidth: 0.7)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                }
            }
            .tint(Color("appAccent"))
        }
    }

    private func rebuildGroupedAlbums() {
        let songs = libraryVM.songs
        let meta = libraryVM.songMetadataCache

        Task.detached(priority: .utility) {
            let groupedDict = Dictionary(grouping: songs, by: { song in
                let m = meta[song.id]
                let albumName = (m?.album ?? song.album).trimmingCharacters(in: .whitespacesAndNewlines)
                return albumName.isEmpty ? "No Album" : albumName
            })
            let result = groupedDict
                .map { (key, value) in (album: key, songs: value) }
                .sorted { $0.album.localizedCaseInsensitiveCompare($1.album) == .orderedAscending }

            await MainActor.run {
                self.groupedAlbums = result
            }
        }
    }
}
