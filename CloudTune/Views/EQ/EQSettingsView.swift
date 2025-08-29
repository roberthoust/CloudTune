//
//  EQSettingsView.swift
//  CloudTune
//

import SwiftUI

struct EQSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    // Live EQ state
    @State private var gains: [Float] = EQManager.shared.getCurrentGains()

    // Track which preset is considered “selected” for the banner.
    // On launch, this is whatever EQManager last persisted.
    @State private var selectedPresetName: String = EQManager.shared.lastUsedPresetName

    // UI state
    @State private var showingSavePrompt = false
    @State private var newPresetName = ""
    @State private var presetToDelete: String? = nil
    @State private var confirmUpdate = false

    // Model
    private let frequencies: [Float] = [60, 250, 1000, 4000, 8000]
    private let builtInOrder: [String] = ["Flat", "Bass Boost", "Vocal Boost", "Treble Boost", "Lo-Fi"]

    // Derived
    private var customPresets: [String] { EQManager.shared.loadCustomPresetNames() }
    private var builtInPresets: [String: [Float]] {
        [
            "Flat": [0, 0, 0, 0, 0],
            "Bass Boost": [6, 3, 0, -2, -4],
            "Vocal Boost": [-2, 1, 4, 3, 0],
            "Treble Boost": [-4, -2, 0, 2, 5],
            "Lo-Fi": [-6, -4, 0, 4, 6]
        ]
    }

    // “Dirty” means the sliders differ from the values of the selected preset name.
    private var isDirty: Bool {
        guard let base = gainsForPreset(selectedPresetName) else { return true }
        return !eqMatches(lhs: gains, rhs: base)
    }

    // If a custom preset is selected and dirty, we show "Update" instead of "Save".
    private var isOnCustomPreset: Bool {
        customPresets.contains(selectedPresetName)
    }

    // A banner-friendly label (e.g. “Bass Boost (edited)”)
    private var currentPresetBanner: String {
        isDirty ? "\(selectedPresetName) (edited)" : selectedPresetName
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {

                    // CURRENT PRESET BANNER
                    Text("Current Preset: \(currentPresetBanner)")
                        .font(.headline)
                        .foregroundColor(.accentColor)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                        .padding(.top, 10)

                    // BUILT-IN PRESETS
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Default Presets")
                            .font(.headline)
                            .foregroundColor(.secondary)
                            .padding(.horizontal)

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                            ForEach(builtInOrder, id: \.self) { name in
                                let isActive = (selectedPresetName == name) && !isDirty
                                Button {
                                    applyPreset(named: name)
                                } label: {
                                    Text(name)
                                        .font(.subheadline)
                                        .frame(maxWidth: .infinity, minHeight: 40)
                                        .background(Color(UIColor.secondarySystemBackground))
                                        .foregroundColor(isActive ? .accentColor : .primary)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(isActive ? Color.accentColor : Color.clear, lineWidth: 2)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }

                    Divider().padding(.horizontal)

                    // SLIDERS
                    VStack(spacing: 18) {
                        ForEach(gains.indices, id: \.self) { i in
                            HStack(spacing: 14) {
                                Text("\(Int(frequencies[i])) Hz")
                                    .frame(width: 60, alignment: .leading)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)

                                Slider(value: $gains[i], in: -6...6, step: 0.5)
                                    .tint(.accentColor)
                                    .onChange(of: gains[i]) { _ in
                                        // Push to EQ immediately
                                        EQManager.shared.setBands(gains)
                                        // Persist the gains (keep preset name as-is so banner sticks)
                                        EQManager.shared.saveLastUsed(gains: gains, presetName: selectedPresetName)
                                    }

                                Text("\(gains[i] >= 0 ? "+" : "")\(Int(gains[i])) dB")
                                    .frame(width: 56, alignment: .trailing)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal)
                        }
                    }

                    // SAVE / UPDATE BUTTONS
                    if isOnCustomPreset {
                        // SELECTED CUSTOM PRESET
                        if isDirty {
                            Button {
                                confirmUpdate = true
                            } label: {
                                Label("Update '\(selectedPresetName)'", systemImage: "arrow.triangle.2.circlepath")
                                    .frame(maxWidth: .infinity)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                        }
                    } else {
                        // SELECTED BUILT-IN PRESET
                        Button {
                            showingSavePrompt = true
                            newPresetName = ""
                        } label: {
                            Label("Save Custom Preset", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .padding()
                        .background(customPresets.count >= 3 ? Color.gray.opacity(0.4) : Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                        .padding(.horizontal)
                        .disabled(customPresets.count >= 3)
                    }

                    // CUSTOM PRESETS LIST
                    if !customPresets.isEmpty {
                        Divider().padding(.horizontal)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Your Presets")
                                .font(.headline)
                                .foregroundColor(.secondary)
                                .padding(.horizontal)

                            ForEach(customPresets, id: \.self) { name in
                                let active = (selectedPresetName == name) && !isDirty
                                HStack {
                                    Button {
                                        applyPreset(named: name)
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "slider.horizontal.3")
                                            Text(name)
                                                .fontWeight(active ? .semibold : .regular)
                                        }
                                        .foregroundColor(active ? .accentColor : .primary)
                                    }
                                    .buttonStyle(.plain)

                                    Spacer()

                                    Button(role: .destructive) {
                                        presetToDelete = name
                                    } label: {
                                        Image(systemName: "trash")
                                            .imageScale(.medium)
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Delete \(name)")
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color(UIColor.secondarySystemBackground))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                                )
                                .padding(.horizontal)
                            }
                        }
                    }

                    Spacer(minLength: 10)
                }
                .padding(.top, 6)
            }
            .navigationTitle("Equalizer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }

            // Save prompt for NEW custom
            .alert("Save Custom Preset", isPresented: $showingSavePrompt) {
                TextField("Preset Name", text: $newPresetName)
                Button("Save") {
                    let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    guard gains.count == frequencies.count else { return }
                    EQManager.shared.savePreset(name: name, gains: gains)
                    EQManager.shared.saveLastUsed(gains: gains, presetName: name)
                    selectedPresetName = name
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Name your new preset (max 3 total).")
            }

            // Confirm overwrite for Update
            .alert("Update Custom Preset",
                   isPresented: $confirmUpdate,
                   actions: {
                       Button("Update", role: .destructive) {
                           let name = selectedPresetName
                           guard customPresets.contains(name) else { return }
                           EQManager.shared.savePreset(name: name, gains: gains)   // overwrite
                           EQManager.shared.saveLastUsed(gains: gains, presetName: name)
                           // still selected; dirty now cleared by equality
                       }
                       Button("Cancel", role: .cancel) {}
                   },
                   message: { Text("Replace '\(selectedPresetName)' with the current slider values?") })

            // Confirm delete
            .alert("Delete Preset",
                   isPresented: Binding(
                       get: { presetToDelete != nil },
                       set: { if !$0 { presetToDelete = nil } }
                   ),
                   actions: {
                       Button("Delete", role: .destructive) {
                           if let p = presetToDelete {
                               EQManager.shared.deleteCustomPreset(named: p)
                               if selectedPresetName == p {
                                   // If we just deleted the selected custom, fall back to Flat.
                                   applyPreset(named: "Flat")
                               }
                               presetToDelete = nil
                           }
                       }
                       Button("Cancel", role: .cancel) { presetToDelete = nil }
                   },
                   message: { Text("Are you sure you want to delete \"\(presetToDelete ?? "")\"?") }
            )
        }
        .onAppear {
            // Ensure banner state (and gains) reflect persisted last-used.
            let lastName = EQManager.shared.lastUsedPresetName
            let lastGains = EQManager.shared.loadLastUsed()
            selectedPresetName = lastName
            gains = lastGains
        }
    }

    // MARK: - Actions

    private func applyPreset(named name: String) {
        let values = gainsForPreset(name) ?? builtInPresets["Flat"]!
        selectedPresetName = name                  // keep banner on selected name
        gains = values
        EQManager.shared.setBands(values)
        EQManager.shared.saveLastUsed(gains: values, presetName: name)
    }

    // MARK: - Helpers

    /// Returns gains for either a built-in or a custom preset name.
    private func gainsForPreset(_ name: String) -> [Float]? {
        if let vals = builtInPresets[name] { return vals }
        if let custom = (UserDefaults.standard.dictionary(forKey: "EQPresets") as? [String: [Float]])?[name] {
            return custom
        }
        return nil
    }

    /// Because we store 0.5 dB steps, strict equality is fine; keep a tolerance just in case.
    private func eqMatches(lhs: [Float], rhs: [Float]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for i in 0..<lhs.count {
            if abs(lhs[i] - rhs[i]) > 0.001 { return false }
        }
        return true
    }
}
