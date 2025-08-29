//
//  PlaybackViewModel.swift
//  CloudTune
//

import Foundation
import AVFoundation
import Combine
import MediaPlayer
import UIKit

enum RepeatMode {
    case off, repeatAll, repeatOne
}

class PlaybackViewModel: NSObject, ObservableObject {
    // 🔁 Engine that owns the player/graph.
    private let audio = AudioEngine()

    @Published var currentSong: Song?
    @Published var isPlaying: Bool = false
    @Published var showPlayer: Bool = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var shouldShowPlayer: Bool = false

    @Published var isShuffle: Bool = false
    @Published var repeatMode: RepeatMode = .off
    @Published var currentContextName: String?

    @Published var originalQueue: [Song] = []
    private var shuffledQueue: [Song] = []
    @Published var currentIndex: Int = -1

    @Published var songToAddToPlaylist: Song?
    @Published var showAddToPlaylistSheet: Bool = false

    private var timer: Timer?
    private var playbackStartTime: TimeInterval = 0

    // Track the currently active play() to filter stale completions
    private var playToken = UUID()

    // Track user seeks so we can ignore immediate "completion" callbacks that some engines emit
    private var lastSeekAt: TimeInterval = 0
    private let seekIgnoreWindow: TimeInterval = 1.0 // seconds

    // Keeps a security-scope open for the currently playing song's folder.
    private var stopSecurityScope: (() -> Void)?

    /// Returns true only for URLs that live *outside* our app sandbox and may need security scope.
    private func requiresSecurityScope(for url: URL) -> Bool {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!.standardizedFileURL.path
        let lib  = fm.urls(for: .libraryDirectory,  in: .userDomainMask).first!.standardizedFileURL.path
        let tmp  = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path

        // Only consider *your* app-group safe IF you actually have the entitlement.
        var myGroupPath: String? = nil
        if let groupID = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
           let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            myGroupPath = container.standardizedFileURL.path
        }

        // SAFE = inside Documents/Library/tmp or inside *your* entitled app group container
        let inSandbox =
            path.hasPrefix(docs) ||
            path.hasPrefix(lib)  ||
            path.hasPrefix(tmp)  ||
            (myGroupPath != nil && path.hasPrefix(myGroupPath!))

