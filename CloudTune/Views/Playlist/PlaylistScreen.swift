import SwiftUI
import UIKit   // for UIImage(contentsOfFile:)

private enum PlaylistViewMode: String, CaseIterable, Identifiable {
    case grid
    case list
    var id: String { rawValue }
    var title: String { self == .grid ? "Grid" : "List" }
    var systemImage: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
}

// Make the cover reusable at different sizes (grid vs list)
struct PlaylistCoverImageView: View {
    let playlist: Playlist
    var side: CGFloat = 150

    var body: some View {
        ZStack {
            if let filename = playlist.coverArtFilename {
                let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let path = folder.appendingPathComponent(filename).path
                if let image = UIImage(contentsOfFile: path) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image("DefaultCover")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            } else {
                Image("DefaultCover")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: side, height: side)
        .cornerRadius(side * 0.093)   // scale radius with size
        .clipped()
    }
}

struct PlaylistScreen: View {
    @EnvironmentObject var playlistVM: PlaylistViewModel
    @EnvironmentObject var libraryVM: LibraryViewModel

    @State private var showCreateSheet = false
    @State private var editingPlaylist: Playlist? = nil

    @AppStorage("playlistViewMode") private var viewModeRaw: String = PlaylistViewMode.grid.rawValue
    @State private var playlistToDelete: Playlist? = nil
    @State private var showDeleteConfirm: Bool = false

    // Computed wrapper so we use the @AppStorage string safely
    private var viewMode: PlaylistViewMode {
        get { PlaylistViewMode(rawValue: viewModeRaw) ?? .grid }
        set { viewModeRaw = newValue.rawValue }
    }

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    // Grid layout
    private var playlistGrid: some View {
        LazyVGrid(columns: columns, spacing: 20) {
            ForEach(playlistVM.playlists) { playlist in
                NavigationLink(destination: PlaylistDetailView(playlist: playlist)) {
                    VStack(alignment: .leading, spacing: 10) {
                        PlaylistCoverImageView(playlist: playlist, side: 140)

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
                    Button("Edit") { editingPlaylist = playlist }
                    Button(role: .destructive) {
                        playlistToDelete = playlist
                        showDeleteConfirm = true
                    } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
    }

    // List layout
    private var playlistList: some View {
        List {
            ForEach(playlistVM.playlists) { playlist in
                NavigationLink(destination: PlaylistDetailView(playlist: playlist)) {
                    HStack(spacing: 12) {
                        PlaylistCoverImageView(playlist: playlist, side: 60) // smaller thumb here

                        VStack(alignment: .leading, spacing: 4) {
                            Text(playlist.name)
                                .font(.headline)
                                .foregroundColor(.primary)
                                .lineLimit(1)

                            Text("\(playlist.songIDs.count) song\(playlist.songIDs.count == 1 ? "" : "s")")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        playlistToDelete = playlist
                        showDeleteConfirm = true
                    } label: { Label("Delete", systemImage: "trash") }
                }
                .contextMenu {
                    Button("Edit") { editingPlaylist = playlist }
                    Button(role: .destructive) {
                        playlistToDelete = playlist
                        showDeleteConfirm = true
                    } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    var body: some View {
        Group {
            if viewMode == .grid {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("Your Playlists")
                            .font(.largeTitle.bold())
                            .padding(.horizontal)

                        playlistGrid
                    }
                    .padding(.horizontal)
                    .transition(.opacity.combined(with: .scale))
                    .animation(.easeInOut(duration: 0.3), value: viewMode)

                    // Extra scrollable space so MiniPlayer doesn't cover last rows
                    Spacer(minLength: 100)
                }
            } else {
                // List mode — no outer ScrollView to avoid nested scrolling
                VStack(alignment: .leading, spacing: 12) {
                    Text("Your Playlists")
                        .font(.largeTitle.bold())
                        .padding(.horizontal)
                    playlistList
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.3), value: viewMode)
                }
            }
        }
            
        .navigationTitle("Playlists")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        viewModeRaw = (viewMode == .grid)
                            ? PlaylistViewMode.list.rawValue
                            : PlaylistViewMode.grid.rawValue
                    }
                }) {
                    Image(systemName: viewMode == .grid ? "list.bullet" : "square.grid.2x2")
                        .imageScale(.large)
                        .foregroundColor(Color("appAccent"))
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showCreateSheet = true }) {
                    Label("New Playlist", systemImage: "plus").labelStyle(IconOnlyLabelStyle())
                }
            }
        }
        .confirmationDialog("Delete this playlist?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let p = playlistToDelete {
                    withAnimation { playlistVM.deletePlaylist(p) }
                    playlistToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) { playlistToDelete = nil }
        } message: {
            if let p = playlistToDelete {
                Text("\"\(p.name)\" will be removed from your library. This won’t delete any audio files.")
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
