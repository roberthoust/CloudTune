import SwiftUI

struct AlbumsView: View {
    @EnvironmentObject var libraryVM: LibraryViewModel

    // Group songs by album name
    var groupedAlbums: [(album: String, songs: [Song])] {
        let grouped = Dictionary(grouping: libraryVM.songs, by: { song in
            song.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No Album" : song.album
        })

        return grouped
            .map { (key, value) in (album: key, songs: value) }
            .sorted { $0.album < $1.album }
    }

    let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(groupedAlbums, id: \.album) { albumGroup in
                    let firstSong = albumGroup.songs.first
                    
                    NavigationLink(destination: AlbumDetailView(albumName: albumGroup.album, songs: albumGroup.songs)) {
                        VStack {
                            if let data = firstSong?.artwork, let uiImage = UIImage(data: data) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 140, height: 140)
                                    .cornerRadius(12)
                                    .clipped()
                            } else {
                                Image("DefaultCover")
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 140, height: 140)
                                    .cornerRadius(12)
                                    .clipped()
                            }
                            
                            Text(albumGroup.album)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .frame(width: 140)
                    }
                }
                .padding()
            }
            .navigationTitle("Albums")
        }
    }
    
}
