import SwiftUI

struct SearchView: View {
    @EnvironmentObject var playbackVM: PlaybackViewModel
    @EnvironmentObject var libraryVM: LibraryViewModel

    @State private var searchText = ""
    @State private var isPresentingPlayer: Bool = false

    var filteredSongs: [Song] {
        if searchText.isEmpty {
            return libraryVM.songs
        } else {
            return libraryVM.songs.filter { song in
                song.displayTitle.lowercased().contains(searchText.lowercased()) ||
                song.displayArtist.lowercased().contains(searchText.lowercased())
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack {
                    Text("Search Songs")
                        .font(.largeTitle.bold())
                        .padding(.horizontal)
                    Spacer()
                }

                ScrollView {
                    LazyVStack(spacing: 22) {
                        ForEach(filteredSongs) { song in
                            SongRow(song: song, libraryVM: libraryVM)
                                .environmentObject(playbackVM)
                                .onTapGesture {
                                    if playbackVM.currentSong?.id == song.id {
                                        isPresentingPlayer = true
                                    } else {
                                        if let index = filteredSongs.firstIndex(of: song) {
                                            playbackVM.currentIndex = index
                                        }
                                        playbackVM.play(song: song, in: filteredSongs, contextName: "Search")
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

                Spacer()
            }
            .padding(.top)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
            .background(Color("AppBackground").ignoresSafeArea())
            .fullScreenCover(isPresented: $isPresentingPlayer) {
                PlayerView()
                    .environmentObject(playbackVM)
            }
        }
    }
}
