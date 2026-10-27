import SwiftUI

struct SearchView: View {
    @EnvironmentObject var playbackVM: PlaybackViewModel
    @EnvironmentObject var libraryVM: LibraryViewModel

    @State private var searchText = ""
    @State private var isPresentingPlayer = false

    // What we actually render
    @State private var results: [Song] = []

    // For cancelable debounce
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                header

                ScrollView {
                    LazyVStack(spacing: 22) {
                        ForEach(results) { song in
                            SongRow(song: song)                // <-- relies on @EnvironmentObject inside SongRow
                                .environmentObject(playbackVM)
                                .environmentObject(libraryVM)
                                .onTapGesture {
                                    if playbackVM.currentSong?.id == song.id {
                                        isPresentingPlayer = true
                                    } else {
                                        if let idx = results.firstIndex(of: song) {
                                            playbackVM.currentIndex = idx
                                        }
                                        playbackVM.play(song: song, in: results, contextName: "Search")
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                            isPresentingPlayer = true
                                        }
                                    }
                                }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 100)
                }

                Spacer(minLength: 0)
            }
            .padding(.top)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
            .fullScreenCover(isPresented: $isPresentingPlayer) {
                PlayerView()
                    .environmentObject(playbackVM)
            }
            // Initial fill + react to library changes
            .onAppear { results = libraryVM.songs }
            .onChange(of: libraryVM.songsVersion) { _, _ in
                if searchText.isEmpty { results = libraryVM.songs } else { debouncedSearch() }
            }
            // Debounced background filtering
            .onChange(of: searchText) { _, _ in debouncedSearch() }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            Text("Search Songs")
                .font(.largeTitle.bold())
                .padding(.horizontal)
            Spacer()
        }
    }

    // MARK: - Search

    private func debouncedSearch() {
        // Cancel any in-flight task
        searchTask?.cancel()

        // Snapshot the query to avoid racing with typing
        let query = searchText

        searchTask = Task {
            // Small debounce to avoid searching on every keystroke
            _ = try? await Task.sleep(nanoseconds: 220_000_000) // 0.22s
            if Task.isCancelled { return }

            // Fast path: empty query shows all
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                results = libraryVM.songs
                return
            }

            // The database matches title, artist and album, ignoring case and accents
            let found = await libraryVM.searchSongs(query)
            if !Task.isCancelled { results = found }
        }
    }
}

