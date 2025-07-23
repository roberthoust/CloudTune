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
    private var isSeeking = false

    let bandFrequencies: [Float] = [60, 250, 1000, 4000, 8000]

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

        let lastGains = loadLastUsed()
        setBands(lastGains)
    }

    // MARK: - Playback Control

    func start() throws {
        try engine.start()
    }

    func play(song: Song, completion: @escaping () -> Void) throws {
        isSeeking = false // ✅ Reset on fresh play

        let file = try AVAudioFile(forReading: song.url)
        currentFile = file
        currentSong = song

        playerNode.stop()
        playerNode.scheduleFile(file, at: nil) {
            if self.isSeeking {
                print("⏩ Ignoring completion — still in seek mode.")
                self.isSeeking = false
                return
            }

            DispatchQueue.main.async {
                completion()
            }
        }
        playerNode.play()
    }

    func seek(to time: TimeInterval, completion: @escaping () -> Void) {
        guard let file = currentFile else {
            print("❌ No active file to seek.")
            return
        }

        isSeeking = true  // 🛑 Suppress completion handler

        let sampleRate = file.processingFormat.sampleRate
        let totalFrames = file.length
        let safeTime = min(max(0, time), Double(totalFrames) / sampleRate)
        let startFrame = AVAudioFramePosition(safeTime * sampleRate)
        let framesToPlay = AVAudioFrameCount(totalFrames - startFrame)

        file.framePosition = startFrame
        playerNode.stop()

        playerNode.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: framesToPlay,
            at: nil
        ) { [weak self] in
            guard let self = self else { return }

            if self.isSeeking {
                print("⏩ Ignoring completion — it was a seek.")
                self.isSeeking = false
                return
            }

            print("✅ Natural playback completion — calling handler.")
            DispatchQueue.main.async {
                completion()
            }
        }

        playerNode.play()
    }

    func pause() {
        playerNode.pause()
    }

    func resume() {
        playerNode.play()
    }

    func stop() {
        playerNode.stop()
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

    // MARK: - Built-in & Custom Presets

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

    var lastUsedPresetName: String? {
        UserDefaults.standard.string(forKey: lastUsedNameKey)
    }
}
