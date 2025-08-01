import SwiftUI

struct RootView: View {
    @EnvironmentObject var playbackVM: PlaybackViewModel
    @EnvironmentObject var importState: ImportState

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView {
                LibraryView()
                    .tabItem {
                        Label("Library", systemImage: "music.note.list")
                    }

                Text("Search")
                    .tabItem {
                        Label("Search", systemImage: "magnifyingglass")
                    }

                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
            }
            .accentColor(AppTheme.accentColor)
            .disabled(importState.isImporting)
            .allowsHitTesting(!importState.isImporting)

            // ✅ Always include MiniPlayer if song exists
            if playbackVM.currentSong != nil {
                MiniPlayerView()
                    .padding(.horizontal)
                    .padding(.bottom, 60)
                    .transition(.move(edge: .bottom))
            }

            if importState.isImporting {
                Color.black.opacity(0.3).ignoresSafeArea()
            }
        }
        .fullScreenCover(isPresented: $playbackVM.showPlayer) {
            PlayerView()
                .environmentObject(playbackVM)
        }
        .animation(.easeInOut, value: playbackVM.currentSong)
    }
}
