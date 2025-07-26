//
//  PlaylistEditView.swift
//  CloudTune
//
//  Created by Robert Houst on 7/22/25.
//

import SwiftUI
import PhotosUI
import CropViewController
import TOCropViewController

struct PlaylistEditView: View {
    @EnvironmentObject var playlistVM: PlaylistViewModel
    @EnvironmentObject var libraryVM: LibraryViewModel
    @Environment(\.dismiss) var dismiss

    @State private var name: String
    @State private var selectedCover: UIImage?
    @State private var selectedSongsOrdered: [Song] = []
    @State private var showImagePicker = false
    @State private var searchText = ""

    let playlist: Playlist

    init(playlist: Playlist) {
        self.playlist = playlist
        _name = State(initialValue: playlist.name)

        if let coverPath = playlist.coverArtFilename {
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let fullPath = folder.appendingPathComponent(coverPath).path
            if let image = UIImage(contentsOfFile: fullPath) {
                _selectedCover = State(initialValue: image)
            } else {
                _selectedCover = State(initialValue: nil)
            }
        } else {
            _selectedCover = State(initialValue: nil)
        }
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Playlist Name")) {
                    TextField("Enter name", text: $name)
                }

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

                Section(header: Text("Playlist Songs (Drag to Reorder)")) {
                    if selectedSongsOrdered.isEmpty {
                        Text("No songs in playlist.")
                    } else {
                        ForEach(selectedSongsOrdered) { song in
                            HStack(spacing: 8) {
                                Image(systemName: "line.3.horizontal")
                                    .foregroundColor(.gray)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(song.title)
                                        .font(.body)
                                        .lineLimit(1)
                                    Text(song.artist)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 4)
                        }
                        .onMove(perform: moveSongs)
                        .onDelete(perform: deleteSongs)
                    }
                }

                Section(header: Text("Add Songs")) {
                    TextField("Search songs...", text: $searchText)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .padding(.vertical, 4)

                    let filtered = libraryVM.songs.filter {
                        searchText.isEmpty ||
                        $0.title.lowercased().contains(searchText.lowercased()) ||
                        $0.artist.lowercased().contains(searchText.lowercased())
                    }.filter { song in
                        !selectedSongsOrdered.contains(where: { $0.id == song.id })
                    }

                    ForEach(filtered) { song in
                        Button(action: {
                            selectedSongsOrdered.append(song)
                        }) {
                            HStack {
                                Text(song.title)
                                Spacer()
                                Text(song.artist)
                                    .foregroundColor(.gray)
                                    .font(.subheadline)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Edit Playlist")
            .navigationBarItems(
                leading: Button("Cancel") { dismiss() },
                trailing: Button("Save") {
                    updatePlaylist()
                    dismiss()
                }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || selectedSongsOrdered.isEmpty)
            )
            .sheet(isPresented: $showImagePicker) {
                ImagePicker(selectedImage: $selectedCover)
            }
            .onAppear {
                let songMap = Dictionary(uniqueKeysWithValues: libraryVM.songs.map { ($0.id, $0) })
                selectedSongsOrdered = playlist.songIDs.compactMap { songMap[$0] }
            }
        }
    }

    func updatePlaylist() {
        var coverPath: String? = playlist.coverArtFilename

        if let image = selectedCover {
            let filename = playlistVM.safeFilename(for: name)
            if playlistVM.saveCoverImage(image: image, as: filename) != nil {
                coverPath = filename
            }
        }

        let updated = Playlist(
            id: playlist.id,
            name: name.trimmingCharacters(in: .whitespaces),
            coverArtFilename: coverPath,
            songIDs: selectedSongsOrdered.map { $0.id }
        )

        playlistVM.updatePlaylist(updated)
    }

    func moveSongs(from source: IndexSet, to destination: Int) {
        selectedSongsOrdered.move(fromOffsets: source, toOffset: destination)
    }

    func deleteSongs(at offsets: IndexSet) {
        selectedSongsOrdered.remove(atOffsets: offsets)
    }
}
