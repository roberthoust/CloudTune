import SwiftUI

struct PlaylistScreen: View {
    @EnvironmentObject var playlistVM: PlaylistViewModel
    @EnvironmentObject var libraryVM: LibraryViewModel

    @State private var showCreateSheet = false
    @State private var editingPlaylist: Playlist? = nil

    let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Your Playlists")
                    .font(.title.bold())
                    .padding(.horizontal)

                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(playlistVM.playlists) { playlist in
                        NavigationLink(destination: PlaylistDetailView(playlist: playlist)) {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack(alignment: .bottomTrailing) {
                                    if let filename = playlist.coverArtFilename {
                                        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                                        let fullPath = folder.appendingPathComponent(filename).path
                                        if let image = UIImage(contentsOfFile: fullPath) {
                                            Image(uiImage: image)
                                                .resizable()
                                                .aspectRatio(1, contentMode: .fill)
                                                .frame(width: 160, height: 160)
                                                .cornerRadius(16)
                                                .shadow(radius: 4)
                                                .clipped()
                                        } else {
                                            Image("DefaultCover")
                                                .resizable()
                                                .aspectRatio(1, contentMode: .fill)
                                                .frame(width: 160, height: 160)
                                                .cornerRadius(16)
                                                .shadow(radius: 4)
                                                .clipped()
                                        }
                                    }
                                }

                                Text(playlist.name)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                    .lineLimit(1)

                                Text("\(playlist.songIDs.count) song\(playlist.songIDs.count == 1 ? "" : "s")")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            .padding(8)
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
                .padding(.horizontal)
            }
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
            PlaylistCreationView()
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
