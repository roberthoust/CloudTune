import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var libraryVM: LibraryViewModel
    @State private var showFolderPicker = false
    @State private var showFolderManager = false
    
    

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {

                    // MARK: - Primary Navigation Tiles
                    VStack(spacing: 16) {
                        NavigationLink(destination: SongsView()) {
                            LibraryTile(icon: "music.note", title: "Songs")
                        }

                        NavigationLink(destination: AlbumsView()) {
                            LibraryTile(icon: "rectangle.stack", title: "Albums")
                        }

                        NavigationLink(destination: PlaylistScreen()) {
                            LibraryTile(icon: "text.badge.plus", title: "Playlists")
                        }
                    }

                    // MARK: - Folder Management
                    DisclosureGroup("Import & Manage Folders") {
                        VStack(spacing: 10) {
                            Button(action: {
                                showFolderPicker = true
                            }) {
                                HStack {
                                    Image(systemName: "folder.badge.plus")
                                    Text("Import New Folder")
                                        .font(.headline)
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(10)
                            }

                            if !libraryVM.savedFolders.isEmpty {
                                ForEach(libraryVM.savedFolders, id: \.self) { folder in
                                    HStack {
                                        Text(folder.lastPathComponent)
                                            .lineLimit(1)
                                            .font(.subheadline)
                                        Spacer()
                                        Button(action: {
                                            libraryVM.removeFolder(folder)
                                        }) {
                                            Image(systemName: "trash")
                                                .foregroundColor(.red)
                                        }
                                    }
                                    .padding(8)
                                    .background(Color(.systemGray6))
                                    .cornerRadius(8)
                                }
                            } else {
                                Text("No folders imported.")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                    .padding(.top, 8)
                            }
                        }
                        .padding(.top, 8)
                    }
                    .padding()
                    .background(Color(.systemGray5))
                    .cornerRadius(12)

                    Spacer()
                }
                .padding()
                .navigationTitle("Library")
            }
            .sheet(isPresented: $showFolderPicker) {
                FolderPicker { folderURL in
                    libraryVM.loadSongs(from: folderURL)
                }
            }
            .sheet(isPresented: $libraryVM.showAlbumPrompt) {
                if let folder = libraryVM.pendingFolder {
                    AlbumImportPromptView(
                        folderURL: folder,
                        defaultName: folder.lastPathComponent,
                        onConfirm: { name in
                            libraryVM.applyAlbumOverride(name: name)
                        },
                        onCancel: {
                            libraryVM.showAlbumPrompt = false
                        }
                    )
                }
            }
        }
    }
}

// MARK: - Reusable Library Tile
struct LibraryTile: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)
                .frame(width: 36, height: 36)

            Text(title)
                .font(.headline)

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundColor(.gray)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 3, x: 0, y: 1)
    }
}
