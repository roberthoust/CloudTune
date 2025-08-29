import AVFoundation

/// Central place to control the app's EQ node safely.
/// - Clamps gain to a safe range (±6 dB by default)
/// - Coalesces rapid updates to avoid scheduling hiccups while the engine is rendering
final class EQManager {
    static let shared = EQManager()

    // MARK: Policy
    /// Production-safe EQ range. You can make this user-configurable later.
    private let gainMinDB: Float = -6.0
    private let gainMaxDB: Float =  6.0

    // If the UI fires many changes quickly, we coalesce to this delay.
    private let coalesceDelay: TimeInterval = 0.03 // 30 ms feels instantaneous but avoids choppy updates

    // MARK: Wiring
    private weak var eqNode: AVAudioUnitEQ?
    private(set) var bandFrequencies: [Float] = [60, 250, 1000, 4000, 8000]

    // MARK: Coalescing machinery
    private let updateQueue = DispatchQueue(label: "eq.update.queue", qos: .userInitiated)
    private var pendingWork: DispatchWorkItem?

    private init() {}

    // Call this once after AudioEngine is created (and the node is attached to the engine)
    func attach(eq: AVAudioUnitEQ, frequencies: [Float]? = nil) {
        self.eqNode = eq
        if let f = frequencies, f.count == eq.bands.count {
            self.bandFrequencies = f
        }

        // Initialize band objects (type/bw) in case AudioEngine didn't already do it
        for (i, freq) in bandFrequencies.enumerated() where i < eq.bands.count {
            let b = eq.bands[i]
            b.filterType = .parametric
            b.frequency = freq
            b.bandwidth = 0.5
            b.bypass = false
        }

        // Apply last-used gains on app start (clamped)
        setBands(loadLastUsed(), coalesce: false)
    }

    // MARK: - Band control

    /// Public setter used by UI / presets.
    /// We clamp and coalesce by default to avoid crackles under heavy UI activity.
    func setBands(_ gains: [Float], coalesce: Bool = true) {
        let clamped = clampGains(gains)

        // Persist immediately so a crash/quit doesn’t lose the state
        saveLastUsed(clamped, presetName: nil)

        guard let _ = eqNode else { return }

        if coalesce {
            // Cancel any in-flight write and schedule a single update shortly
            pendingWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.applyToEQ(clamped)
            }
            pendingWork = work
            updateQueue.asyncAfter(deadline: .now() + coalesceDelay, execute: work)
        } else {
            applyToEQ(clamped)
        }
    }

    /// Read current gains (for UI)
    func getCurrentGains() -> [Float] {
        guard let eq = eqNode else { return Array(repeating: 0, count: bandFrequencies.count) }
        return eq.bands.prefix(bandFrequencies.count).map { $0.gain }
    }

    // MARK: - Presets

    private let builtInPresets: [String: [Float]] = [
        "Flat":        [ 0,  0,  0,  0,  0],
        "Bass Boost":  [ 6,  3,  0, -2, -4],
        "Vocal Boost": [-2,  1,  4,  3,  0],
        "Treble Boost":[-4, -2,  0,  2,  5],
        "Lo-Fi":       [-6, -4,  0,  4,  6] // will be clamped to min/max automatically
    ]

    private let presetsKey      = "EQPresets"
    private let customNamesKey  = "CustomPresetNames"
    private let lastUsedGainsKey = "LastUsedEQ"
    private let lastUsedNameKey  = "LastUsedEQName"

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
            return clampGains(gains)
        }
        return clampGains(builtInPresets[name] ?? builtInPresets["Flat"]!)
    }

    func savePreset(name: String, gains: [Float]) {
        let safe = clampGains(gains)
        guard safe.count == bandFrequencies.count else { return }
        var allPresets = UserDefaults.standard.dictionary(forKey: presetsKey) as? [String: [Float]] ?? [:]
        allPresets[name] = safe
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
        let safe = clampGains(gains)
        guard safe.count == bandFrequencies.count else { return }
        UserDefaults.standard.set(safe, forKey: lastUsedGainsKey)
        if let name = presetName {
            UserDefaults.standard.set(name, forKey: lastUsedNameKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lastUsedNameKey)
        }
    }

    func loadLastUsed() -> [Float] {
        if let gains = UserDefaults.standard.array(forKey: lastUsedGainsKey) as? [Float],
           gains.count == bandFrequencies.count {
            return clampGains(gains)
        }
        return builtInPresets["Flat"]!
    }

    // MARK: - Internals

    /// Actually writes into AVAudioUnitEQ (on main-thread to avoid UI->audio races)
    private func applyToEQ(_ gains: [Float]) {
        guard let eq = eqNode else { return }
        let safe = clampGains(gains)

        // Update on main thread; AVAudioEngine prefers graph mutations from main.
        DispatchQueue.main.async {
            for (i, g) in safe.enumerated() where i < eq.bands.count {
                eq.bands[i].gain = g
            }
        }
    }

    /// Ensures the array has the right length and each band is within [min, max].
    private func clampGains(_ gains: [Float]) -> [Float] {
        var result = Array(gains.prefix(bandFrequencies.count))
        if result.count < bandFrequencies.count {
            result.append(contentsOf: Array(repeating: 0, count: bandFrequencies.count - result.count))
        }
        for i in 0..<result.count {
            result[i] = max(gainMinDB, min(gainMaxDB, result[i]))
        }
        return result
    }
}
