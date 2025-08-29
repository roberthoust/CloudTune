import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var libraryVM: LibraryViewModel
    @EnvironmentObject var importState: ImportState

    @State private var showFolderPicker = false
    @State private var showFolderManager = false

    var body: some View {
        ZStack {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {

                        // MARK: - Header
                        Text("Your Library")
                            .font(.system(size: 32, weight: .semibold, design: .rounded))
                            .padding(.horizontal)
                        if let vm = _libraryVM.wrappedValue as? LibraryViewModel,
                           !vm.songs.isEmpty || !vm.albums.isEmpty {
                            Group {
                                Text("\(libraryVM.songs.count) songs • \(libraryVM.albums.count) albums")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal)
                            }
                        }

                        // MARK: - Navigation Tiles (Vertical List)
                        VStack(spacing: 16) {
                            LibraryNavTile(title: "Songs", icon: "music.note", destination: SongsView())
                            LibraryNavTile(title: "Albums", icon: "rectangle.stack", destination: AlbumsView())
                            LibraryNavTile(title: "Playlists", icon: "text.badge.plus", destination: PlaylistScreen())
                        }
                        .padding(.horizontal)

                    }
                    .padding(.top)
                }
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Button("Import Folder") {
                                showFolderPicker = true
                            }
                            Button("Import Song") {
                                // Future: Song picker logic
                            }
                            Button("Import from Cloud") {
                                // Future: Trigger cloud import or paywall
                            }
                            .disabled(true)
                        } label: {
                            Label("Add", systemImage: "plus")
                                .labelStyle(IconOnlyLabelStyle())
                                .padding(10)
                                .background(Color.appAccent.opacity(0.1))
                                .clipShape(Circle())
                        }
                    }
                }
                .sheet(isPresented: $showFolderPicker) {
                    FolderPicker { folderURL in
                        showFolderPicker = false
                        Task {
                            await MainActor.run { importState.isImporting = true }
                            await libraryVM.importAndEnrich(folderURL)
                            await MainActor.run { importState.isImporting = false }
                        }
                    }
                    .interactiveDismissDisabled(importState.isImporting)
                }
            }
            if importState.isImporting {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.5)
                        Text("Importing…")
                            .foregroundColor(.white)
                            .font(.headline)
                        Text("Please wait while we process your files.")
                            .foregroundColor(.white)
                            .font(.footnote)
                    }
                    .padding()
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(12)
                }
            }
        }
        .disabled(importState.isImporting)
        .allowsHitTesting(!importState.isImporting)
    }
}

// MARK: - Modern/Futuristic Nav Tile
struct LibraryNavTile<Destination: View>: View {
    let title: String
    let icon: String
    let destination: Destination

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.appAccent.opacity(0.2))
                        .frame(width: 60, height: 60)
                        .shadow(color: Color.appAccent.opacity(0.3), radius: 6, x: 0, y: 2)

                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundColor(Color.appAccent)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("Browse \(title.lowercased())")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundColor(.gray)
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(16)
            .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
        }
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}
