import SwiftUI

@main
struct CloudTuneApp: App {
    @StateObject private var libraryVM = LibraryViewModel()
    @StateObject private var playbackVM = PlaybackViewModel()
    @StateObject private var playlistVM = PlaylistViewModel()
    @StateObject private var importState = ImportState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(libraryVM)
                .environmentObject(playbackVM)
                .environmentObject(playlistVM)
                .environmentObject(importState)
                .tint(Color.appAccent)
        }
    }
}
