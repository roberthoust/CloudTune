import SwiftUI
import UIKit
import Combine

// Reuse the same lightweight async thumb (no global cache redeclare).
@MainActor
private struct PlaylistThumb: View {
    let coverArtFilename: String?
    let side: CGFloat

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image("DefaultCover")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .redacted(reason: .placeholder)
                    .task { await decodeIfNeeded() }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.14, style: .continuous))
        .clipped()
    }

    private func decodeIfNeeded() async {
        guard let name = coverArtFilename else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent(name)

        let scale = UIScreen.main.scale
        let target = CGSize(width: side * scale, height: side * scale)

        let thumb: UIImage? = await Task.detached(priority: .utility) {
            guard let full = UIImage(contentsOfFile: url.path) else { return nil }
            let fmt = UIGraphicsImageRendererFormat.default()
            fmt.scale = 1
            let r = UIGraphicsImageRenderer(size: target, format: fmt)
            return r.image { _ in full.draw(in: CGRect(origin: .zero, size: target)) }
        }.value

        if let thumb { self.image = thumb }
    }
}

final class KeyboardFlag: ObservableObject {
    @Published var visible = false
    private var c = Set<AnyCancellable>()
    init() {
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
            .sink { [weak self] _ in self?.visible = true }.store(in: &c)
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
            .sink { [weak self] _ in self?.visible = false }.store(in: &c)
    }
}

struct AddToPlaylistSheet: View {
    let song: Song
    @Binding var selectedPlaylist: Playlist?

    @EnvironmentObject var playlistVM: PlaylistViewModel
    @Environment(\.dismiss) private var dismiss

    @StateObject private var kb = KeyboardFlag()

    @State private var searchText = ""
    @State private var debouncedQuery = ""
    @State private var showCreatePlaylist = false
    @State private var newlyCreatedPlaylist: Playlist?

    // Debounce typing to avoid full list reload every keystroke
    @State private var debounceWork: DispatchWorkItem?

    private var filteredPlaylists: [Playlist] {
        let q = debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return playlistVM.playlists }
        return playlistVM.playlists.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                // Title row
                HStack {
                    Text("Add to Playlist")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .imageScale(.large)
                            .foregroundColor(.secondary)
                    }
                    .accessibilityLabel("Close")
                }
                .padding(.horizontal)

                // Search (debounced)
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    PlainTextField(placeholder: "Search playlists…", text: $searchText) { newValue in
                        // keep your debounce here
                        debounceWork?.cancel()
                        let work = DispatchWorkItem { self.debouncedQuery = newValue }
                        debounceWork = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
                    }
                    .frame(height: 22) // visual height inside padded container
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
                .padding(.horizontal)

                // Create new (primary)
                Button {
                    let new = Playlist(name: "New Playlist", coverArtFilename: nil, songIDs: [song.id])
                    playlistVM.addPlaylist(new)
                    newlyCreatedPlaylist = new
                    selectedPlaylist = new
                    showCreatePlaylist = true
                } label: {
                    Label("Create New Playlist", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("appAccent"))
                .padding(.horizontal)

                // List
                List {
                    ForEach(filteredPlaylists) { playlist in
                        Button {
                            var updated = playlist
                            if !updated.songIDs.contains(song.id) {
                                updated.songIDs.append(song.id)
                                playlistVM.updatePlaylist(updated)
                            }
                            selectedPlaylist = updated
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                PlaylistThumb(coverArtFilename: playlist.coverArtFilename, side: 56)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(playlist.name)
                                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    Text("\(playlist.songIDs.count) song\(playlist.songIDs.count == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                if playlist.songIDs.contains(song.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(Color("appAccent"))
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        // When keyboard is visible, avoid heavy backgrounds/shadows
                        .listRowBackground(
                            kb.visible
                            ? AnyView(Color.clear)
                            : AnyView(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color(.systemBackground))
                                    // mild shadow looks nice but costs GPU; skip while typing
                                    .shadow(color: Color("appAccent").opacity(0.06), radius: 2, x: 0, y: 1)
                                    .padding(.vertical, 2)
                            )
                        )
                    }
                }
                .listStyle(.insetGrouped)
                .scrollDismissesKeyboard(.interactively)
                // Kill implicit animations during keyboard transitions
                .animation(.none, value: kb.visible)
                .transaction { tx in if kb.visible { tx.animation = nil } }
            }
            .padding(.top, 8)
            .tint(Color("appAccent"))
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .sheet(isPresented: $showCreatePlaylist) {
                if let playlist = newlyCreatedPlaylist {
                    PlaylistEditView(playlist: playlist)
                        .environmentObject(playlistVM)
                        .onDisappear { playlistVM.loadPlaylists() }
                }
            }
        }
        .ignoresSafeArea(.keyboard)
        // Also disable UIKit animations only while keyboard animates
        .onChange(of: kb.visible) { visible in
            UIView.setAnimationsEnabled(!visible)
            if !visible {
                // Re-enable on the next runloop to be safe
                DispatchQueue.main.async { UIView.setAnimationsEnabled(true) }
            }
        }
    }
}
