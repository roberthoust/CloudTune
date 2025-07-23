import SwiftUI

@main
struct CloudTuneApp: App {
    @StateObject private var libraryVM = LibraryViewModel()
    @StateObject private var playbackVM = PlaybackViewModel()
    @StateObject private var playlistVM = PlaylistViewModel() // ✅ Add this

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(libraryVM)
                .environmentObject(playbackVM)
                .environmentObject(playlistVM) // ✅ Inject it here
        }
    }
}
