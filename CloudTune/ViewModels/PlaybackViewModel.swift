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
            guard let self = self else { return }
            let elapsed = Date().timeIntervalSince1970 - self.playbackStartTime
            let clamped = min(elapsed, self.duration)
            if abs(clamped - self.lastPushedTime) >= 0.25 {
                self.lastPushedTime = clamped
                DispatchQueue.main.async {
                    self.currentTime = clamped
                    self.updateNowPlayingElapsedTimeThrottled()
                    self.updateNowPlayingPlaybackState()
                }
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
        let rate = isPlaying ? 1.0 : 0.0
        let artHash = song.artwork?.hashValue ?? 0
        
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
        let rate = isPlaying ? 1.0 : 0.0
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
