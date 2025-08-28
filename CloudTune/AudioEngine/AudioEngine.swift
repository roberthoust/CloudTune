//
//  AudioEngine.swift
//  CloudTune
//
//  Created by Robert Houst on 8/28/25.
//

import AVFoundation
import AudioToolbox   // for AudioComponentDescription & AU instantiate

final class AudioEngine {

    // Core nodes
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let eq = AVAudioUnitEQ(numberOfBands: 5)

    // Optional limiter (Apple Peak Limiter AU). It's async-loaded.
    private var limiterAU: AVAudioUnit?

    // Playback state
    private var currentFile: AVAudioFile?
    private var playbackCompletion: (() -> Void)?
    private var activePlaybackID: UUID?

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
            self.activePlaybackID = id
            self.playbackCompletion = completion

            self.player.stop()
            self.player.reset()

            do {
                let file = try AVAudioFile(forReading: url)
                self.currentFile = file

                let startStamp = CACurrentMediaTime()
                self.player.scheduleFile(file, at: nil) { [weak self] in
                    guard let self else { return }
                    guard self.activePlaybackID == id else { return }
                    if CACurrentMediaTime() - startStamp < 0.5 { return }
                    DispatchQueue.main.async { self.playbackCompletion?() }
                }

                if !self.engine.isRunning { try? self.engine.start() }
                self.player.play()
            } catch {
                print("❌ AudioEngine.play: \(error.localizedDescription)")
            }
        }
    }

    func seek(to seconds: TimeInterval, completion: (() -> Void)? = nil) {
        whenReady { [weak self] in
            guard let self, let file = self.currentFile else { return }

            let sr = file.processingFormat.sampleRate
            let totalFrames = file.length
            let duration = Double(totalFrames) / sr
            let clamped = max(0, min(seconds, duration))

            let startFrame = AVAudioFramePosition(clamped * sr)
            let framesLeft = AVAudioFrameCount(totalFrames - startFrame)

            self.player.stop()
            self.player.reset()
            file.framePosition = startFrame

            let seekID = UUID()
            self.activePlaybackID = seekID

            self.player.scheduleSegment(file, startingFrame: startFrame, frameCount: framesLeft, at: nil) { [weak self] in
                guard let self, self.activePlaybackID == seekID else { return }
                DispatchQueue.main.async { completion?() }
            }

            self.player.play()
        }
    }

    func pause()  { player.pause() }
    func resume() { player.play()  }

    func stop() {
        player.stop()
        player.reset()
        playbackCompletion = nil
        activePlaybackID = nil
        currentFile = nil
    }

    // MARK: - Private setup

    private func whenReady(_ work: @escaping () -> Void) {
        if isGraphReady { work() } else { readyCallbacks.append(work) }
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()

        // 1) Always deactivate before reconfiguring (resets bad state)
        try? session.setActive(false, options: .notifyOthersOnDeactivation)

        // 2) Choose a *simple, valid* category for playback-only
        //    - Don’t request .allowBluetooth with .playback
        //    - AirPlay selection does not require .allowAirPlay in most cases
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            // If you *must* mix with other audio, add: options: [.mixWithOthers]
        } catch {
            print("❌ setCategory(.playback) failed: \(error.localizedDescription)")
        }

        // 3) Ask for reasonable prefs (these are *preferences*, not guarantees)
        //    Keep them modest to avoid -50 on some routes/devices.
        do {
            // Prefer 48k, but don’t hard-fail if unsupported
            try? session.setPreferredSampleRate(48_000)
            // 10 ms is a safe, low-latency target; 5 ms is often too aggressive
            try? session.setPreferredIOBufferDuration(0.010)
        }

        // 4) Activate *after* category & prefs
        do {
            try session.setActive(true)
        } catch {
            print("❌ setActive(true) failed: \(error.localizedDescription)")
        }

        // 5) Log what we actually got (useful when debugging -50)
        let sr = session.sampleRate
        let dur = session.ioBufferDuration
        let route = session.currentRoute
        print("🎧 Session active. sr=\(sr)Hz io=\(Int(dur * 1000))ms route=\(route.outputs.first?.portType.rawValue ?? "unknown")")
    }

    private func configureGraph(onReady: @escaping () -> Void) {
        // Attach nodes we already have
        [player, eq].forEach(engine.attach)

        // Preconfigure EQ bands (neutral). EQManager will set gains later.
        let freqs: [Float] = [60, 250, 1000, 4000, 8000]
        for (i, f) in freqs.enumerated() where i < eq.bands.count {
            let b = eq.bands[i]
            b.filterType = .parametric
            b.frequency = f
            b.bandwidth = 0.5
            b.gain = 0
            b.bypass = false
        }

        // We’ll try to insert a Peak Limiter AU between EQ and MainMixer.
        // Because instantiate is async, we build connections in its callback.
        let fmt = engine.outputNode.outputFormat(forBus: 0)

        instantiatePeakLimiter { [weak self] limiter in
            guard let self else { return }

            if let limiter {
                self.limiterAU = limiter
                self.engine.attach(limiter)

                self.engine.connect(self.player,  to: self.eq,      format: fmt)
                self.engine.connect(self.eq,      to: limiter,       format: fmt)
                self.engine.connect(limiter,      to: self.engine.mainMixerNode, format: fmt)

                // Optional: you can set limiter parameters via AudioUnit APIs if needed.
            } else {
                // Fallback: no limiter, direct to mixer.
                self.engine.connect(self.player, to: self.eq, format: fmt)
                self.engine.connect(self.eq,     to: self.engine.mainMixerNode, format: fmt)
            }

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
}
