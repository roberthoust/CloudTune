extension String {
    func ifEmpty(_ fallback: String) -> String {
        self.isEmpty ? fallback : self
    }
}

import SwiftUI

struct AlbumsView: View {
    @EnvironmentObject var libraryVM: LibraryViewModel
    @State private var isGridView = true

    var groupedAlbums: [(album: String, songs: [Song])] {
        let grouped = Dictionary(grouping: libraryVM.songs, by: { song in
            let meta = libraryVM.songMetadataCache[song.id]
            let albumName = meta.map { $0.album.trimmingCharacters(in: .whitespacesAndNewlines) }
            return (albumName?.isEmpty == false ? albumName! : song.album.trimmingCharacters(in: .whitespacesAndNewlines)).ifEmpty("No Album")
        })

        return grouped
            .map { (key, value) in (album: key, songs: value) }
            .sorted { $0.album.localizedCaseInsensitiveCompare($1.album) == .orderedAscending }
    }

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
            }
            .padding(.top, 6)
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
                        if let data = firstSong?.artwork, let uiImage = UIImage(data: data) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 140, height: 140)
                                .cornerRadius(14)
                                .clipped()
                        } else {
                            Image("DefaultCover")
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 140, height: 140)
                                .cornerRadius(14)
                                .clipped()
                        }

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
                        if let data = firstSong?.artwork, let uiImage = UIImage(data: data) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 70, height: 70)
                                .cornerRadius(10)
                                .clipped()
                        } else {
                            Image("DefaultCover")
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 70, height: 70)
                                .cornerRadius(10)
                                .clipped()
                        }

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
}
