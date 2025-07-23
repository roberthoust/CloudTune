import SwiftUI
import PhotosUI

struct PlaylistCreationView: View {
    @EnvironmentObject var playlistVM: PlaylistViewModel
    @EnvironmentObject var libraryVM: LibraryViewModel
    @Environment(\.dismiss) var dismiss

    @State private var name = ""
    @State private var selectedCover: UIImage?
    @State private var selectedSongs: Set<String> = []
    @State private var showImagePicker = false
    @State private var searchText = ""

    var filteredSongs: [Song] {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return libraryVM.songs
        } else {
            return libraryVM.songs.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.artist.localizedCaseInsensitiveContains(searchText) ||
                $0.album.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    var body:    some View {
        NavigationView {
            Form {
                // Playlist name
                Section(header: Text("Playlist Name")) {
                    TextField("Enter name", text: $name)
                }

                // Cover art picker
                Section(header: Text("Cover Art")) {
                    Button(action: {
                        showImagePicker.toggle()
                    }) {
                        if let image = selectedCover {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(height: 180)
                                .cornerRadius(12)
                                .clipped()
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(.systemGray5))
                                    .frame(height: 180)
                                Text("Tap to select image")
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                }

                // Song selector with search
                Section(header: Text("Select Songs")) {
                    TextField("Search songs...", text: $searchText)

                    List(filteredSongs) { song in
                        Button(action: {
                            if selectedSongs.contains(song.id) {
                                selectedSongs.remove(song.id)
                            } else {
                                selectedSongs.insert(song.id)
                            }
                        }) {
                            HStack {
                                Text(song.title)
                                    .lineLimit(1)
                                Spacer()
                                if selectedSongs.contains(song.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("New Playlist")
            .navigationBarItems(
                leading: Button("Cancel") { dismiss() },
                trailing: Button("Save") {
                    createPlaylist()
                    dismiss()
                }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || selectedSongs.isEmpty)
            )
            .sheet(isPresented: $showImagePicker) {
                ImagePicker(selectedImage: $selectedCover)
            }
        }
    }

    func createPlaylist() {
        var coverPath: String? = nil

        if let image = selectedCover {
            let filename = playlistVM.safeFilename(for: name)
            if playlistVM.saveCoverImage(image: image, as: filename) != nil {
                coverPath = filename
            }
        }

        playlistVM.createPlaylist(
            name: name.trimmingCharacters(in: .whitespaces),
            songIDs: Array(selectedSongs),
            coverArtFilename: coverPath
        )
    }
}
