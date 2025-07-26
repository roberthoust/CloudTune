import SwiftUI

@main
struct CloudTuneApp: App {
    @StateObject private var libraryVM = LibraryViewModel()
    @StateObject private var playbackVM = PlaybackViewModel()
    @StateObject private var playlistVM = PlaylistViewModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(libraryVM)
                .environmentObject(playbackVM)
                .environmentObject(playlistVM)
                .tint(Color.appAccent) // ✅ Apply global accent color here
        }
    }
}
