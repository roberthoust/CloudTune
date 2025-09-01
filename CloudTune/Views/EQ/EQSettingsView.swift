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
    @State private var selectedPresetName: String = EQManager.shared.lastUsedPresetName

    // UI state
    @State private var showSaveDialog = false
    @FocusState private var nameFieldFocused: Bool
    @State private var newPresetName = ""
    @State private var presetToDelete: String? = nil
    @State private var confirmUpdate = false
    @State private var isSaving = false

    // Cached values (no I/O in body)
    @State private var cachedCustomPresets: [String] = []
    @State private var selectedPresetGainsCache: [Float]? = nil

    // Model
    private let frequencies: [Float] = [60, 250, 1000, 4000, 8000]
    private let builtInOrder: [String] = ["Flat", "Bass Boost", "Vocal Boost", "Treble Boost", "Lo-Fi"]

    // Derived
    private var customPresets: [String] { cachedCustomPresets }
    private let builtInPresets: [String: [Float]] = [
        "Flat": [0, 0, 0, 0, 0],
        "Bass Boost": [6, 3, 0, -2, -4],
        "Vocal Boost": [-2, 1, 4, 3, 0],
        "Treble Boost": [-4, -2, 0, 2, 5],
        "Lo-Fi": [-6, -4, 0, 4, 6]
    ]

    private var isDirty: Bool {
        let base: [Float]
        if let builtin = builtInPresets[selectedPresetName] {
            base = builtin
        } else if let cached = selectedPresetGainsCache {
            base = cached
        } else {
            return false
        }
        return !eqMatches(lhs: gains, rhs: base)
    }

    private var isOnCustomPreset: Bool {
        customPresets.contains(selectedPresetName)
    }

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
                                Button { applyPreset(named: name) } label: {
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
                                        .animation(nil, value: showSaveDialog)
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
                                        EQManager.shared.setBands(gains)
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
                            .disabled(isSaving)
                        }
                    } else {
                        Button {
                            showSaveDialog = true
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
                        .disabled(customPresets.count >= 3 || isSaving)
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
                                    Button { applyPreset(named: name) } label: {
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
                        .transaction { tx in tx.animation = nil }
                    }

                    Spacer(minLength: 10)
                }
                .padding(.top, 6)
                .disabled(isSaving || showSaveDialog)
            }
            .navigationTitle("Equalizer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .transaction { tx in if showSaveDialog { tx.animation = nil } }

            // In-place SAVE DIALOG overlay
            .overlay {
                if showSaveDialog {
                    ZStack {
                        Color.black.opacity(0.35)
                            .ignoresSafeArea()

                        VStack(spacing: 12) {
                            Text("Save Custom Preset")
                                .font(.headline)

                            TextField("Preset Name", text: $newPresetName)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .focused($nameFieldFocused)
                                .submitLabel(.done)
                                .padding(10)
                                .background(Color(UIColor.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                            HStack(spacing: 12) {
                                Button("Cancel") {
                                    showSaveDialog = false
                                }
                                .buttonStyle(.bordered)
                                .disabled(isSaving)

                                Button("Save") {
                                    let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !name.isEmpty, gains.count == frequencies.count else { return }
                                    isSaving = true
                                    Task {
                                        await Task.detached(priority: .utility) {
                                            EQManager.shared.savePreset(name: name, gains: gains)
                                            EQManager.shared.saveLastUsed(gains: gains, presetName: name)
                                        }.value
                                        await MainActor.run {
                                            withAnimation(nil) {
                                                selectedPresetName = name
                                                selectedPresetGainsCache = gains
                                                refreshCustomNames()
                                                isSaving = false
                                                showSaveDialog = false
                                            }
                                        }
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: 360)
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .onAppear { DispatchQueue.main.async { nameFieldFocused = true } }
                    }
                }
            }

            // Confirm overwrite for Update
            .alert("Update Custom Preset",
                   isPresented: $confirmUpdate,
                   actions: {
                       Button("Update", role: .destructive) {
                           let name = selectedPresetName
                           guard customPresets.contains(name) else { return }
                           isSaving = true
                           Task {
                               await Task.detached(priority: .utility) {
                                   EQManager.shared.savePreset(name: name, gains: gains)
                                   EQManager.shared.saveLastUsed(gains: gains, presetName: name)
                               }.value
                               await MainActor.run {
                                   withAnimation(nil) { isSaving = false }
                               }
                           }
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
                               refreshCustomNames()
                               if selectedPresetName == p {
                                   applyPreset(named: "Flat")
                                   selectedPresetGainsCache = builtInPresets["Flat"]
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
            let lastName = EQManager.shared.lastUsedPresetName
            let lastGains = EQManager.shared.loadLastUsed()
            selectedPresetName = lastName
            gains = lastGains
            refreshCustomNames()
            refreshSelectedCache(for: lastName)
        }
    }

    // MARK: - Actions

    private func applyPreset(named name: String) {
        let values = gainsForPreset(name) ?? builtInPresets["Flat"]!
        selectedPresetName = name
        gains = values
        EQManager.shared.setBands(values)
        EQManager.shared.saveLastUsed(gains: values, presetName: name)
        refreshSelectedCache(for: name)
    }

    // MARK: - Helpers

    private func gainsForPreset(_ name: String) -> [Float]? {
        if let vals = builtInPresets[name] { return vals }
        if name == selectedPresetName { return selectedPresetGainsCache }
        return nil
    }

    @MainActor
    private func refreshCustomNames() {
        cachedCustomPresets = EQManager.shared
            .loadCustomPresetNames()
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    @MainActor
    private func refreshSelectedCache(for name: String) {
        if let builtin = builtInPresets[name] {
            selectedPresetGainsCache = builtin
        } else {
            selectedPresetGainsCache = EQManager.shared.loadPreset(named: name)
        }
    }

    private func eqMatches(lhs: [Float], rhs: [Float]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for i in 0..<lhs.count {
            if abs(lhs[i] - rhs[i]) > 0.001 { return false }
        }
        return true
    }
}
