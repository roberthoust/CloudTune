// Finalized PlaybackViewModel.swift — safely handles seeking and playback completion

import Foundation
import AVFoundation
import Combine
import MediaPlayer
import UIKit

enum RepeatMode {
    case off, repeatAll, repeatOne
}

class PlaybackViewModel: NSObject, ObservableObject {
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

    private var currentPlaybackID: UUID?
    private var timer: Timer?
    private var playbackStartTime: TimeInterval = 0

    var songQueue: [Song] {
        isShuffle ? shuffledQueue : originalQueue
    }

    override init() {
        super.init()
        configureAudioSession()
        setupRemoteCommandCenter()
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            print("❌ Failed to set audio session: \(error.localizedDescription)")
        }
    }

    func play(song: Song, in queue: [Song] = [], contextName: String? = nil) {
        if currentSong?.url != song.url {
            EQManager.shared.stop()
        }

        if queue != originalQueue {
            originalQueue = queue
            shuffledQueue = queue.shuffled()
        }

        currentSong = song
        currentContextName = contextName

        if let index = songQueue.firstIndex(of: song) {
            currentIndex = index
        } else {
            currentIndex = 0
        }

        print("▶️ Now playing index \(currentIndex) of \(songQueue.count): \(song.title) — \(song.artist)")

        EQManager.shared.stop()  // Always stop previous playback first
        let playbackID = UUID()
        self.currentPlaybackID = playbackID

        do {
            try EQManager.shared.start()

            try EQManager.shared.play(song: song, id: playbackID) { [weak self] completedID in
                guard let self = self else { return }
                guard self.currentPlaybackID == completedID else {
                    print("⏭ Ignored completion from stale playback.")
                    return
                }
                print("🎧 PlaybackViewModel received completion")
                self.handlePlaybackCompletion()
            }

            duration = song.duration ?? 0
            currentTime = 0
            isPlaying = true
            playbackStartTime = Date().timeIntervalSince1970
            startTimer()
            updateNowPlayingInfo(for: song)
        } catch {
            print("❌ Playback failed: \(error)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.shouldShowPlayer = true
        }
    }

    func togglePlayPause() {
        if isPlaying {
            EQManager.shared.pause()
            isPlaying = false
        } else {
            EQManager.shared.resume()
            playbackStartTime = Date().timeIntervalSince1970 - currentTime
            isPlaying = true
        }
        updateNowPlayingPlaybackState()
    }

    func stop(clearSong: Bool = true) {
        EQManager.shared.stop()
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

        let clampedTime = max(0, min(time, duration - 0.5))

        EQManager.shared.seek(to: clampedTime) {
            print("✅ seek(to:) completion handler fired")
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
        if let current = currentSong {
            currentIndex = songQueue.firstIndex(of: current) ?? 0
        }
    }

    func toggleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .repeatAll
        case .repeatAll: repeatMode = .repeatOne
        case .repeatOne: repeatMode = .off
        }
    }

    private func handlePlaybackCompletion() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
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
