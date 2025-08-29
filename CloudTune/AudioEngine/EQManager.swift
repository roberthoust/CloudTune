//
//  EQManager.swift
//  CloudTune
//

import AVFoundation

/// Coalesces rapid updates to avoid scheduling hiccups while the engine is rendering.
final class EQManager {
    static let shared = EQManager()

    // MARK: Policy
    /// Production-safe EQ range.
    private let gainMinDB: Float = -6.0
    private let gainMaxDB: Float =  6.0

    /// If the UI fires many changes quickly, we coalesce to this delay.
    private let coalesceDelay: TimeInterval = 0.03 // ~30 ms

    // MARK: Wiring
    private weak var eqNode: AVAudioUnitEQ?
    private(set) var bandFrequencies: [Float] = [60, 250, 1000, 4000, 8000]

    // MARK: Coalescing machinery
    private let updateQueue = DispatchQueue(label: "eq.update.queue", qos: .userInitiated)
    private var pendingWork: DispatchWorkItem?

    // MARK: Persistence keys
    private let presetsKey        = "EQPresets"
    private let customNamesKey    = "CustomPresetNames"
    private let lastUsedGainsKey  = "LastUsedEQ"
    private let lastUsedNameKey   = "LastUsedEQName"

    // MARK: Built-ins
    private let builtInPresets: [String: [Float]] = [
        "Flat":         [ 0,  0,  0,  0,  0],
        "Bass Boost":   [ 6,  3,  0, -2, -4],
        "Vocal Boost":  [-2,  1,  4,  3,  0],
        "Treble Boost": [-4, -2,  0,  2,  5],
        "Lo-Fi":        [-6, -4,  0,  4,  6] // gets clamped anyway
    ]

    private init() {}

    // MARK: Attach / boot
    /// Call this once after AudioEngine is created (and the node is attached to the engine).
    func attach(eq: AVAudioUnitEQ, frequencies: [Float]? = nil) {
        self.eqNode = eq
        if let f = frequencies, f.count == eq.bands.count {
            self.bandFrequencies = f
        }

        // Ensure bands are configured
        for (i, freq) in bandFrequencies.enumerated() where i < eq.bands.count {
            let b = eq.bands[i]
            b.filterType = .parametric
            b.frequency = freq
            b.bandwidth = 0.5
            b.bypass = false
        }

        // Apply last-used gains on app start
        let gains = loadLastUsed()
        applyToEQ(gains)
    }

    // MARK: - Band control

    /// Public setter used by UI / presets.
    /// We clamp and coalesce by default to avoid crackles under heavy UI activity.
    func setBands(_ gains: [Float], coalesce: Bool = true) {
        let clamped = clampGains(gains)

        // Persist immediately so a crash/quit doesn’t lose the state
        // (presetName is handled separately by saveLastUsed(gains:presetName:))
        UserDefaults.standard.set(clamped, forKey: lastUsedGainsKey)

        guard eqNode != nil else { return }

        if coalesce {
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

    /// Read current gains (for UI).
    func getCurrentGains() -> [Float] {
        guard let eq = eqNode else { return Array(repeating: 0, count: bandFrequencies.count) }
        return eq.bands.prefix(bandFrequencies.count).map { $0.gain }
    }

    // MARK: - Presets

    /// Last used preset name (for banner/startup).
    var lastUsedPresetName: String {
        UserDefaults.standard.string(forKey: lastUsedNameKey) ?? "Flat"
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
        var all = UserDefaults.standard.dictionary(forKey: presetsKey) as? [String: [Float]] ?? [:]
        all[name] = safe
        UserDefaults.standard.set(all, forKey: presetsKey)
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

    /// Persist both gains and (optionally) the preset name.
    func saveLastUsed(gains: [Float], presetName: String?) {
        let safe = clampGains(gains)
        guard safe.count == bandFrequencies.count else { return }
        UserDefaults.standard.set(safe, forKey: lastUsedGainsKey)
        if let name = presetName {
            UserDefaults.standard.set(name, forKey: lastUsedNameKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lastUsedNameKey)
        }
    }

    /// Gains to apply on app start.
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
        DispatchQueue.main.async {
            for (i, g) in safe.enumerated() where i < eq.bands.count {
                eq.bands[i].gain = g
            }
        }
    }

    /// Ensures array length & clamps each band within [min, max].
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

    private func saveCustomPresetName(_ name: String) {
        var names = loadCustomPresetNames()
        if !names.contains(name) && names.count < 3 {
            names.append(name)
            UserDefaults.standard.set(names, forKey: customNamesKey)
        }
        
    }
    // MARK: - Active preset name (for UI banners, etc.)

    /// Name of the preset that matches the *current* EQ gains.
    /// If gains are edited relative to the last selection, returns "<lastUsedPresetName> (edited)".
    var activePresetName: String {
        let gains = getCurrentGains()
        if let exact = matchPresetName(gains) {
            return exact
        }
        // No exact match: keep the last-used name but mark as edited
        let last = lastUsedPresetName
        return "\(last) (edited)"
    }

    // Finds an exact preset name that matches the provided gains (built-in or custom).
    private func matchPresetName(_ gains: [Float]) -> String? {
        // Built-ins
        for (name, vals) in builtInPresets {
            if eqMatches(lhs: gains, rhs: vals) { return name }
        }
        // Customs
        if let custom = UserDefaults.standard.dictionary(forKey: presetsKey) as? [String: [Float]] {
            for (name, vals) in custom where eqMatches(lhs: gains, rhs: vals) {
                return name
            }
        }
        return nil
    }

    // Float-array equality with tiny tolerance.
    private func eqMatches(lhs: [Float], rhs: [Float]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for i in 0..<lhs.count {
            if abs(lhs[i] - rhs[i]) > 0.001 { return false }
        }
        return true
    }
}
