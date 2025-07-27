import SwiftUI

struct PlaylistCoverImageView: View {
    let playlist: Playlist

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.appAccent, lineWidth: 1.5)
                )
                .shadow(radius: 8)

            if let filename = playlist.coverArtFilename {
                let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let fullPath = folder.appendingPathComponent(filename).path
                if let image = UIImage(contentsOfFile: fullPath) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 160, height: 160)
                        .clipped()
                        .cornerRadius(16)
                        .padding(6)
                } else {
                    Image("DefaultCover")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 160, height: 160)
                        .clipped()
                        .cornerRadius(16)
                        .padding(6)
                }
            } else {
                Image("DefaultCover")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 160, height: 160)
                    .clipped()
                    .cornerRadius(16)
                    .padding(6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
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
                    .frame(width: 180, height: 240)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
