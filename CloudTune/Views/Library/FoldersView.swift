//
//  FoldersView.swift
//  CloudTune
//
//  Created by Robert Houst on 9/1/25.
//

import SwiftUI
import UIKit

// MARK: - Artwork view
private struct FolderArtwork: View {
    let artworkID: String?
    let side: CGFloat

    var body: some View {
        ArtworkThumbView(artworkID: artworkID)
            .frame(width: side, height: side)
            .cornerRadius(side * 0.1)
            .clipped()
    }
}

// MARK: - FoldersView
struct FoldersView: View {
    @EnvironmentObject var libraryVM: LibraryViewModel

    @State private var isGridView = true
    @State private var groups: [(folder: URL, songs: [Song])] = []

    private let grid = [
        GridItem(.flexible(), spacing: 20),
        GridItem(.flexible(), spacing: 20)
    ]

    var body: some View {
        VStack {
            // Top-right toggle button (same behavior/feel as Albums)
            HStack {
                Spacer()
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isGridView.toggle()
                    }
                }) {
                    Image(systemName: isGridView ? "list.bullet" : "square.grid.2x2")
                        .imageScale(.large)
                        .foregroundColor(Color("appAccent"))
                }
                .padding(.trailing, 20)
            }

            ScrollView {
                if isGridView {
                    LazyVGrid(columns: grid, spacing: 24) {
                        folderItems
                    }
                    .transition(.opacity.combined(with: .scale))
                    .animation(.easeInOut(duration: 0.3), value: isGridView)
                } else {
                    LazyVStack(spacing: 16) {
                        folderItems
                    }
                    .padding(.horizontal, 12)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: isGridView)
                }
                Spacer(minLength: 100) // extra scroll space so MiniPlayer doesn't overlap folder names
            }
            .padding(.top, 6)
            .onAppear { rebuildGroups() }
            .onChange(of: libraryVM.savedFolders) { _, _ in rebuildGroups() }
            .onChange(of: libraryVM.songs) { _, _ in rebuildGroups() }
        }
        .navigationTitle("Folders")
        .tint(Color("appAccent"))
    }

    @ViewBuilder
    private var folderItems: some View {
        ForEach(groups, id: \.folder) { group in
            let firstArtwork = group.songs.first?.artworkID

            NavigationLink(destination: FolderDetailView(folder: group.folder, songs: group.songs)) {
                if isGridView {
                    VStack(spacing: 10) {
                        FolderArtwork(artworkID: firstArtwork, side: 140)

                        Text(group.folder.lastPathComponent)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundColor(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(width: 140)
                    }
                    .padding(.vertical, 6)
                    .frame(width: 160)
                    .contentShape(Rectangle())
                } else {
                    HStack {
                        FolderArtwork(artworkID: firstArtwork, side: 70)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.folder.lastPathComponent)
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .shadow(color: Color.primary.opacity(0.06), radius: 1, x: 0, y: 1)

                            Text("\(group.songs.count) item\(group.songs.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(.systemBackground).opacity(0.7))
                            .shadow(color: Color("appAccent").opacity(0.08), radius: 4, x: 0, y: 2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color("appAccent").opacity(0.11), lineWidth: 0.7)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                }
            }
            .tint(Color("appAccent"))
        }
    }

    private func rebuildGroups() {
        // Snapshot to avoid repeatedly touching @Published on a background thread.
        let folders = libraryVM.savedFolders
        let allSongs = libraryVM.songs

        Task.detached(priority: .utility) {
            // Build groups off-main for smoothness.
            // If your VM already has a songs(in:) helper, prefer that.
            var result: [(URL, [Song])] = []
            result.reserveCapacity(folders.count)

            // Fast path: map songs by parent folder (prefix match).
            // Uses Song.url (non-optional) for path prefix matching.
            for folder in folders {
                let prefix = folder.standardizedFileURL.path
                let items = allSongs.filter { song in
                    let songPath = song.url.standardizedFileURL.path
                    return songPath.hasPrefix(prefix)   
                }
                if !items.isEmpty {
                    result.append((folder, items))
                } else {
                    // Still show empty folder entry so user can drill-in
                    result.append((folder, []))
                }
            }

            // Stable sort by folder name
            result.sort { $0.0.lastPathComponent.localizedCaseInsensitiveCompare($1.0.lastPathComponent) == .orderedAscending }

            await MainActor.run {
                self.groups = result
            }
        }
    }
}
