import SwiftUI

struct PlaylistCoverImageView: View {
    let playlist: Playlist

    var body: some View {
        ZStack {
            if let filename = playlist.coverArtFilename {
                let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let fullPath = folder.appendingPathComponent(filename).path
                if let image = UIImage(contentsOfFile: fullPath) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 150, height: 150)
                        .cornerRadius(14)
                        .clipped()
                } else {
                    Image("DefaultCover")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 150, height: 150)
                        .cornerRadius(14)
                        .clipped()
                }
            } else {
                Image("DefaultCover")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 150, height: 150)
                    .cornerRadius(14)
                    .clipped()
            }
        }
    }
}

struct PlaylistScreen: View {
    @EnvironmentObject var playlistVM: PlaylistViewModel
    @EnvironmentObject var libraryVM: LibraryViewModel

    @State private var showCreateSheet = false
    @State private var editingPlaylist: Playlist? = nil

    let columns = [GridItem(.flexible()), GridItem(.flexible())]

    private var playlistGrid: some View {
        LazyVGrid(columns: columns, spacing: 20) {
            ForEach(playlistVM.playlists) { playlist in
                NavigationLink(destination: PlaylistDetailView(playlist: playlist)) {
                    VStack(alignment: .leading, spacing: 10) {
                        PlaylistCoverImageView(playlist: playlist)

                        Text(playlist.name)
                            .font(.headline)
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        Text("\(playlist.songIDs.count) song\(playlist.songIDs.count == 1 ? "" : "s")")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(width: 160)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .padding(.horizontal, 4)
                }
                .contextMenu {
                    Button("Edit") {
                        editingPlaylist = playlist
                    }

                    Button(role: .destructive) {
                        playlistVM.deletePlaylist(playlist)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Your Playlists")
                    .font(.largeTitle.bold())
                    .padding(.horizontal)

                playlistGrid
            }
            .padding(.horizontal)
        }
        .navigationTitle("Playlists")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    showCreateSheet = true
                }) {
                    Label("New Playlist", systemImage: "plus")
                        .labelStyle(IconOnlyLabelStyle())
                }
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            PlaylistCreationView(preloadedSong: nil)
                .environmentObject(playlistVM)
                .environmentObject(libraryVM)
        }
        .sheet(item: $editingPlaylist) { playlist in
            PlaylistEditView(playlist: playlist)
                .environmentObject(playlistVM)
                .environmentObject(libraryVM)
        }
    }
}
