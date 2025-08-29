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
            .background(Color("AppBackground").ignoresSafeArea())
            .fullScreenCover(isPresented: $isPresentingPlayer) {
                PlayerView()
                    .environmentObject(playbackVM)
            }
            // Initial fill + react to library changes
            .onAppear { results = libraryVM.songs }
            .onChange(of: libraryVM.songs) { newSongs, _ in
                if searchText.isEmpty { results = newSongs } else { debouncedSearch() }
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

        // Snapshot values to avoid racing with typing
        let query = searchText
        let corpus = libraryVM.songs

        // Launch a non-throwing async task (matches Task<Void, Never>)
        searchTask = Task { [query, corpus] in
            // Small debounce to avoid filtering on every keystroke
            _ = try? await Task.sleep(nanoseconds: 220_000_000) // 0.22s

            // If cancelled, bail without throwing
            if Task.isCancelled { return }

            // Fast path: empty query shows all
            guard !query.isEmpty else {
                await MainActor.run { results = corpus }
                return
            }

            // Lowercase once; filter off the main thread
            let q = query.lowercased()
            let filtered = await filterSongs(queryLowercased: q, in: corpus)

            // Publish back on main thread
            await MainActor.run { results = filtered }
        }
    }

    private func filterSongs(queryLowercased q: String, in songs: [Song]) async -> [Song] {
        // Run on a background executor
        await withTaskGroup(of: [Song].self) { group in
            // Chunk to keep big libraries smooth
            let chunkSize = 512
            for chunk in songs.chunked(into: chunkSize) {
                group.addTask {
                    var out: [Song] = []
                    out.reserveCapacity(chunk.count)
                    for s in chunk {
                        // Avoid allocating strings repeatedly
                        let title = s.displayTitle.lowercased()
                        let artist = s.displayArtist.lowercased()
                        if title.contains(q) || artist.contains(q) {
                            out.append(s)
                        }
                    }
                    return out
                }
            }

            var aggregate: [Song] = []
            for await part in group {
                aggregate.append(contentsOf: part)
            }
            return aggregate
        }
    }
}

// MARK: - Tiny helper
private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        var result: [[Element]] = []
        result.reserveCapacity((count + size - 1) / size)
        var i = startIndex
        while i < endIndex {
            let j = index(i, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(Array(self[i..<j]))
            i = j
        }
        return result
    }
}
