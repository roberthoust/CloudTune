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

    // MARK: Playback state
    private var currentFile: AVAudioFile?
    private var playbackCompletion: (() -> Void)?
    private var activePlaybackID: UUID?

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

            // Keep same track identity and end-of-track completion.
            self.player.scheduleSegment(
                file,
                startingFrame: startFrame,
                frameCount: framesLeft,
                at: nil
            ) { [weak self] in
                guard let self else { return }
                DispatchQueue.main.async { self.playbackCompletion?() }
            }

            self.player.play()

            // UI callback for seek completion.
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

        // Release scope now that the file is no longer used
        currentScopeStopper?()
        currentScopeStopper = nil
    }

    // MARK: - Private setup

    private func whenReady(_ work: @escaping () -> Void) {
        if isGraphReady { work() } else { readyCallbacks.append(work) }
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()

        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        do {
            try session.setCategory(.playback, mode: .default, options: [])
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

        // Simple graph: player → eq → mainMixer
        engine.connect(player, to: eq, format: fmt)
        engine.connect(eq, to: engine.mainMixerNode, format: fmt)

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

    deinit {
        currentScopeStopper?()
        currentScopeStopper = nil
        print("🧹 AudioEngine deinit — released any active scope")
    }
}
