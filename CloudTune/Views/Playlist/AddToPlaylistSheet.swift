//
//  AddToPlaylistSheet.swift
//  CloudTune
//
//  Created by Robert Houst on 7/22/25.
//

import SwiftUI

struct AddToPlaylistSheet: View {
    let song: Song
    @EnvironmentObject var playlistVM: PlaylistViewModel
    @Environment(\.dismiss) var dismiss

    @State private var searchText = ""
    @State private var showCreatePlaylist = false

    var filteredPlaylists: [Playlist] {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return playlistVM.playlists
        } else {
            return playlistVM.playlists.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    var body: some View {
        NavigationView {
            VStack {
                // Search bar
                TextField("Search playlists...", text: $searchText)
                    .padding(10)
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                    .padding(.horizontal)

                List {
                    ForEach(filteredPlaylists) { playlist in
                        Button {
                            var updated = playlist
                            if !updated.songIDs.contains(song.id) {
                                updated.songIDs.append(song.id)
                                playlistVM.updatePlaylist(updated)
                            }
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                if let path = playlist.coverArtFilename,
                                   let img = UIImage(contentsOfFile: path) {
                                    Image(uiImage: img)
                                        .resizable()
                                        .frame(width: 50, height: 50)
                                        .cornerRadius(8)
                                } else {
                                    Image("DefaultCover")
                                        .resizable()
                                        .frame(width: 50, height: 50)
                                        .cornerRadius(8)
                                }

                                VStack(alignment: .leading) {
                                    Text(playlist.name)
                                        .font(.headline)
                                    Text("\(playlist.songIDs.count) song\(playlist.songIDs.count == 1 ? "" : "s")")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                if playlist.songIDs.contains(song.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    // Create New Playlist Button
                    Button {
                        showCreatePlaylist = true
                    } label: {
                        Label("Create New Playlist", systemImage: "plus.circle.fill")
                            .font(.headline)
                            .foregroundColor(.blue)
                            .padding(.vertical, 6)
                    }
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showCreatePlaylist) {
                PlaylistCreationView()
                    .environmentObject(playlistVM)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
