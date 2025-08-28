import AVFoundation

final class EQManager {
    static let shared = EQManager()

    // We don’t own the engine. Inject the EQ node we want to control.
    private weak var eqNode: AVAudioUnitEQ?
    private(set) var bandFrequencies: [Float] = [60, 250, 1000, 4000, 8000]

    private init() {}

    // Call this once after AudioEngine is created
    func attach(eq: AVAudioUnitEQ, frequencies: [Float]? = nil) {
        self.eqNode = eq
        if let f = frequencies, f.count == eq.bands.count { self.bandFrequencies = f }
        // Apply last-used gains on app start
        setBands(loadLastUsed())
    }

    // MARK: - Band control

    func setBands(_ gains: [Float]) {
        guard let eq = eqNode else { return }
        for (i, g) in gains.enumerated() where i < eq.bands.count {
            eq.bands[i].gain = g
        }
        saveLastUsed(gains, presetName: nil)
    }

    func getCurrentGains() -> [Float] {
        guard let eq = eqNode else { return Array(repeating: 0, count: bandFrequencies.count) }
        return eq.bands.prefix(bandFrequencies.count).map { $0.gain }
    }

    // MARK: - Presets (unchanged logic, just without playback concerns)

    private let builtInPresets: [String: [Float]] = [
        "Flat": [0, 0, 0, 0, 0],
        "Bass Boost": [6, 3, 0, -2, -4],
        "Vocal Boost": [-2, 1, 4, 3, 0],
        "Treble Boost": [-4, -2, 0, 2, 5],
        "Lo-Fi": [-8, -4, 0, 4, 8]
    ]

    private let presetsKey = "EQPresets"
    private let customNamesKey = "CustomPresetNames"
    private let lastUsedGainsKey = "LastUsedEQ"
    private let lastUsedNameKey = "LastUsedEQName"

    var lastUsedPresetName: String {
        UserDefaults.standard.string(forKey: lastUsedNameKey) ?? "Flat"
    }

    var activePresetName: String {
        let gains = getCurrentGains()
        if gains == builtInPresets["Flat"] { return "OFF" }
        if let custom = UserDefaults.standard.dictionary(forKey: presetsKey) as? [String: [Float]] {
            for (name, storedGains) in custom where storedGains == gains { return name }
        }
        for (name, builtInGains) in builtInPresets where builtInGains == gains { return name }
        return "Custom"
    }

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
        var all = UserDefaults.standard.dictionary(forKey: presetsKey) as? [String: [Float]] ?? [:]
        all.removeValue(forKey: name)
        UserDefaults.standard.set(all, forKey: presetsKey)

        var names = loadCustomPresetNames()
        names.removeAll { $0 == name }
        UserDefaults.standard.set(names, forKey: customNamesKey)
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