        print("🔎 requiresSecurityScope? \(!inSandbox) — path=\(path) docs=\(docs) lib=\(lib) tmp=\(tmp) myGroup=\(myGroupPath ?? "nil")")
        return !inSandbox
    }

    var songQueue: [Song] { isShuffle ? shuffledQueue : originalQueue }

    override init() {
        super.init()

        // Let the EQ UI control the engine's EQ node.
        EQManager.shared.attach(eq: audio.eq)

        // AudioEngine configures AVAudioSession internally; we just react here.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

            switch type {
            case .began:
                self.audio.pause()
                self.isPlaying = false
            case .ended:
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                    self.audio.resume()
                    self.isPlaying = true
                } catch {
                    print("❌ Failed to reactivate audio session after interruption: \(error)")
                }
            @unknown default:
                break
            }
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { notification in
            print("Audio session route change notification: \(notification)")
        }

        setupRemoteCommandCenter()
    }

    // MARK: - Playback control

    func play(song: Song, in queue: [Song] = [], contextName: String? = nil) {
        // 0) If a new song (different URL) is chosen, stop current playback cleanly
        // Close any previous folder security-scope when switching songs.
        stopSecurityScope?()
        stopSecurityScope = nil

        if currentSong?.url != song.url {
            audio.stop()
        }

        // 1) Use the EXACT order provided by caller (SongsView/Album/Playlist)
        let incoming = queue.isEmpty ? [song] : queue
        let reorderedQueue = incoming

        // 2) Rebuild indices
        if reorderedQueue != originalQueue {
            if let idx = reorderedQueue.firstIndex(of: song) {
                currentIndex = idx
            } else {
                currentIndex = 0
            }
            originalQueue = reorderedQueue
            shuffledQueue = reorderedQueue.shuffled()
        } else {
            if let idx = songQueue.firstIndex(of: song) {
                currentIndex = idx
            } else {
                currentIndex = 0
            }
        }

        currentSong = songQueue[currentIndex]
        currentContextName = contextName

        // 🔊 DEBUG BANNER
        if let s = currentSong {
            print("""
            🎵 Now Playing
               Title:  \(s.title)
               Artist: \(s.artist)
               Album:  \(s.album)
               Track#: \(s.trackNumber ?? 0)  •  Duration: \(String(format: "%.1f sec", s.duration))
            """)
        }

        // 2.5) ✅ Ensure scope is alive for the folder containing this song.
        if let s = currentSong {
            if requiresSecurityScope(for: s.url) {
                if SecurityScopeKeeper.shared.ensureScope(forParentOf: s.url) {
                    print("🔐 Using existing security-scope for: \(s.url.deletingLastPathComponent().lastPathComponent)")
                } else {
                    print("⚠️ External location without matching active scope. Playback may fail.")
                }
            } else {
                print("🏠 In-app file — security scope not required.")
            }
        }

        // 3) Start playback using AudioEngine
        duration = currentSong?.duration ?? 0
        currentTime = 0
        isPlaying = true
        playbackStartTime = Date().timeIntervalSince1970
        lastSeekAt = 0 // reset any old seek marker
        startTimer()
        if let s = currentSong { updateNowPlayingInfo(for: s) }

        // 🔏 New token for this play()
        playToken = UUID()
        let tokenForThisPlay = playToken

        audio.play(url: currentSong!.url, id: tokenForThisPlay) { [weak self] in
            guard let self = self else { return }

            // Ignore completions from previous plays
            guard tokenForThisPlay == self.playToken else {
                print("⤬ Completion from stale play token — ignored.")
                return
            }

            // Ignore completions that fire immediately after a seek
            let now = Date().timeIntervalSince1970
            if now - self.lastSeekAt < self.seekIgnoreWindow {
                print("⏸️ Completion ignored — within \(self.seekIgnoreWindow)s of a seek.")
                return
            }

            guard self.isPlaying else {
                print("🛑 Completion ignored — playback already stopped.")
                return
            }
            self.handleSongCompletion()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.shouldShowPlayer = true
        }
    }

    func togglePlayPause() {
        if isPlaying {
            audio.pause()
            isPlaying = false
        } else {
            audio.resume()
            playbackStartTime = Date().timeIntervalSince1970 - currentTime
            isPlaying = true
        }
        updateNowPlayingPlaybackState()
    }

    func stop(clearSong: Bool = true) {
        audio.stop()
        // Close any active security scope for the current song's folder.
        stopSecurityScope?()
        stopSecurityScope = nil

        // Invalidate token so late completions from the engine are ignored
        playToken = UUID()

        timer?.invalidate()
        timer = nil
        isPlaying = false
        currentTime = 0
        duration = 0

        if clearSong {
            currentSong = nil
            showPlayer = false
            currentContextName = nil
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func seek(to time: Double) {
        guard currentSong != nil else { return }

        let clampedTime = max(0, min(time, duration > 0 ? duration - 0.5 : time))

        // Mark the moment of user seek so we can ignore spurious completion callbacks
        lastSeekAt = Date().timeIntervalSince1970

        audio.seek(to: clampedTime) { [weak self] in
            print("✅ seek(to:) completion handler fired")
            self?.updateNowPlayingElapsedTime()
        }

        playbackStartTime = Date().timeIntervalSince1970 - clampedTime
        currentTime = clampedTime
        startTimer()
    }

    func skipForward() {
        stop(clearSong: false)

        if repeatMode == .repeatOne {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.play(song: self.songQueue[self.currentIndex], in: self.originalQueue, contextName: self.currentContextName)
            }
            return
        }

        let nextIndex = currentIndex + 1
        if songQueue.indices.contains(nextIndex) {
            currentIndex = nextIndex
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.play(song: self.songQueue[nextIndex], in: self.originalQueue, contextName: self.currentContextName)
            }
        } else if repeatMode == .repeatAll {
            currentIndex = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.play(song: self.songQueue[0], in: self.originalQueue, contextName: self.currentContextName)
            }
        }
    }

    func skipBackward() {
        stop(clearSong: false)

        let prevIndex = currentIndex - 1
        if songQueue.indices.contains(prevIndex) {
            currentIndex = prevIndex
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.play(song: self.songQueue[prevIndex], in: self.originalQueue, contextName: self.currentContextName)
            }
        } else if repeatMode == .repeatAll {
            currentIndex = songQueue.count - 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.play(song: self.songQueue[self.currentIndex], in: self.originalQueue, contextName: self.currentContextName)
            }
        }
    }

    func toggleShuffle() {
        isShuffle.toggle()
        if isShuffle {
            shuffledQueue = originalQueue
            // Fisher-Yates shuffle (keep current song at index 0)
            for i in stride(from: shuffledQueue.count - 1, through: 1, by: -1) {
                let j = Int.random(in: 0...i)
                shuffledQueue.swapAt(i, j)
            }
            if let current = currentSong, let idx = shuffledQueue.firstIndex(of: current) {
                shuffledQueue.swapAt(0, idx)
                currentIndex = 0
            }
        } else {
            if let current = currentSong {
                currentIndex = originalQueue.firstIndex(of: current) ?? 0
            }
        }
    }

    func toggleRepeatMode() {
        switch repeatMode {
        case .off:
            repeatMode = .repeatAll
            print("🔁 Repeat mode set to: Repeat All")
        case .repeatAll:
            repeatMode = .repeatOne
            print("🔂 Repeat mode set to: Repeat One")
        case .repeatOne:
            repeatMode = .off
            print("⏹ Repeat mode set to: Off")
        }
    }

    // MARK: - Completion handling

    private func handlePlaybackCompletion() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Ignore ultra-early completions (engine priming etc.)
            if Date().timeIntervalSince1970 - self.playbackStartTime < 0.5 {
                print("⏸️ Ignoring ultra-early completion (<0.5s since start).")
                return
            }
            guard self.isPlaying else {
                print("🛑 Completion ignored — playback already stopped.")
                return
            }
            self.handleSongCompletion()
        }
    }

    private func handleSongCompletion() {
        guard songQueue.indices.contains(currentIndex) else {
            print("❌ Invalid index, stopping.")
            stop()
            return
        }

        print("🎧 handleSongCompletion() — currentIndex: \(currentIndex)")

        switch repeatMode {
        case .repeatOne:
            print("🔁 Repeating current song.")
            play(song: songQueue[currentIndex], in: originalQueue, contextName: currentContextName)

        case .repeatAll:
            if currentIndex + 1 < songQueue.count {
                print("⏭ Moving to next song.")
                currentIndex += 1
                play(song: songQueue[currentIndex], in: originalQueue, contextName: currentContextName)
            } else {
                print("🔄 Repeating from start.")
                currentIndex = 0
                play(song: songQueue[0], in: originalQueue, contextName: currentContextName)
            }

        case .off:
            if currentIndex + 1 < songQueue.count {
                print("⏭ Moving to next song.")
                currentIndex += 1
                play(song: songQueue[currentIndex], in: originalQueue, contextName: currentContextName)
            } else {
                print("⏹ End of queue.")
                stop()
            }
        }
    }

    // MARK: - Now Playing / Timer

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let elapsed = Date().timeIntervalSince1970 - self.playbackStartTime
            self.currentTime = min(elapsed, self.duration)
            self.updateNowPlayingElapsedTime()
        }
    }

    private func updateNowPlayingInfo(for song: Song) {
        var nowPlayingInfo: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]

        if let data = song.artwork, let image = UIImage(data: data) {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    private func updateNowPlayingPlaybackState() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingElapsedTime() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
    }

    private func setupRemoteCommandCenter() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.skipForward(); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.skipBackward(); return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime); return .success
        }
    }
}
