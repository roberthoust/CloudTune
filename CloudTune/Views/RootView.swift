import SwiftUI

struct RootView: View {
    @EnvironmentObject var playbackVM: PlaybackViewModel
    @EnvironmentObject var importState: ImportState
    @EnvironmentObject var pro: ProStore

    @State private var showTrialEnded = false
    @State private var paywallReason: PaywallReason?

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView {
                LibraryView()
                    .tabItem {
                        Label("Library", systemImage: "music.note.list")
                    }

                SearchView()
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
        // Speed/pitch trial: checked whenever a song starts or speed/pitch changes, wherever
        // that happens (player, mini player, lock screen, next track).
        .onChange(of: playbackVM.currentSong?.id) { _, _ in enforceSpeedPitchAccess() }
        .onChange(of: playbackVM.playbackRate) { _, _ in enforceSpeedPitchAccess() }
        .onChange(of: playbackVM.pitchCents) { _, _ in enforceSpeedPitchAccess() }
        .alert("Free speed & pitch songs used", isPresented: $showTrialEnded) {
            Button("Unlock Pro") { paywallReason = .speedPitch }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Playback is back to normal speed. CloudTune Pro unlocks speed & pitch for every song.")
        }
        .sheet(item: $paywallReason) { reason in
            PaywallView(reason: reason)
        }
    }

    private func enforceSpeedPitchAccess() {
        guard playbackVM.hasCustomSpeedOrPitch, let songID = playbackVM.currentSong?.id else { return }
        if pro.canUseSpeedPitch(on: songID) {
            pro.noteSpeedPitchUse(on: songID)
        } else {
            playbackVM.resetSpeedAndPitch()
            showTrialEnded = true
        }
    }
}
