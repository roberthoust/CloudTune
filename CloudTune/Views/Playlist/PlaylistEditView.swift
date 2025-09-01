//
//  PlaylistEditView.swift
//  CloudTune
//

import SwiftUI
import PhotosUI
import CropViewController
import TOCropViewController

struct PlaylistEditView: View {
    @EnvironmentObject var playlistVM: PlaylistViewModel
    @EnvironmentObject var libraryVM: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    // MARK: - State
    @State private var name: String
    @State private var selectedCover: UIImage?
    @State private var selectedSongsOrdered: [Song] = []
    @State private var showImagePicker = false

    // Search
    @State private var searchText = ""
    @State private var filteredCandidates: [Song] = []        // derived list for "Add Songs"
    @State private var searchWork: Task<Void, Never>? = nil   // debouncer / canceller

    // Cached data to avoid recomputation on every keystroke
    @State private var songMap: [Song.ID: Song] = [:]

    // Keyboard calm animations (optional but cheap)
    @State private var keyboardVisible = false

    let playlist: Playlist

    // MARK: - Init
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

    // MARK: - Body
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {

                    // ===== Header Card (CloudTune style) =====
                    VStack(spacing: 12) {
                        HStack {
                            Text("Edit Playlist")
                                .font(.title2.weight(.semibold))
                            Spacer()
                            // subtle badge
                            Text("\(selectedSongsOrdered.count) songs")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(Capsule())
                        }

                        // Cover + Name stacked
                        Button {
                            showImagePicker.toggle()
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color(.secondarySystemBackground))
                                if let image = selectedCover {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    VStack(spacing: 8) {
                                        Image(systemName: "photo.on.rectangle.angled")
                                            .font(.system(size: 36, weight: .semibold))
                                            .foregroundColor(Color("appAccent"))
                                        Text("Tap to select image")
                                            .font(.footnote)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .frame(height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Playlist Name")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                            TextField("Enter name", text: $name)
                                .textInputAutocapitalization(.words)
                                .disableAutocorrection(true)
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color(.secondarySystemBackground))
                                )
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(.systemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color("appAccent").opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: Color("appAccent").opacity(0.05), radius: 6, x: 0, y: 3)

                    // ===== Current Songs Card (reorder/delete) =====
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Playlist Songs")
                                .font(.headline)
                            Spacer()
                            Text("Drag to reorder")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if selectedSongsOrdered.isEmpty {
                            Text("No songs in playlist.")
                                .foregroundColor(.secondary)
                                .padding(.vertical, 8)
                        } else {
                            // Use lightweight ListStyle within a fixed container to get reordering
                            ReorderableList(
                                items: $selectedSongsOrdered,
                                row: { song in
                                    HStack(spacing: 10) {
                                        Image(systemName: "line.3.horizontal")
                                            .foregroundColor(.secondary)
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
                                    .padding(.vertical, 6)
                                },
                                onDelete: { indexSet in
                                    deleteSongs(at: indexSet)
                                }
                            )
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(.systemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )

                    // ===== Add Songs Card (debounced search) =====
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Add Songs")
                            .font(.headline)

                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                            TextField("Search songs…", text: $searchText)
                                .onChange(of: searchText) { _ in scheduleSearch() }
                                .submitLabel(.search)
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(.secondarySystemBackground))
                        )

                        if filteredCandidates.isEmpty {
                            Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                 ? "All songs are already in this playlist, or your library is empty."
                                 : "No matches.")
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                        } else {
                            // Lightweight, simple list of buttons
                            VStack(spacing: 6) {
                                ForEach(filteredCandidates) { song in
                                    Button {
                                        selectedSongsOrdered.append(song)
                                        filteredCandidates.removeAll { $0.id == song.id }
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(song.title)
                                                    .lineLimit(1)
                                                    .fontWeight(.medium)
                                                Text(song.artist)
                                                    .foregroundColor(.secondary)
                                                    .font(.caption)
                                                    .lineLimit(1)
                                            }
                                            Spacer()
                                            Image(systemName: "plus.circle.fill")
                                                .foregroundColor(Color("appAccent"))
                                        }
                                        .padding(12)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .fill(Color(.secondarySystemBackground))
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(.systemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .background(
                LinearGradient(
                    colors: [
                        Color("appAccent").opacity(0.10),
                        Color(.systemBackground)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            .navigationTitle("Edit Playlist")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                    .tint(Color("appAccent"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        savePlaylist()
                        dismiss()
                    } label: {
                        Label("Save", systemImage: "checkmark.circle.fill")
                            .labelStyle(.iconOnly)
                    }
                    .tint(Color("appAccent"))
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || selectedSongsOrdered.isEmpty)
                }
            }
            .sheet(isPresented: $showImagePicker) {
                ImagePicker(selectedImage: $selectedCover)
            }

            // Calm animations during typing / keyboard transitions
            .transaction { tx in
                if keyboardVisible { tx.animation = nil }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardVisible = false
            }

            // One-time setup
            .onAppear {
                // Build song map once for fast lookup
                songMap = Dictionary(uniqueKeysWithValues: libraryVM.songs.map { ($0.id, $0) })
                // Build playlist order from IDs
                selectedSongsOrdered = playlist.songIDs.compactMap { songMap[$0] }
                // Initial candidates list (no search text yet)
                rebuildCandidates(for: searchText)
            }
            // Keep candidates fresh when library changes
            .onChange(of: libraryVM.songs) { _ in
                songMap = Dictionary(uniqueKeysWithValues: libraryVM.songs.map { ($0.id, $0) })
                rebuildCandidates(for: searchText)
            }
        }
        .tint(Color("appAccent"))
    }

    // MARK: - Save
    private func savePlaylist() {
        var coverPath: String? = playlist.coverArtFilename

        if let image = selectedCover {
            let filename = playlistVM.safeFilename(for: name)
            if playlistVM.saveCoverImage(image: image, as: filename) != nil {
                coverPath = filename
            }
        }

        let updated = Playlist(
            id: playlist.id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            coverArtFilename: coverPath,
            songIDs: selectedSongsOrdered.map { $0.id }
        )
        playlistVM.updatePlaylist(updated)
    }

    // MARK: - Reordering / Deleting
    private func deleteSongs(at offsets: IndexSet) {
        selectedSongsOrdered.remove(atOffsets: offsets)
        rebuildCandidates(for: searchText)
    }

    // MARK: - Search (debounced, off-main)
    private func scheduleSearch() {
        searchWork?.cancel()
        let text = searchText
        searchWork = Task {
            try? await Task.sleep(nanoseconds: 180_000_000) // 180ms
            await rebuildCandidates(for: text)
        }
    }

    @MainActor
    private func setCandidates(_ songs: [Song]) {
        self.filteredCandidates = songs
    }

    private func rebuildCandidates(for text: String) {
        let library = libraryVM.songs
        let excludedIDs = Set(selectedSongsOrdered.map { $0.id })
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        Task.detached(priority: .utility) {
            let base = library.filter { !excludedIDs.contains($0.id) }
            let filtered: [Song]
            if needle.isEmpty {
                filtered = base
            } else {
                filtered = base.filter {
                    $0.title.lowercased().contains(needle)
                    || $0.artist.lowercased().contains(needle)
                }
            }
            await setCandidates(Array(filtered.prefix(500)))
        }
    }
}

// MARK: - Tiny Reorderable List Wrapper
/// A lightweight wrapper that embeds a List to get `.onMove` without a full Form.
/// Keeps CloudTune card look by removing separators & insets.
private struct ReorderableList<RowData: Identifiable, RowView: View>: View {
    @Binding var items: [RowData]
    let row: (RowData) -> RowView
    let onDelete: (IndexSet) -> Void

    init(items: Binding<[RowData]>,
         row: @escaping (RowData) -> RowView,
         onDelete: @escaping (IndexSet) -> Void) {
        self._items = items
        self.row = row
        self.onDelete = onDelete
    }

    var body: some View {
        List {
            ForEach(items) { item in
                row(item)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .onMove(perform: move)
            .onDelete(perform: onDelete)
        }
        .environment(\.editMode, .constant(.active)) // show drag handles
        .listStyle(.plain)
        .scrollDisabled(true) // let outer ScrollView scroll
        .frame(maxHeight: min(CGFloat(items.count) * 54, 360)) // cap height
    }

    private func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }
}
