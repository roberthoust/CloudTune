import AVFoundation

final class AudioEngine {

    // 1) Core nodes live here (owned by AudioEngine)
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let eq = AVAudioUnitEQ(numberOfBands: 5) // we’ll wire EQManager to this node
    let limiter = AVAudioUnitLimiter()       // safety against EQ boosts clipping

    // 2) Playback state (kept here, not in EQ manager)
    private var currentFile: AVAudioFile?
    private var playbackCompletion: (() -> Void)?
    private var activePlaybackID: UUID?

    init() {
        configureSession()
        configureGraph()
        prepareAndStart()
        setupInterruptions()
        setupRouteChange()
    }

    // MARK: - Public controls

    func play(url: URL, id: UUID = UUID(), completion: (() -> Void)? = nil) throws {
        activePlaybackID = id
        playbackCompletion = completion

        // Stop/reset before scheduling a new file
        player.stop()
        player.reset()

        let file = try AVAudioFile(forReading: url)
        currentFile = file

        // Schedule entire file (simple path). For ultra-robustness, later replace
        // with chunked scheduling on a background queue.
        let startStamp = CACurrentMediaTime()
        player.scheduleFile(file, at: nil) { [weak self] in
            guard let self else { return }
            // Ignore if a newer play() superseded this
            guard self.activePlaybackID == id else { return }
            // Avoid early false positives (race with immediate pause/seek)
            if CACurrentMediaTime() - startStamp < 0.5 { return }
            DispatchQueue.main.async { self.playbackCompletion?() }
        }

        if !engine.isRunning { try? engine.start() }
        player.play()
    }

    func seek(to seconds: TimeInterval, completion: (() -> Void)? = nil) {
        guard let file = currentFile else { return }

        let sr = file.processingFormat.sampleRate
        let totalFrames = file.length
        let duration = Double(totalFrames) / sr
        let clamped = max(0, min(seconds, duration))

        let startFrame = AVAudioFramePosition(clamped * sr)
        let framesLeft = AVAudioFrameCount(totalFrames - startFrame)

        player.stop()
        player.reset()
        file.framePosition = startFrame

        let seekID = UUID()
        activePlaybackID = seekID

        player.scheduleSegment(file, startingFrame: startFrame, frameCount: framesLeft, at: nil) { [weak self] in
            guard let self, self.activePlaybackID == seekID else { return }
            DispatchQueue.main.async { completion?() }
        }

        player.play()
    }

    func pause()  { player.pause() }
    func resume() { player.play()  }

    func stop() {
        player.stop()
        player.reset()
        // keep engine running; starting/stopping engine itself can cause pops
        playbackCompletion = nil
        activePlaybackID = nil
        currentFile = nil
    }

    // MARK: - Private setup

    private func configureSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [.allowBluetooth, .allowAirPlay])
        try? s.setPreferredSampleRate(48_000)        // stable SR on iOS hardware
        try? s.setPreferredIOBufferDuration(0.005)   // ~5ms I/O buffer (low latency)
        try? s.setActive(true)
    }

    private func configureGraph() {
        // Attach once, don’t rewire mid-playback
        [player, eq, limiter].forEach(engine.attach)

        // Preconfigure EQ bands (neutral); EQManager will tune these later
        let freqs: [Float] = [60, 250, 1000, 4000, 8000]
        for (i, f) in freqs.enumerated() where i < eq.bands.count {
            let b = eq.bands[i]
            b.filterType = .parametric
            b.frequency = f
            b.bandwidth = 0.5
            b.gain = 0
            b.bypass = false
        }

        // Keep a limiter near output to avoid clipping on user boosts
        limiter.preGain = 0

        // Connect with the device/output format so the engine doesn’t resample later
        let fmt = engine.outputNode.outputFormat(forBus: 0)
        engine.connect(player,  to: eq,      format: fmt)
        engine.connect(eq,      to: limiter, format: fmt)
        engine.connect(limiter, to: engine.mainMixerNode, format: fmt)
    }

    private func prepareAndStart() {
        engine.prepare()          // alloc render resources
        try? engine.start()       // keep running to avoid first-note glitch
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
                // If the system says we can resume, resume playback
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
            // Re-start engine if output route changed and engine stopped
            guard let self else { return }
            if !self.engine.isRunning { try? self.engine.start() }
        }
    }
}