import AVFoundation
import Foundation

class EQManager {
    static let shared = EQManager()

    private var eq: AVAudioUnitEQ!
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    // ✅ Simplified 5-band EQ
    private let bandFrequencies: [Float] = [60, 250, 1000, 4000, 8000]
    private var bands: [AVAudioUnitEQFilterParameters] = []

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

        // Load last used EQ settings on launch
        let lastGains = loadLastUsed()
        setBands(lastGains)
    }

    func start() throws {
        try engine.start()
    }

    func play(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        playerNode.stop()
        playerNode.scheduleFile(file, at: nil)
        playerNode.play()
    }

    func pause() {
        playerNode.pause()
    }

    func resume() {
        playerNode.play()
    }

    func setBands(_ gains: [Float]) {
        for (i, gain) in gains.enumerated() where i < bands.count {
            bands[i].gain = gain
        }
    }

    func getCurrentGains() -> [Float] {
        return bands.map { $0.gain }
    }

    func stop() {
        playerNode.stop()
    }

    // MARK: - Preset Management (UserDefaults)

    private let presetsKey = "EQPresets"
    private let lastUsedKey = "LastUsedEQ"

    func loadPreset(named name: String) -> [Float] {
        if let saved = UserDefaults.standard.dictionary(forKey: presetsKey) as? [String: [Float]],
           let preset = saved[name], preset.count == bandFrequencies.count {
            return preset
        }

        // 5-band default presets
        switch name {
        case "Bass Boost": return [6, 3, 0, -2, -4]
        case "Vocal Boost": return [-2, 1, 4, 3, 0]
        case "Treble Boost": return [-4, -2, 0, 2, 5]
        case "Lo-Fi": return [-8, -4, 0, 4, 8]
        default: return [0, 0, 0, 0, 0] // Flat
        }
    }

    func savePreset(name: String, gains: [Float]) {
        guard gains.count == bandFrequencies.count else { return }

        var saved = UserDefaults.standard.dictionary(forKey: presetsKey) as? [String: [Float]] ?? [:]
        saved[name] = gains
        UserDefaults.standard.set(saved, forKey: presetsKey)
    }

    func isCustomSlotEmpty(index: Int) -> Bool {
        guard (1...3).contains(index) else { return true }
        let name = "Custom \(index)"
        let saved = UserDefaults.standard.dictionary(forKey: presetsKey) as? [String: [Float]] ?? [:]
        return saved[name] == nil
    }

    func saveLastUsed(_ gains: [Float]) {
        guard gains.count == bandFrequencies.count else { return }
        UserDefaults.standard.set(gains, forKey: lastUsedKey)
    }

    func loadLastUsed() -> [Float] {
        if let saved = UserDefaults.standard.array(forKey: lastUsedKey) as? [Float],
           saved.count == bandFrequencies.count {
            return saved
        }
        return [0, 0, 0, 0, 0]
    }

    // Optional: expose band frequencies to UI
    func getFrequencies() -> [Float] {
        return bandFrequencies
    }
}
