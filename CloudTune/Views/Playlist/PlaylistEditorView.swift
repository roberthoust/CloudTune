//
//  PlaylistEditorView.swift
//  CloudTune
//
//  Create or edit a playlist: cover, name, and its songs (drag ≡ to reorder, − or swipe to remove).
//  Songs are added on their own searchable screen, so the search bar never covers the list.
//  Replaces PlaylistCreationView and PlaylistEditView.
//

import SwiftUI

struct PlaylistEditorView: View {
    @EnvironmentObject var playlistVM: PlaylistViewModel
    @EnvironmentObject var libraryVM: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    /// nil when creating a new playlist.
    private let original: Playlist?
    private let onSave: ((Playlist) -> Void)?

    @State private var name: String
    @State private var songIDs: [String]
    @State private var newCover: UIImage?
    @State private var songsByID: [String: Song] = [:]
    @State private var showImagePicker = false
    @State private var showSongPicker = false
    @FocusState private var nameFocused: Bool

    /// - Parameters:
    ///   - playlist: the playlist to edit, or nil to create one.
    ///   - initialSongIDs: songs a new playlist starts with (e.g. from "Add to Playlist").
    ///   - onSave: called with the saved playlist.
    init(playlist: Playlist? = nil, initialSongIDs: [String] = [], onSave: ((Playlist) -> Void)? = nil) {
        original = playlist
        self.onSave = onSave
        _name = State(initialValue: playlist?.name ?? "")
        var seen = Set<String>()
        _songIDs = State(initialValue: (playlist?.songIDs ?? initialSongIDs).filter { seen.insert($0).inserted })
    }

    private var isNew: Bool { original == nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var songs: [Song] { songIDs.compactMap { songsByID[$0] } }

    private var hasChanges: Bool {
        newCover != nil
            || trimmedName != (original?.name ?? "")
            || songIDs != (original?.songIDs ?? [])
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))

                Section {
                    Button {
                        nameFocused = false
                        showSongPicker = true
                    } label: {
                        Label("Add Songs", systemImage: "plus.circle.fill")
                            .font(.body.weight(.semibold))
                    }

                    ForEach(songs) { song in
                        PlaylistSongRow(song: song)
                    }
                    .onMove { songIDs.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { songIDs.remove(atOffsets: $0) }
                } header: {
                    Text(songs.isEmpty ? "Songs" : "\(songs.count) song\(songs.count == 1 ? "" : "s")")
                } footer: {
                    if songs.isEmpty {
                        Text("Add songs from your library. Drag ≡ to reorder them, or tap − to remove one.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            // Always show drag handles and remove buttons on the songs.
            .environment(\.editMode, .constant(.active))
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle(isNew ? "New Playlist" : "Edit Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Create" : "Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(trimmedName.isEmpty)
                }
            }
            .navigationDestination(isPresented: $showSongPicker) {
                SongPickerView(selectedIDs: $songIDs)
            }
            .sheet(isPresented: $showImagePicker) {
                ImagePicker(selectedImage: $newCover)
            }
            .task(id: libraryVM.songsVersion) { refreshSongs() }
        }
        .tint(Color("appAccent"))
        // Don't lose edits to an accidental swipe down.
        .interactiveDismissDisabled(hasChanges)
    }

    // MARK: - Header (cover + name)

    private var header: some View {
        VStack(spacing: 14) {
            Button {
                nameFocused = false
                showImagePicker = true
            } label: {
                cover
                    .frame(width: 168, height: 168)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "camera.circle.fill")
                            .font(.system(size: 30))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color("appAccent"))
                            .padding(8)
                    }
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose cover image")

            TextField("Playlist Name", text: $name)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($nameFocused)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var cover: some View {
        if let newCover {
            Image(uiImage: newCover).resizable().scaledToFill()
        } else if let original, original.coverArtFilename != nil {
            PlaylistCoverImageView(playlist: original, side: 168)
        } else {
            ZStack {
                Color(.secondarySystemGroupedBackground)
                Image(systemName: "music.note.list")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Color("appAccent"))
            }
        }
    }

    // MARK: - Actions

    private func refreshSongs() {
        songsByID = Dictionary(libraryVM.songs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Drop songs no longer in the library so rows and IDs line up for move/delete.
        // (Skip while the library is still loading, or everything would be dropped.)
        if !songsByID.isEmpty {
            songIDs.removeAll { songsByID[$0] == nil }
        }
    }

    private func save() {
        if let original {
            var updated = original
            updated.name = trimmedName
            updated.songIDs = songIDs
            playlistVM.updatePlaylist(updated, withNewImage: newCover)
            onSave?(updated)
        } else {
            let created = playlistVM.createPlaylist(name: trimmedName, songIDs: songIDs, cover: newCover)
            onSave?(created)
        }
        dismiss()
    }
}

// MARK: - Song picker

/// The whole library with a search bar in the navigation bar; tap a song to add or remove it.
struct SongPickerView: View {
    @Binding var selectedIDs: [String]

    @EnvironmentObject var libraryVM: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [Song] = []
    @State private var loaded = false

    private struct SearchQuery: Equatable {
        let text: String
        let version: Int
    }

    var body: some View {
        let selected = Set(selectedIDs)

        List(results) { song in
            Button {
                toggle(song.id)
            } label: {
                PlaylistSongRow(song: song, accessory: selected.contains(song.id) ? .added : .add)
            }
            .foregroundStyle(.primary)
        }
        .listStyle(.plain)
        .environment(\.editMode, .constant(.inactive))
        .overlay {
            if loaded && results.isEmpty {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView("No Songs", systemImage: "music.note",
                                           description: Text("Import a folder to add songs."))
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Title, artist or album")
        .autocorrectionDisabled()
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle(selectedIDs.isEmpty ? "Add Songs" : "\(selectedIDs.count) Selected")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }.fontWeight(.semibold)
            }
        }
        // Search the database; a new keystroke or library change cancels the previous search.
        .task(id: SearchQuery(text: query, version: libraryVM.songsVersion)) {
            if loaded {
                try? await Task.sleep(nanoseconds: 180_000_000)
                if Task.isCancelled { return }
            }
            let found = await libraryVM.pickerSongs(matching: query)
            if !Task.isCancelled {
                results = found
                loaded = true
            }
        }
    }

    private func toggle(_ id: String) {
        if let i = selectedIDs.firstIndex(of: id) {
            selectedIDs.remove(at: i)
        } else {
            selectedIDs.append(id)
        }
    }
}

// MARK: - Row

private struct PlaylistSongRow: View {
    enum Accessory { case none, add, added }

    let song: Song
    var accessory: Accessory = .none

    var body: some View {
        HStack(spacing: 12) {
            ArtworkThumbView(artworkID: song.artworkID)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .lineLimit(1)
                Text(song.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            switch accessory {
            case .none:
                EmptyView()
            case .add:
                Image(systemName: "plus.circle")
                    .font(.title3)
                    .foregroundStyle(Color("appAccent"))
            case .added:
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color("appAccent"))
            }
        }
        .contentShape(Rectangle())
    }
}
