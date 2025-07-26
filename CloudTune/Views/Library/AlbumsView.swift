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

    let columns = [
        GridItem(.flexible(), spacing: 20),
        GridItem(.flexible(), spacing: 20)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(groupedAlbums, id: \.album) { albumGroup in
                    let firstSong = albumGroup.songs.first

                    NavigationLink(destination: AlbumDetailView(albumName: albumGroup.album, songs: albumGroup.songs)) {
                        VStack(spacing: 12) {
                            ZStack {
                                // Glowing accent outline card
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(Color("appAccent"), lineWidth: 2.2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .fill(Color.clear)
                                    )
                                    .frame(width: 150, height: 150)
                                    .shadow(color: Color("appAccent").opacity(0.35), radius: 8, x: 0, y: 4)

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
                            }

                            Text(albumGroup.album)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .shadow(color: Color.primary.opacity(0.06), radius: 1, x: 0, y: 1)
                        }
                        .frame(width: 150)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(Color(.systemBackground).opacity(0.7))
                                .shadow(color: Color("appAccent").opacity(0.08), radius: 4, x: 0, y: 2)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(Color("appAccent").opacity(0.11), lineWidth: 0.7)
                        )
                    }
                    .tint(Color("appAccent"))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .navigationTitle("Albums")
        }
        .tint(Color("appAccent"))
    }
    
}
