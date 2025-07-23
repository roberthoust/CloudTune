// Finalized PlaybackViewModel.swift – delegates all playback & seeking to EQManager

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

    var songQueue: [Song] {
        isShuffle ? shuffledQueue : originalQueue
    }

    private var timer: Timer?
    private var playbackStartTime: TimeInterval = 0

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
        stop(clearSong: false)

        if queue != originalQueue {
            originalQueue = queue
            shuffledQueue = queue.shuffled()
        }

        currentIndex = songQueue.firstIndex(of: song) ?? 0
        currentSong = song
        currentContextName = contextName

        do {
            try EQManager.shared.start()
            try EQManager.shared.play(song: song) {}
            duration = song.duration ?? 0
            currentTime = 0
            playbackStartTime = Date().timeIntervalSince1970

            isPlaying = true
            startTimer()
            updateNowPlayingInfo(for: song)
        } catch {
            print("❌ Failed to play with EQManager: \(error.localizedDescription)")
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
        guard let _ = currentSong else { return }

        let clampedTime = max(0, min(time, duration - 0.5))  // Avoid near-end skips

        do {
            try EQManager.shared.seek(to: clampedTime){}
            playbackStartTime = Date().timeIntervalSince1970 - clampedTime
            currentTime = clampedTime
            startTimer()
        } catch {
            print("❌ Seek failed: \(error.localizedDescription)")
        }
    }

    func skipForward() {
        if repeatMode == .repeatOne {
            play(song: songQueue[currentIndex], in: originalQueue, contextName: currentContextName)
            return
        }

        let nextIndex = currentIndex + 1
        if songQueue.indices.contains(nextIndex) {
            play(song: songQueue[nextIndex], in: originalQueue, contextName: currentContextName)
        } else if repeatMode == .repeatAll {
            play(song: songQueue.first!, in: originalQueue, contextName: currentContextName)
        }
    }

    func skipBackward() {
        let prevIndex = currentIndex - 1
        if songQueue.indices.contains(prevIndex) {
            play(song: songQueue[prevIndex], in: originalQueue, contextName: currentContextName)
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

    private func handleSongCompletion() {
        print("🎧 handleSongCompletion() triggered — index: \(currentIndex), repeatMode: \(repeatMode), queue count: \(songQueue.count)")

        if let song = currentSong {
            print("📀 Current song: \(song.title)")
        }

        if repeatMode == .repeatOne {
            print("🔁 Repeating current song.")
            play(song: currentSong!, in: originalQueue, contextName: currentContextName)
        } else if currentIndex + 1 < songQueue.count {
            print("⏭ Skipping to next song.")
            skipForward()
        } else if repeatMode == .repeatAll {
            print("🔄 Repeat all — starting from beginning.")
            play(song: songQueue.first!, in: originalQueue, contextName: currentContextName)
        } else {
            print("⏹ Reached end of queue. Stopping playback.")
            stop()
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
