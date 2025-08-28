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
    // 🔁 New engine that owns the player/graph.
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

    var songQueue: [Song] { isShuffle ? shuffledQueue : originalQueue }

    override init() {
        super.init()
        
        EQManager.shared.attach(eq: audio.eq)

        // AudioEngine already configures AVAudioSession internally.
        // We just react to interruptions and route changes.

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

        // Optional debug
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
        // If switching tracks, stop previous playback first.
        if currentSong?.url != song.url {
            audio.stop()
        }

        // Order queue (by trackNumber when available)
        let reorderedQueue: [Song]
        if queue.allSatisfy({ $0.trackNumber > 0 }) {
            reorderedQueue = queue.sorted { $0.trackNumber < $1.trackNumber }
        } else {
            reorderedQueue = queue
        }

        if reorderedQueue != originalQueue {
            currentIndex = reorderedQueue.firstIndex(of: song) ?? 0
            originalQueue = reorderedQueue
            shuffledQueue = reorderedQueue.shuffled()
        } else {
            originalQueue = queue
            shuffledQueue = queue.shuffled()
            currentIndex = songQueue.firstIndex(of: song) ?? 0
        }

        currentSong = songQueue[currentIndex]
        currentContextName = contextName

        print("▶️ Now playing index \(currentIndex) of \(songQueue.count): \(currentSong?.title ?? "nil") — \(currentSong?.artist ?? "nil")")

        // Start playback via AudioEngine
        let start = Date().timeIntervalSince1970
        guard let url = currentSong?.url else { return }

        audio.play(url: url) { [weak self] in
            guard let self = self else { return }

            // Guard against spurious super-early completions (rare race)
            let elapsed = Date().timeIntervalSince1970 - start
            if elapsed < 0.5 {
                print("⚠️ Playback completion too soon (\(elapsed)s) — ignoring.")
                return
            }

            print("🎧 PlaybackViewModel received completion")
            self.handlePlaybackCompletion()
        }

        duration = currentSong?.duration ?? 0
        currentTime = 0
        isPlaying = true
        playbackStartTime = Date().timeIntervalSince1970
        startTimer()
        if let s = currentSong { updateNowPlayingInfo(for: s) }

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
            // Fisher-Yates shuffle (with current song kept at index 0)
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
