//
//  AudioEngine.swift
//  CloudTune
//
//  Created by Robert Houst on 8/28/25.
//

import AVFoundation

final class AudioEngine {
    static let shared = AudioEngine()

    // MARK: - Sandbox helper
    /// Returns true only for URLs that live *outside* our app sandbox and may need security scope.
    private func requiresSecurityScope(for url: URL) -> Bool {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!.standardizedFileURL.path
        let lib  = fm.urls(for: .libraryDirectory,  in: .userDomainMask).first!.standardizedFileURL.path
        let tmp  = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path

        var myGroupPath: String? = nil
        if let groupID = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
           let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            myGroupPath = container.standardizedFileURL.path
        }

        let inSandbox =
            path.hasPrefix(docs) ||
            path.hasPrefix(lib)  ||
            path.hasPrefix(tmp)  ||
            (myGroupPath != nil && path.hasPrefix(myGroupPath!))

        // Comment out if too chatty.
        print("🔎 requiresSecurityScope? \(!inSandbox) — path=\(path)")
        return !inSandbox
    }

    // MARK: Core nodes
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let eq = AVAudioUnitEQ(numberOfBands: 5)

    /// Time + pitch processor.
    /// - `rate`: playback speed (1.0 = normal)
    /// - `pitch`: cents (+/- 1200 = +/- 1 octave)
    let timePitch = AVAudioUnitTimePitch()

    // MARK: Playback state
    private var currentFile: AVAudioFile?
    private var playbackCompletion: (() -> Void)?
    private var activePlaybackID: UUID?

    // Position tracking: the player's sampleTime restarts at 0 every time we schedule,
    // so remember where the current segment starts in the file.
    private var segmentStartFrame: AVAudioFramePosition = 0
    private var lastKnownSeconds: TimeInterval = 0

    // Identifies the currently scheduled segment so completions from segments we
    // replaced (seek / recovery) don't get mistaken for end-of-track.
    private var segmentID = UUID()

    // Route-change / interruption recovery
    private var wasPlayingBeforeInterruption: Bool = false
    private var resumeSecondsBeforeInterruption: TimeInterval = 0

    /// Set when the engine was rebuilt while paused; `resume()` reschedules from here.
    private var pendingResumeSeconds: TimeInterval?

    /// Called on main when the system pauses or resumes playback
    /// (interruptions, headphones unplugged). `true` = now playing.
    var onSystemPlaybackChange: ((Bool) -> Void)?

    // MARK: - Time/Pitch smoothing
    // SwiftUI sliders can emit many updates per second while dragging.
    // If we jump rate/pitch instantly, you can hear "zippering" artifacts.
    // We ramp to the target over a short window to keep it sounding smooth.

    private var rateRampTimer: Timer?
    private var pitchRampTimer: Timer?

    private var rateRampFrom: Float = 1.0
    private var rateRampTo: Float = 1.0
    private var rateRampStartTime: CFTimeInterval = 0
    private var rateRampDuration: CFTimeInterval = 0.2

    private var pitchRampFrom: Float = 0.0
    private var pitchRampTo: Float = 0.0
    private var pitchRampStartTime: CFTimeInterval = 0
    private var pitchRampDuration: CFTimeInterval = 0.2

    // 🔐 Keep a security-scope alive for the currently opened file’s folder.
    private var currentScopeStopper: (() -> Void)?

    // Graph readiness
    private var isGraphReady = false
    private var readyCallbacks: [() -> Void] = []

    init() {
        configureSession()
        configureGraph { [weak self] in
            guard let self else { return }
            self.prepareAndStart()
            self.isGraphReady = true
            let pending = self.readyCallbacks
            self.readyCallbacks.removeAll()
            pending.forEach { $0() }
        }
        setupInterruptions()
        setupRouteChange()
    }

    // MARK: - Public controls

    /// Set playback speed. 1.0 = normal.
    /// Clamped to CloudTune UI limits: 0.2x (5x slower) … 5.0x (5x faster).
    func setPlaybackRate(_ rate: Float) {
        // AVAudioUnitTimePitch supports a broad range, but we clamp to the app’s design goal.
        let clamped = max(0.2, min(rate, 5.0))
        rampRate(to: clamped, duration: 0.20)
    }

    /// Immediate (non-ramped) speed set. Useful for hard resets or one-tap presets.
    func setPlaybackRateImmediate(_ rate: Float) {
        let clamped = max(0.2, min(rate, 5.0))
        rateRampTimer?.invalidate()
        rateRampTimer = nil
        timePitch.rate = clamped
        print("🎚️ timePitch.rate (immediate)=\(timePitch.rate)")
    }

    /// Set pitch shift in cents. 0 = unchanged.
    /// Typical useful range: -2400 … +2400.
    func setPitchCents(_ cents: Float) {
        let clamped = max(-2400, min(cents, 2400))
        rampPitch(to: clamped, duration: 0.20)
    }

    /// Immediate (non-ramped) pitch set. Useful for hard resets or one-tap presets.
    func setPitchCentsImmediate(_ cents: Float) {
        let clamped = max(-2400, min(cents, 2400))
        pitchRampTimer?.invalidate()
        pitchRampTimer = nil
        timePitch.pitch = clamped
        print("🎚️ timePitch.pitch (immediate)=\(timePitch.pitch)")
    }

    /// Convenience: reset to normal playback.
    func resetRateAndPitch() {
        // Reset should be snappy and deterministic.
        setPlaybackRateImmediate(1.0)
        setPitchCentsImmediate(0.0)
        print("🎚️ timePitch reset (rate=1.0, pitch=0)")
    }

    func play(url: URL, id: UUID = UUID(), completion: (() -> Void)? = nil) {
        whenReady { [weak self] in
            guard let self else { return }

            // Close scope for previous file (if any) before switching.
            self.currentScopeStopper?()
            self.currentScopeStopper = nil

            self.activePlaybackID = id
            self.playbackCompletion = completion

            self.player.stop()
            self.player.reset()
            print("▶️ AudioEngine.play(url: \(url.lastPathComponent))")

            // Open security scope for a bookmarked ancestor (only if needed).
            if self.requiresSecurityScope(for: url) {
                if BookmarkStore.shared.beginAccessIfBookmarked(parentOf: url) {
                    self.currentScopeStopper = {
                        BookmarkStore.shared.endAccess(forFolderContaining: url)
                        print("🛑 Scope released for: \(url.deletingLastPathComponent().lastPathComponent)")
                    }
                } else {
                    print("⚠️ No matching active bookmark for: \(url.path)")
                    self.currentScopeStopper = nil
                }
            } else {
                print("🏠 In-app file — security scope not required.")
                self.currentScopeStopper = nil
            }

            do {
                let file = try AVAudioFile(forReading: url)
                print("📖 Opened AVAudioFile. sampleRate=\(file.processingFormat.sampleRate) ch=\(file.processingFormat.channelCount) frames=\(file.length)")
                self.currentFile = file
                self.segmentStartFrame = 0
                self.lastKnownSeconds = 0
                self.pendingResumeSeconds = nil

                let startStamp = CACurrentMediaTime()
                let segment = UUID()
                self.segmentID = segment
                self.player.scheduleFile(file, at: nil) { [weak self] in
                    guard let self else { return }
                    guard self.activePlaybackID == id, self.segmentID == segment else { return }
                    // Ignore spurious "immediate" completions
                    if CACurrentMediaTime() - startStamp < 0.5 { return }
                    DispatchQueue.main.async { self.playbackCompletion?() }
                }

                if !self.engine.isRunning { try? self.engine.start() }
                print("🔊 Scheduling file & starting engine (running=\(self.engine.isRunning))")
                self.player.play()
            } catch {
                print("❌ AudioEngine.play failed for \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    func seek(to seconds: TimeInterval, completion: (() -> Void)? = nil) {
        whenReady { [weak self] in
            guard let self, let file = self.currentFile else { return }

            let sr = file.processingFormat.sampleRate
            let totalFrames = file.length
            let duration = Double(totalFrames) / sr
            print("⏩ seek(to: \(String(format: "%.3f", seconds)))")
            print("    file frames=\(totalFrames) sr=\(sr) duration=\(String(format: "%.3f", duration))")
            let clamped = max(0, min(seconds, duration))

            let startFrame = AVAudioFramePosition(clamped * sr)
            let framesLeft = AVAudioFrameCount(max(0, totalFrames - startFrame))
            print("    startFrame=\(startFrame) framesLeft=\(framesLeft)")

            // New segment ID first so the completion fired by stop() below is ignored.
            let segment = UUID()
            self.segmentID = segment

            self.player.stop()
            self.player.reset()
            file.framePosition = startFrame
            self.segmentStartFrame = startFrame
            self.lastKnownSeconds = clamped
            self.pendingResumeSeconds = nil

            // Keep same track identity and end-of-track completion.
            self.player.scheduleSegment(
                file,
                startingFrame: startFrame,
                frameCount: framesLeft,
                at: nil
            ) { [weak self] in
                guard let self else { return }
                DispatchQueue.main.async {
                    guard self.segmentID == segment else { return }
                    self.playbackCompletion?()
                }
            }

            if !self.engine.isRunning { try? self.engine.start() }
            self.player.play()

            // UI callback for seek completion.
            if let completion { DispatchQueue.main.async { completion() } }
        }
    }

    func pause()  { player.pause() }

    func resume() {
        guard currentFile != nil else { player.play(); return }

        if !engine.isRunning {
            // Engine was stopped under us (e.g. interruption): restart and reschedule.
            recoverAudio(resume: true, resumeSeconds: pendingResumeSeconds ?? currentPlaybackSeconds())
        } else if let s = pendingResumeSeconds {
            // Engine was rebuilt while paused, so nothing is scheduled anymore.
            seek(to: s)
        } else {
            player.play()
        }
        pendingResumeSeconds = nil
    }

    func stop() {
        player.stop()
        player.reset()
        print("⏹️ AudioEngine.stop()")
        // Stop any in-flight ramps so they don't keep mutating parameters.
        rateRampTimer?.invalidate(); rateRampTimer = nil
        pitchRampTimer?.invalidate(); pitchRampTimer = nil
        playbackCompletion = nil
        activePlaybackID = nil
        currentFile = nil
        segmentID = UUID()
        segmentStartFrame = 0
        lastKnownSeconds = 0
        pendingResumeSeconds = nil

        // Release scope now that the file is no longer used
        currentScopeStopper?()
        currentScopeStopper = nil
    }

    // MARK: - Smooth ramp helpers

    private func rampRate(to target: Float, duration: CFTimeInterval) {
        // If the graph isn't ready yet, set immediately (safe default).
        if !isGraphReady {
            timePitch.rate = target
            return
        }

        rateRampTimer?.invalidate()

        rateRampFrom = timePitch.rate
        rateRampTo = target
        rateRampStartTime = CACurrentMediaTime()
        rateRampDuration = max(0.05, duration)

        // ~60 Hz update.
        rateRampTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let now = CACurrentMediaTime()
            let u = (now - self.rateRampStartTime) / self.rateRampDuration

            if u >= 1.0 {
                self.timePitch.rate = self.rateRampTo
                t.invalidate()
                self.rateRampTimer = nil
                // Comment out if too chatty.
                // print("🎚️ timePitch.rate (ramped)=\(self.timePitch.rate)")
                return
            }

            // Linear interpolation is enough for audible smoothness.
            let v = self.rateRampFrom + Float(u) * (self.rateRampTo - self.rateRampFrom)
            self.timePitch.rate = v
        }

        // Ensure timer runs while scrolling/dragging.
        RunLoop.main.add(rateRampTimer!, forMode: .common)
    }

    private func rampPitch(to target: Float, duration: CFTimeInterval) {
        if !isGraphReady {
            timePitch.pitch = target
            return
        }

        pitchRampTimer?.invalidate()

        pitchRampFrom = timePitch.pitch
        pitchRampTo = target
        pitchRampStartTime = CACurrentMediaTime()
        pitchRampDuration = max(0.05, duration)

        pitchRampTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let now = CACurrentMediaTime()
            let u = (now - self.pitchRampStartTime) / self.pitchRampDuration

            if u >= 1.0 {
                self.timePitch.pitch = self.pitchRampTo
                t.invalidate()
                self.pitchRampTimer = nil
                // print("🎚️ timePitch.pitch (ramped)=\(self.timePitch.pitch)")
                return
            }

            let v = self.pitchRampFrom + Float(u) * (self.pitchRampTo - self.pitchRampFrom)
            self.timePitch.pitch = v
        }

        RunLoop.main.add(pitchRampTimer!, forMode: .common)
    }

    // MARK: - Route-change helpers

    /// Current position in the file (seconds), from the player node clock.
    /// The player's clock counts source frames, so this stays correct at any playback rate.
    /// Returns the last known position while paused; nil when nothing is loaded. Call on main.
    func currentPlaybackSeconds() -> TimeInterval? {
        guard let file = currentFile else { return nil }
        let sr = file.processingFormat.sampleRate
        guard sr > 0 else { return nil }

        if let nodeTime = player.lastRenderTime,
           let playerTime = player.playerTime(forNodeTime: nodeTime) {
            let frame = segmentStartFrame + max(0, playerTime.sampleTime)
            lastKnownSeconds = Double(min(frame, file.length)) / sr
        }
        return lastKnownSeconds
    }

    /// Restart the engine/session after a route change or interruption.
    /// If `resume` is true, seeks back to `resumeSeconds` and resumes playback;
    /// otherwise remembers the position so the next `resume()` picks up from there.
    private func recoverAudio(resume: Bool, resumeSeconds: TimeInterval?) {
        // Resetting the engine drops anything scheduled on the player; retire the old segment first.
        segmentID = UUID()

        let session = AVAudioSession.sharedInstance()

        // Keep session active across route changes.
        do {
            try session.setActive(true)
        } catch {
            print("❌ setActive(true) during recover failed: \(error.localizedDescription)")
        }

        // Route changes can stop or invalidate the engine render clock.
        // Restart cleanly.
        if engine.isRunning {
            engine.pause()
            engine.stop()
        }
        engine.reset()

        do {
            try engine.start()
            print("🔁 Engine restarted (running=\(engine.isRunning))")
        } catch {
            print("❌ Engine restart failed: \(error.localizedDescription)")
        }

        guard let s = resumeSeconds, currentFile != nil else { return }

        if resume {
            // Reschedule from the last known position; seek starts playback.
            seek(to: s)
        } else {
            pendingResumeSeconds = s
        }
    }

    // MARK: - Private setup

    private func whenReady(_ work: @escaping () -> Void) {
        if isGraphReady { work() } else { readyCallbacks.append(work) }
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()

        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        do {
            // Allow playback to route to Bluetooth/AirPlay.
            // - allowBluetoothA2DP: high quality stereo (music)
            // - allowBluetooth: supports HFP devices (lower quality but prevents drops)
            try session.setCategory(.playback, mode: .default, options: [.allowBluetooth, .allowBluetoothA2DP, .allowAirPlay])
        } catch {
            print("❌ setCategory(.playback) failed: \(error.localizedDescription)")
        }

        try? session.setPreferredSampleRate(48_000)
        try? session.setPreferredIOBufferDuration(0.010) // ~10ms

        do {
            try session.setActive(true)
        } catch {
            print("❌ setActive(true) failed: \(error.localizedDescription)")
        }

        let sr = session.sampleRate
        let dur = session.ioBufferDuration
        let route = session.currentRoute
        print("🎧 Session active. sr=\(sr)Hz io=\(Int(dur * 1000))ms route=\(route.outputs.first?.portType.rawValue ?? "unknown")")
    }

    private func configureGraph(onReady: @escaping () -> Void) {
        // Attach core nodes once
        [player, eq, timePitch].forEach(engine.attach)

        // Default time/pitch settings (neutral)
        timePitch.rate = 1.0
        timePitch.pitch = 0.0

        // Flat EQ bands; UI will adjust gains.
        let freqs: [Float] = [60, 250, 1000, 4000, 8000]
        for (i, f) in freqs.enumerated() where i < eq.bands.count {
            let b = eq.bands[i]
            b.filterType = .parametric
            b.frequency = f
            b.bandwidth = 0.5
            b.gain = 0
            b.bypass = false
        }

        let fmt = engine.outputNode.outputFormat(forBus: 0)

        // Graph: player → eq → timePitch → mainMixer
        engine.connect(player, to: eq, format: fmt)
        engine.connect(eq, to: timePitch, format: fmt)
        engine.connect(timePitch, to: engine.mainMixerNode, format: fmt)

        onReady()
    }

    private func prepareAndStart() {
        engine.prepare()
        try? engine.start()
        print("⚙️ Engine prepared & started (running=\(engine.isRunning))")
    }

    private func setupInterruptions() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] n in
            guard let self,
                  let info = n.userInfo,
                  let typeVal = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }

            switch type {
            case .began:
                self.wasPlayingBeforeInterruption = self.player.isPlaying
                self.resumeSecondsBeforeInterruption = self.currentPlaybackSeconds() ?? 0
                self.player.pause()
                if self.wasPlayingBeforeInterruption { self.onSystemPlaybackChange?(false) }

            case .ended:
                let optsVal = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let opts = AVAudioSession.InterruptionOptions(rawValue: optsVal)

                if opts.contains(.shouldResume), self.wasPlayingBeforeInterruption {
                    self.recoverAudio(resume: true, resumeSeconds: self.resumeSecondsBeforeInterruption)
                    self.onSystemPlaybackChange?(true)
                } else if self.currentFile != nil {
                    // Stay paused; the next resume() restarts from where we left off.
                    self.pendingResumeSeconds = self.resumeSecondsBeforeInterruption
                }

                self.wasPlayingBeforeInterruption = false
                self.resumeSecondsBeforeInterruption = 0

            @unknown default:
                break
            }
        }
    }

    private func setupRouteChange() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] n in
            guard let self else { return }

            let reasonRaw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = reasonRaw.flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }

            let wasPlaying = self.player.isPlaying
            let resumeAt = self.currentPlaybackSeconds()

            if let reason {
                print("🔌 Route change: \(reason)")
            } else {
                print("🔌 Route change")
            }

            // When output switches (e.g., Bluetooth connect), AVAudioEngine may keep 'playing'
            // but render silence. Restart and reschedule if we were playing.
            switch reason {
            case .oldDeviceUnavailable:
                // Headphones unplugged / Bluetooth disconnected: pause instead of
                // blasting out of the speaker (standard iOS behavior).
                self.player.pause()
                self.recoverAudio(resume: false, resumeSeconds: resumeAt)
                if wasPlaying { self.onSystemPlaybackChange?(false) }
            case .newDeviceAvailable, .categoryChange, .override, .routeConfigurationChange:
                self.recoverAudio(resume: wasPlaying, resumeSeconds: resumeAt)
            default:
                // Still ensure engine is running.
                if !self.engine.isRunning {
                    self.recoverAudio(resume: wasPlaying, resumeSeconds: resumeAt)
                }
            }
        }
    }

    deinit {
        currentScopeStopper?()
        currentScopeStopper = nil
        print("🧹 AudioEngine deinit — released any active scope")
    }
}
