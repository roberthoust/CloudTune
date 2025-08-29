//
//  AudioEngine.swift
//  CloudTune
//
//  Created by Robert Houst on 8/28/25.
//

import AVFoundation
import AudioToolbox   // for AudioComponentDescription & AU instantiate
import Accelerate     // vDSP peak scan for the guard tap

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

        print("🔎 requiresSecurityScope? \(!inSandbox) — path=\(path)")
        return !inSandbox
    }

    // MARK: Core nodes
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let eq = AVAudioUnitEQ(numberOfBands: 5)

    // Optional limiter (Apple Peak Limiter AU). It's async-loaded.
    private var limiterAU: AVAudioUnit?

    // MARK: Safe output (lawsuit guard)
    // We cap overall mixer volume and install a tiny “peak guard” tap.
    private let outputVolumeCap: Float = 0.82
    private var peakTapInstalled = false

    // MARK: Playback state
    private var currentFile: AVAudioFile?
    private var playbackCompletion: (() -> Void)?
    private var activePlaybackID: UUID?

    // 🔐 Keep a security-scope alive for the currently opened file’s folder.
    // We synthesize a stopper that calls BookmarkStore.endAccess(forFolderContaining:).
    private var currentScopeStopper: (() -> Void)?

    // Graph readiness (because limiter instantiation is async)
    private var isGraphReady = false
    private var readyCallbacks: [() -> Void] = []

    init() {
        configureSession()
        configureGraph { [weak self] in
            guard let self else { return }
            self.prepareAndStart()
            self.isGraphReady = true
            // Flush any queued work (e.g., play calls that arrived early)
            let pending = self.readyCallbacks
            self.readyCallbacks.removeAll()
            pending.forEach { $0() }
        }
        setupInterruptions()
        setupRouteChange()
    }

    // MARK: - Public controls

    func play(url: URL, id: UUID = UUID(), completion: (() -> Void)? = nil) {
        whenReady { [weak self] in
            guard let self else { return }

            // Close scope for the previous file (if any) before switching.
            self.currentScopeStopper?()
            self.currentScopeStopper = nil

            self.activePlaybackID = id
            self.playbackCompletion = completion

            self.player.stop()
            self.player.reset()
            print("▶️ AudioEngine.play(url: \(url.lastPathComponent))")

            // 🔑 Open security scope for a bookmarked ancestor folder (only if needed).
            if self.requiresSecurityScope(for: url) {
                if BookmarkStore.shared.beginAccessIfBookmarked(parentOf: url) {
                    // Scope is now ensured for the parent folder (may have been newly started or already active).
                    // We keep only the release log to avoid duplicate/noisy "scope acquired" messages.
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

                let startStamp = CACurrentMediaTime()
                self.player.scheduleFile(file, at: nil) { [weak self] in
                    guard let self else { return }
                    guard self.activePlaybackID == id else { return }
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

            self.player.stop()
            self.player.reset()
            file.framePosition = startFrame

            // ⚠️ Do NOT change activePlaybackID here; keep the same track identity
            // Reschedule with the ORIGINAL end-of-track completion
            self.player.scheduleSegment(file,
                                        startingFrame: startFrame,
                                        frameCount: framesLeft,
                                        at: nil) { [weak self] in
                guard let self else { return }
                // fire the stored end-of-track completion so autoplay still works
                DispatchQueue.main.async { self.playbackCompletion?() }
            }

            self.player.play()

            // Notify caller that the seek operation completed (UI update), immediately.
            if let completion { DispatchQueue.main.async { completion() } }
        }
    }

    func pause()  { player.pause() }
    func resume() { player.play()  }

    func stop() {
        player.stop()
        player.reset()
        print("⏹️ AudioEngine.stop()")
        playbackCompletion = nil
        activePlaybackID = nil
        currentFile = nil

        // 🔐 Release scope now that the file is no longer used
        currentScopeStopper?()
        currentScopeStopper = nil

        // keep engine running to avoid first-note glitch on next start
    }

    // MARK: - Private setup

    private func whenReady(_ work: @escaping () -> Void) {
        if isGraphReady { work() } else { readyCallbacks.append(work) }
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()

        // Deactivate before reconfiguring—avoids -50 from stale state.
        try? session.setActive(false, options: .notifyOthersOnDeactivation)

        do {
            // Plain playback category: most stable across routes
            try session.setCategory(.playback, mode: .default, options: [])
        } catch {
            print("❌ setCategory(.playback) failed: \(error.localizedDescription)")
        }

        // Preferences (not guarantees). Keep modest.
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
        [player, eq].forEach(engine.attach)

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

        // Try to insert Apple Peak Limiter (nice-to-have).
        instantiatePeakLimiter { [weak self] limiter in
            guard let self else { return }

            if let limiter {
                self.limiterAU = limiter
                self.engine.attach(limiter)

                self.engine.connect(self.player,  to: self.eq,      format: fmt)
                self.engine.connect(self.eq,      to: limiter,      format: fmt)
                self.engine.connect(limiter,      to: self.engine.mainMixerNode, format: fmt)
            } else {
                // Fallback path: player → eq → mixer
                self.engine.connect(self.player, to: self.eq, format: fmt)
                self.engine.connect(self.eq,     to: self.engine.mainMixerNode, format: fmt)
            }

            // ---- SAFETY GUARD (works everywhere) ----
            // 1) Hard cap the main mixer output (fixed multiplier)
            self.engine.mainMixerNode.outputVolume = min(self.engine.mainMixerNode.outputVolume, self.outputVolumeCap)
            // 2) Install a tiny peak detector that gently ducks on near-clips
            self.installPeakGuardTap()

            onReady()
        }
    }

    /// Instantiate Apple's Peak Limiter AU. Returns nil on failure.
    private func instantiatePeakLimiter(completion: @escaping (AVAudioUnit?) -> Void) {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        AVAudioUnit.instantiate(with: desc, options: []) { unit, error in
            if let unit {
                completion(unit)
            } else {
                if let error { print("⚠️ PeakLimiter AU instantiate failed: \(error.localizedDescription)") }
                completion(nil)
            }
        }
    }

    private func prepareAndStart() {
        engine.prepare()        // pre-alloc render resources
        try? engine.start()     // keep running to avoid first-note glitch
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
                self.player.pause()
            case .ended:
                let optsVal = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let opts = AVAudioSession.InterruptionOptions(rawValue: optsVal)
                if opts.contains(.shouldResume) { self.player.play() }
            @unknown default: break
            }
        }
    }

    private func setupRouteChange() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if !self.engine.isRunning { try? self.engine.start() }
        }
    }

    // MARK: - Peak Guard Tap (soft limiter-ish)

    /// Installs a very cheap peak detector on the main mixer that gently ducks
    /// output volume if instantaneous peaks approach full scale (0 dBFS).
    private func installPeakGuardTap() {
        guard !peakTapInstalled else { return }
        peakTapInstalled = true

        let mixer = engine.mainMixerNode
        let fmt = engine.outputNode.outputFormat(forBus: 0)
        let bufferSize: AVAudioFrameCount = 1024  // ~21ms @ 48k — responsive but cheap

        mixer.installTap(onBus: 0, bufferSize: bufferSize, format: fmt) { [weak self] buffer, _ in
            guard let self = self else { return }
            // Only operate if we have float channels
            guard let ch0 = buffer.floatChannelData?.pointee else { return }
            let n = Int(buffer.frameLength)
            if n == 0 { return }

            // Peak magnitude for this buffer (channel 0 is enough for guard)
            var peak: Float = 0
            vDSP_maxmgv(ch0, 1, &peak, vDSP_Length(n))

            // If peak is hot, gently duck the mixer (soft, fast reaction).
            // We keep a ceiling of outputVolumeCap to avoid slow drift upward.
            if peak > 0.89 {
                DispatchQueue.main.async {
                    let cur = mixer.outputVolume
                    // small 3% step down
                    mixer.outputVolume = max(0.0, min(self.outputVolumeCap, cur * 0.97))
                }
            } else if peak < 0.55 {
                // allow a very slow recovery toward the cap to avoid permanent attenuation
                DispatchQueue.main.async {
                    let cur = mixer.outputVolume
                    let target = self.outputVolumeCap
                    mixer.outputVolume = min(target, cur + 0.0015) // slow rise
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
