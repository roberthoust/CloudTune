import AVFoundation
import Foundation

class EQManager {
    static let shared = EQManager()

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let eq: AVAudioUnitEQ
    private var bands: [AVAudioUnitEQFilterParameters] = []

    private var currentFile: AVAudioFile?
    private var currentSong: Song?
    private var playbackCompletionHandler: (() -> Void)?
    private var activePlaybackID: UUID?
    private var currentSeekID: UUID?
    private var isSeeking = false
    private(set) var isPlaying: Bool = false

    private var lastPlayStartTime: TimeInterval = 0

    let bandFrequencies: [Float] = [60, 250, 1000, 4000, 8000]

    var lastUsedPresetName: String {
        UserDefaults.standard.string(forKey: lastUsedNameKey) ?? "Flat"
    }

    private init() {
        eq = AVAudioUnitEQ(numberOfBands: bandFrequencies.count)
        bands = eq.bands

        for (i, freq) in bandFrequencies.enumerated() {
            bands[i].filterType = .parametric
            bands[i].frequency = freq
            bands[i].bandwidth = 0.5
            bands[i].gain = 0
            bands[i].bypass = false
        }

        engine.attach(playerNode)
        engine.attach(eq)
        engine.connect(playerNode, to: eq, format: nil)
        engine.connect(eq, to: engine.mainMixerNode, format: nil)

        setBands(loadLastUsed())
    }

    // MARK: - Playback Control

    func start() throws {
        try engine.start()
    }

        func play(song: Song, id playbackID: UUID, completion: @escaping (UUID) -> Void) throws {
        activePlaybackID = playbackID
        playbackCompletionHandler = { completion(playbackID) }

        let file = try AVAudioFile(forReading: song.url)

        // Full reset
        playerNode.stop()
        playerNode.reset()
        engine.stop()

        engine.detach(playerNode)

        engine.attach(playerNode)
        engine.connect(playerNode, to: eq, format: nil)
        engine.connect(eq, to: engine.mainMixerNode, format: nil)

        try engine.start()

        print("🧪 EQManager — scheduling full file")
        let playStartTime = Date().timeIntervalSince1970
        self.lastPlayStartTime = playStartTime
        isSeeking = false

        playerNode.scheduleFile(file, at: nil) { [weak self] in
            guard let self = self else { return }
            let now = Date().timeIntervalSince1970
            let elapsed = now - playStartTime

            if self.isSeeking || self.activePlaybackID != playbackID {
                return
            }

            if elapsed < 1.5 {
                print("⚠️ Skipped too soon after playback start (\(elapsed)s) — ignoring completion.")
                return
            }

            DispatchQueue.main.async {
                print("🎯 Inside EQManager — about to call completion closure")
                self.playbackCompletionHandler?()
                self.playbackCompletionHandler = nil
            }
        }

        currentFile = file
        currentSong = song

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.playerNode.play()
        }
        isPlaying = true
    }

    func seek(to time: TimeInterval, completion: (() -> Void)? = nil) {
        guard let file = currentFile, let song = currentSong else {
            print("❌ No active file or song to seek.")
            return
        }

        isSeeking = true
        let seekID = UUID()
        activePlaybackID = seekID

        let sampleRate = file.processingFormat.sampleRate
        let totalFrames = file.length
        let songDuration = Double(totalFrames) / sampleRate
        let safeTime = min(max(0, time), songDuration)
        let startFrame = AVAudioFramePosition(safeTime * sampleRate)
        let framesToPlay = AVAudioFrameCount(totalFrames - startFrame)

        file.framePosition = startFrame
        playerNode.stop()

        playerNode.scheduleSegment(file, startingFrame: startFrame, frameCount: framesToPlay, at: nil) {
            guard self.activePlaybackID == seekID else {
                print("🛑 Outdated seekID ignored.")
                return
            }

            DispatchQueue.main.async {
                print("✅ Segment finished — treating as completion")
                self.playbackCompletionHandler?()
                self.playbackCompletionHandler = nil
                completion?()
            }
        }

        playerNode.play()
        isPlaying = true
    }

    func pause() {
        playerNode.pause()
        isPlaying=false

    }

    func resume() {
        playerNode.play()
        isPlaying=true

    }

    func stop() {
        playerNode.reset() // flush all scheduled buffers
        playerNode.stop()
        engine.stop()
        isPlaying = false
        
        playbackCompletionHandler = nil
        activePlaybackID = nil
        currentSeekID = nil
        isSeeking = false

        currentFile = nil
        currentSong = nil

        print("🛑 EQManager — playback stopped and cleared.")
    }

    // MARK: - EQ Management

    func setBands(_ gains: [Float]) {
        for (i, gain) in gains.enumerated() where i < bands.count {
            bands[i].gain = gain
        }
    }

    func getCurrentGains() -> [Float] {
        bands.map { $0.gain }
    }

    // MARK: - Presets

    private let builtInPresets: [String: [Float]] = [
        "Flat": [0, 0, 0, 0, 0],
        "Bass Boost": [6, 3, 0, -2, -4],
        "Vocal Boost": [-2, 1, 4, 3, 0],
        "Treble Boost": [-4, -2, 0, 2, 5],
        "Lo-Fi": [-8, -4, 0, 4, 8]
    ]

    func loadPreset(named name: String) -> [Float] {
        if let custom = UserDefaults.standard.dictionary(forKey: presetsKey) as? [String: [Float]],
           let gains = custom[name], gains.count == bandFrequencies.count {
            return gains
        }
        return builtInPresets[name] ?? builtInPresets["Flat"]!
    }

    func savePreset(name: String, gains: [Float]) {
        guard gains.count == bandFrequencies.count else { return }
        var allPresets = UserDefaults.standard.dictionary(forKey: presetsKey) as? [String: [Float]] ?? [:]
        allPresets[name] = gains
        UserDefaults.standard.set(allPresets, forKey: presetsKey)
        saveCustomPresetName(name)
    }

    func deleteCustomPreset(named name: String) {
        var allPresets = UserDefaults.standard.dictionary(forKey: presetsKey) as? [String: [Float]] ?? [:]
        allPresets.removeValue(forKey: name)
        UserDefaults.standard.set(allPresets, forKey: presetsKey)

        var savedNames = loadCustomPresetNames()
        savedNames.removeAll { $0 == name }
        UserDefaults.standard.set(savedNames, forKey: customNamesKey)
    }

    func loadCustomPresetNames() -> [String] {
        UserDefaults.standard.stringArray(forKey: customNamesKey) ?? []
    }

    private func saveCustomPresetName(_ name: String) {
        var names = loadCustomPresetNames()
        if !names.contains(name) && names.count < 3 {
            names.append(name)
            UserDefaults.standard.set(names, forKey: customNamesKey)
        }
    }

    // MARK: - Last Used

    private let presetsKey = "EQPresets"
    private let customNamesKey = "CustomPresetNames"
    private let lastUsedGainsKey = "LastUsedEQ"
    private let lastUsedNameKey = "LastUsedEQName"

    func saveLastUsed(_ gains: [Float], presetName: String?) {
        guard gains.count == bandFrequencies.count else { return }
        UserDefaults.standard.set(gains, forKey: lastUsedGainsKey)

        if let name = presetName {
            UserDefaults.standard.set(name, forKey: lastUsedNameKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lastUsedNameKey)
        }
    }

    func loadLastUsed() -> [Float] {
        if let gains = UserDefaults.standard.array(forKey: lastUsedGainsKey) as? [Float],
           gains.count == bandFrequencies.count {
            return gains
        }
        return builtInPresets["Flat"]!
    }
}
