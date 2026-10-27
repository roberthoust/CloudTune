import SwiftUI

/// "Add to Playlist" for one song: pick a playlist, or make a new one that starts with the song.
struct AddToPlaylistSheet: View {
    let song: Song
    @Binding var selectedPlaylist: Playlist?

    @EnvironmentObject var playlistVM: PlaylistViewModel
    @EnvironmentObject var libraryVM: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var showCreatePlaylist = false
    @State private var createdPlaylist: Playlist?

    private var filteredPlaylists: [Playlist] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return playlistVM.playlists }
        return playlistVM.playlists.filter { $0.name.localizedStandardContains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showCreatePlaylist = true
                    } label: {
                        Label("New Playlist", systemImage: "plus.circle.fill")
                            .font(.body.weight(.semibold))
                    }
                }

                if !filteredPlaylists.isEmpty {
                    Section("Your Playlists") {
                        ForEach(filteredPlaylists) { playlist in
                            playlistRow(playlist)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if filteredPlaylists.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: "Search playlists")
            .autocorrectionDisabled()
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showCreatePlaylist, onDismiss: {
                // Created a playlist with the song in it: we're done.
                if let createdPlaylist {
                    selectedPlaylist = createdPlaylist
                    dismiss()
                }
            }) {
                PlaylistEditorView(initialSongIDs: [song.id]) { createdPlaylist = $0 }
                    .environmentObject(playlistVM)
                    .environmentObject(libraryVM)
            }
        }
        .tint(Color("appAccent"))
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        let alreadyIn = playlist.songIDs.contains(song.id)
        return Button {
            if !alreadyIn {
                var updated = playlist
                updated.songIDs.append(song.id)
                playlistVM.updatePlaylist(updated)
                selectedPlaylist = updated
            } else {
                selectedPlaylist = playlist
            }
            dismiss()
        } label: {
            HStack(spacing: 12) {
                PlaylistCoverImageView(playlist: playlist, side: 52)

                VStack(alignment: .leading, spacing: 3) {
                    Text(playlist.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(alreadyIn
                         ? "Already added"
                         : "\(playlist.songIDs.count) song\(playlist.songIDs.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if alreadyIn {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color("appAccent"))
                }
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
    }
}
