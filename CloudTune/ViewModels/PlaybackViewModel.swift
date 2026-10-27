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
    private let audio = AudioEngine.shared
    
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

    // MARK: - Speed / Pitch

    /// Playback speed multiplier. 1.0 = normal.
    /// UI range: 0.2x (5x slower) ... 5.0x (5x faster)
    @Published var playbackRate: Float = 1.0 {
        didSet {
            audio.setPlaybackRate(playbackRate)

            // Optional: “tape” mode — changing speed also changes pitch.
            if linkSpeedToPitch {
                applyLinkedPitchFromRate()
            }

            updateNowPlayingPlaybackState()
        }
    }

    /// When enabled, playbackRate drives pitch using the musical relationship:
    /// pitchCents = 1200 * log2(rate)
    /// Example: rate 0.5 → -1200 cents (−12 semitones)
    @Published var linkSpeedToPitch: Bool = true {
        didSet {
            if linkSpeedToPitch {
                applyLinkedPitchFromRate()
            }
        }
    }

    /// Coarse pitch control in musical semitones.
    /// 1 semitone = 100 cents.
    @Published var semitones: Int = 0 {
        didSet {
            // In linked mode, semitones are derived from speed (tape behavior).
            guard !linkSpeedToPitch else { return }
            guard !isUpdatingPitchUI else { return }
            applyPitchFromUI()
        }
    }

    /// Fine pitch adjustment in cents (usually a small window like -50...+50).
    @Published var fineCents: Float = 0.0 {
        didSet {
            // In linked mode, fine cents are derived from speed (tape behavior).
            guard !linkSpeedToPitch else { return }
            guard !isUpdatingPitchUI else { return }
            applyPitchFromUI()
        }
    }

    /// Total pitch shift in cents. 0 = unchanged. (-1200 = -1 octave)
    /// This is what the audio engine ultimately consumes.
    @Published var pitchCents: Float = 0.0 {
        didSet {
            audio.setPitchCents(pitchCents)

            // If something else sets pitchCents directly (restore, preset, etc.),
            // keep semitones/fineCents in sync without creating feedback loops.
            guard !isUpdatingPitchUI else { return }
            syncPitchUIFromCents(pitchCents)
        }
    }

    /// Prevent feedback loops when we derive pitchCents from semitones/fineCents
    /// and when we derive semitones/fineCents from pitchCents.
    private var isUpdatingPitchUI: Bool = false

    /// Build `pitchCents` from the UI-friendly controls.
    /// Example: semitones = -3, fineCents = -25 => pitchCents = -325
    private func applyPitchFromUI() {
        // Manual pitch is disabled when speed drives pitch.
        guard !linkSpeedToPitch else { return }

        isUpdatingPitchUI = true
        pitchCents = Float(semitones) * 100 + fineCents
        isUpdatingPitchUI = false
    }

    /// Derive `semitones` and `fineCents` from a cents value.
    /// Uses truncation toward zero so `fineCents` stays within (-100, 100).
    private func syncPitchUIFromCents(_ cents: Float) {
        isUpdatingPitchUI = true
        let st = Int(cents / 100) // truncates toward zero
        let fine = cents - (Float(st) * 100)
        semitones = st
        fineCents = fine
        isUpdatingPitchUI = false
    }

    /// Compute tape-style pitch shift (in cents) for a given playback rate.
    /// pitchCents = 1200 * log2(rate)
    private func linkedPitchCents(for rate: Float) -> Float {
        let r = max(0.01, rate) // safety: log2 requires > 0
        return Float(1200.0 * Foundation.log2(Double(r)))
    }

    /// Apply the tape-style pitch shift for the current playbackRate.
    /// Updates pitchCents and keeps semitones/fineCents in sync.
    private func applyLinkedPitchFromRate() {
        let cents = linkedPitchCents(for: playbackRate)

        // Avoid feedback loops with the pitch UI sync logic.
        isUpdatingPitchUI = true
        pitchCents = cents
        syncPitchUIFromCents(cents)
        isUpdatingPitchUI = false
    }

    @Published var songToAddToPlaylist: Song?
    @Published var showAddToPlaylistSheet: Bool = false
    
    private var timer: Timer?
    private var playbackStartTime: TimeInterval = 0
    
    // Track the currently active play() to filter stale completions
    private var playToken = UUID()
    
    // Track user seeks so we can ignore immediate "completion" callbacks that some engines emit
    private var lastSeekAt: TimeInterval = 0
    private let seekIgnoreWindow: TimeInterval = 1.0 // seconds
    
    // Now Playing dedup/throttle
    private struct NowPlayingSignature: Equatable {
        let title: String
        let artist: String
        let duration: Double
        let elapsed: Double
        let rate: Double
        let artworkHash: Int
    }
    private var lastNPSignature: NowPlayingSignature?
    private var lastNPStateElapsed: Double = -1
    private var lastNPStateRate: Double = -1
    
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
        
        return !inSandbox
    }
    
    var songQueue: [Song] { isShuffle ? shuffledQueue : originalQueue }
    
    override init() {
        super.init()
        
        // Let the EQ UI control the engine's EQ node.
        EQManager.shared.attach(eq: audio.eq)
        
        // AudioEngine owns interruption / route-change handling (it knows the exact
        // position to resume from); we just mirror the resulting play state.
        audio.onSystemPlaybackChange = { [weak self] playing in
            guard let self, self.currentSong != nil else { return }
            self.isPlaying = playing
            if playing { self.playbackStartTime = Date().timeIntervalSince1970 - self.currentTime }
            self.updateNowPlayingElapsedTime()
            self.updateNowPlayingPlaybackState()
        }

        setupRemoteCommandCenter()
    }
    
    // MARK: - Playback control
    
    func play(song: Song, in queue: [Song] = [], contextName: String? = nil) {
        stopSecurityScope?()
        stopSecurityScope = nil
        
        if currentSong?.url != song.url {
            audio.stop()
        }
        
        let incoming = queue.isEmpty ? [song] : queue
        let reorderedQueue = incoming
        
        let isSameQueue = (reorderedQueue == originalQueue)
        if !isSameQueue { originalQueue = reorderedQueue }
        
        if isShuffle {
            if !isSameQueue || shuffledQueue.isEmpty {
                var rest = originalQueue
                if let sel = rest.firstIndex(of: song) {
                    let selected = rest.remove(at: sel)
                    shuffledQueue = [selected] + rest.shuffled()
                } else {
                    shuffledQueue = originalQueue.shuffled()
                    if let idx = shuffledQueue.firstIndex(of: song) {
                        shuffledQueue.swapAt(0, idx)
                    }
                }
                currentIndex = 0
            } else {
                currentIndex = shuffledQueue.firstIndex(of: song) ?? 0
            }
        } else {
            currentIndex = originalQueue.firstIndex(of: song) ?? 0
        }
        
        currentSong = songQueue[currentIndex]
        currentContextName = contextName
        
        if let s = currentSong {
            print("""
            🎵 Now Playing
               Title:  \(s.title)
               Artist: \(s.artist)
               Album:  \(s.album)
               Track#: \(s.trackNumber ?? 0)  •  Duration: \(String(format: "%.1f sec", s.duration))
            """)
        }
        
        if let s = currentSong {
            if requiresSecurityScope(for: s.url) {
                let parentName = s.url.deletingLastPathComponent().lastPathComponent
                if SecurityScopeKeeper.shared.ensureScope(forParentOf: s.url) {
                    print("🔐 Using existing security-scope for: \(parentName)")
                } else if BookmarkStore.shared.beginAccessIfBookmarked(parentOf: s.url) {
                    print("🔐 Started scope for: \(parentName)")
                    self.stopSecurityScope = { BookmarkStore.shared.endAccess(forFolderContaining: s.url) }
                } else {
                    print("⚠️ External location without bookmark/scope. Playback may fail.")
                }
            } else {
                print("🏠 In-app file — security scope not required.")
            }
        }
        
        duration = currentSong?.duration ?? 0
        currentTime = 0
        isPlaying = true
        playbackStartTime = Date().timeIntervalSince1970
        lastSeekAt = 0

        // Apply current speed/pitch settings for this playback session.
        // (Re-applying here ensures the engine matches UI after scheduling a new track.)
        audio.setPlaybackRate(playbackRate)

        // If speed is linked to pitch, ensure pitchCents reflects the current rate.
        if linkSpeedToPitch {
            applyLinkedPitchFromRate()
        }

        audio.setPitchCents(pitchCents)

        startTimer()
        if let s = currentSong { updateNowPlayingInfo(for: s) }
        
        playToken = UUID()
        let tokenForThisPlay = playToken
        
        audio.play(url: currentSong!.url, id: tokenForThisPlay) { [weak self] in
            guard let self = self else { return }
            guard tokenForThisPlay == self.playToken else { return }
            
            let now = Date().timeIntervalSince1970
            if now - self.lastSeekAt < self.seekIgnoreWindow { return }
            guard self.isPlaying else { return }
            
            self.handlePlaybackCompletion()
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
        stopSecurityScope?()
        stopSecurityScope = nil
        
        timerSrc?.cancel()
        timerSrc = nil
        
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
        
        let tailGuard: TimeInterval = 1.2
        if duration > 0, time >= duration - tailGuard {
            handleSongCompletion()
            return
        }
        
        let clampedTime = max(0, min(time, duration > 0 ? duration - tailGuard : time))
        let wasPlaying = isPlaying
        lastSeekAt = Date().timeIntervalSince1970
        
        audio.seek(to: clampedTime) { [weak self] in
            guard let self = self else { return }
            self.lastSeekAt = 0
            self.updateNowPlayingElapsedTime()
            self.updateNowPlayingPlaybackState()
        }
        
        playbackStartTime = Date().timeIntervalSince1970 - clampedTime
        currentTime = clampedTime
        if !wasPlaying { isPlaying = true }
        startTimer()
        updateNowPlayingPlaybackState()
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
        if currentTime > 3 {
            seek(to: 0)
            if !isPlaying {
                audio.resume()
                isPlaying = true
                updateNowPlayingPlaybackState()
            }
            return
        }
        
        stop(clearSong: false)
        
        if repeatMode == .repeatOne {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.play(song: self.songQueue[self.currentIndex], in: self.originalQueue, contextName: self.currentContextName)
            }
            return
        }
        
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
        } else {
            if let cur = currentSong {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.play(song: cur, in: self.originalQueue, contextName: self.currentContextName)
                }
            }
        }
    }
    
    func toggleShuffle() {
        isShuffle.toggle()
        
        guard let current = currentSong else {
            if isShuffle { shuffledQueue = originalQueue.shuffled() }
            return
        }
        
        if isShuffle {
            var rest = originalQueue.filter { $0 != current }
            rest.shuffle()
            shuffledQueue = [current] + rest
            currentIndex = 0
        } else {
            currentIndex = originalQueue.firstIndex(of: current) ?? 0
        }
    }
    
    func toggleRepeatMode() {
        switch repeatMode {
        case .off:
            repeatMode = .repeatAll
        case .repeatAll:
            repeatMode = .repeatOne
        case .repeatOne:
            repeatMode = .off
        }
    }
    
    // MARK: - Completion handling
    
    private func handlePlaybackCompletion() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if Date().timeIntervalSince1970 - self.playbackStartTime < 0.5 { return }
            guard self.isPlaying else { return }
            self.handleSongCompletion()
        }
    }
    
    private func handleSongCompletion() {
        guard songQueue.indices.contains(currentIndex) else {
            stop()
            return
        }
        
        switch repeatMode {
        case .repeatOne:
            play(song: songQueue[currentIndex], in: originalQueue, contextName: currentContextName)
        case .repeatAll:
            if currentIndex + 1 < songQueue.count {
                currentIndex += 1
                play(song: songQueue[currentIndex], in: originalQueue, contextName: currentContextName)
            } else {
                currentIndex = 0
                play(song: songQueue[0], in: originalQueue, contextName: currentContextName)
            }
        case .off:
            if currentIndex + 1 < songQueue.count {
                currentIndex += 1
                play(song: songQueue[currentIndex], in: originalQueue, contextName: currentContextName)
            } else {
                stop()
            }
        }
    }
    
    // MARK: - Now Playing / Timer
    
    private var timerSrc: DispatchSourceTimer?
    private var lastPushedTime: Double = -1
    
    private func startTimer() {
        timerSrc?.cancel()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Prefer the engine's clock: it tracks the real file position at any playback
                // rate and freezes while paused. Wall clock is only a fallback before audio starts.
                let elapsed = self.audio.currentPlaybackSeconds()
                    ?? (Date().timeIntervalSince1970 - self.playbackStartTime)
                let clamped = max(0, min(elapsed, self.duration))
                guard abs(clamped - self.lastPushedTime) >= 0.25 else { return }
                self.lastPushedTime = clamped
                self.currentTime = clamped
                self.updateNowPlayingElapsedTimeThrottled()
                self.updateNowPlayingPlaybackState()
            }
        }
        timerSrc = t
        t.resume()
    }
    
    private var lastNPUpdate: CFTimeInterval = 0
    private func updateNowPlayingElapsedTimeThrottled() {
        let now = CACurrentMediaTime()
        guard now - lastNPUpdate > 0.5 else { return }
        lastNPUpdate = now
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
    }
    
    private func updateNowPlayingInfo(for song: Song) {
        let title = song.title
        let artist = song.artist
        let dur = duration
        let elapsed = currentTime
        let rate = isPlaying ? Double(playbackRate) : 0.0
        let artHash = song.artworkID?.hashValue ?? 0

        let sig = NowPlayingSignature(title: title, artist: artist, duration: dur, elapsed: elapsed, rate: rate, artworkHash: artHash)
        if sig == lastNPSignature { return }
        lastNPSignature = sig

        var nowPlayingInfo: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyPlaybackDuration: dur,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: rate
        ]

        if let data = song.artwork, let image = UIImage(data: data) {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    private func updateNowPlayingPlaybackState() {
        let rate = isPlaying ? Double(playbackRate) : 0.0
        let elapsed = currentTime
        if rate == lastNPStateRate && elapsed == lastNPStateElapsed { return }
        lastNPStateRate = rate
        lastNPStateElapsed = elapsed
        
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    private func updateNowPlayingElapsedTime() {
        if currentTime == lastNPStateElapsed { return }
        lastNPStateElapsed = currentTime
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
