import SwiftUI

// MARK: - Preset identity

private enum PresetKind: Equatable {
    case builtIn(String)
    case custom(String)
    var name: String {
        switch self { case .builtIn(let s), .custom(let s): return s }
    }
}

// MARK: - Helper: resolve gains for a preset kind

private func gainsForPreset(kind: PresetKind,
                            customNames: [String],
                            builtIns: [String: [Float]]) -> [Float] {
    switch kind {
    case .builtIn(let name):
        return builtIns[name] ?? builtIns["Flat"] ?? [0,0,0,0,0]
    case .custom(let name):
        if customNames.contains(name) {
            return EQManager.shared.loadPreset(named: name)
        } else {
            // If somehow missing, don’t surprise the user—keep current gains.
            return EQManager.shared.getCurrentGains()
        }
    }
}

// MARK: - View

struct EQSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    // View state
    @State private var selectedPreset: PresetKind
    @State private var gains: [Float]
    @State private var baselineGains: [Float]
    @State private var customNames: [String]

    // UI state
    @State private var showingSavePrompt = false
    @State private var newPresetName = ""
    @State private var pendingUpdateConfirm = false
    @State private var presetToDelete: String? = nil

    // Constants
    private let frequencies: [Float] = [60, 250, 1000, 4000, 8000]

    // Built-ins made static so we can use them safely during init
    private static let builtIns: [String: [Float]] = [
        "Flat": [0, 0, 0, 0, 0],
        "Bass Boost": [6, 3, 0, -2, -4],
        "Vocal Boost": [-2, 1, 4, 3, 0],
        "Treble Boost": [-4, -2, 0, 2, 5],
        "Lo-Fi": [-8, -4, 0, 4, 8]
    ]
    private static let builtInNames: [String] = ["Flat", "Bass Boost", "Vocal Boost", "Treble Boost", "Lo-Fi"]

    // MARK: Init

    init() {
        let lastName = EQManager.shared.lastUsedPresetName
        let custom = EQManager.shared.loadCustomPresetNames()
        let startKind: PresetKind = custom.contains(lastName) ? .custom(lastName) : .builtIn(lastName)
        let startGains = EQManager.shared.getCurrentGains()
        let base = gainsForPreset(kind: startKind, customNames: custom, builtIns: Self.builtIns)

        _selectedPreset = State(initialValue: startKind)
        _gains = State(initialValue: startGains)
        _baselineGains = State(initialValue: base)
        _customNames = State(initialValue: custom)
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 18) {
                    banner

                    sectionHeader("Default Presets")
                    presetGrid(names: Self.builtInNames, isCustom: false)

                    sectionHeader("Your Presets")
                    if customNames.isEmpty {
                        Text("No custom presets yet.")
                            .foregroundColor(.secondary)
                            .font(.footnote)
                            .padding(.bottom, 8)
                    } else {
                        presetGrid(names: customNames, isCustom: true, showDelete: true)
                    }

                    Divider().padding(.top, 8)

                    sliders

                    actionButtons

                    Spacer(minLength: 12)
                }
                .padding(.vertical, 8)
                .padding(.horizontal)
            }
            .navigationTitle("Equalizer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        // If user made changes but didn’t save, revert to baseline on close
                        if isDirty { applyGains(baselineGains) }
                        dismiss()
                    }
                }
            }
            // Save new custom preset prompt
            .alert("Save Custom Preset", isPresented: $showingSavePrompt) {
                TextField("Preset Name", text: $newPresetName)
                Button("Save") { performSaveAsNew() }
                Button("Cancel", role: .cancel) { newPresetName = "" }
            } message: {
                Text("Name your new custom EQ preset.")
            }
            // Update current custom preset confirmation
            .alert("Update “\(selectedPreset.name)”?", isPresented: $pendingUpdateConfirm) {
                Button("Update", role: .destructive) { performUpdateCurrentCustom() }
                Button("Cancel", role: .cancel) { /* no-op */ }
            } message: {
                Text("This will overwrite the saved gains for this preset.")
            }
            // Delete preset confirmation
            .alert("Delete Preset", isPresented: Binding(
                get: { presetToDelete != nil },
                set: { newValue in if !newValue { presetToDelete = nil } }
            )) {
                Button("Delete", role: .destructive) {
                    if let p = presetToDelete { deletePreset(named: p) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to delete “\(presetToDelete ?? "")”?")
            }
        }
    }

    // MARK: - Subviews

    private var banner: some View {
        let name = selectedPreset.name
        let modified = isDirty ? " (modified)" : ""
        return Text("Current Preset: \(name)\(modified)")
            .font(.headline)
            .foregroundColor(.accentColor)
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(Color.accentColor.opacity(0.15))
            .clipShape(Capsule())
            .padding(.top, 6)
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.headline)
                .foregroundColor(.accentColor)
            Spacer()
        }
        .padding(.top, 8)
    }

    private func presetGrid(names: [String], isCustom: Bool, showDelete: Bool = false) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
            ForEach(names, id: \.self) { name in
                Button {
                    selectPreset(named: name, isCustom: isCustom)
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Text(name)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .frame(minWidth: 80, maxWidth: 120, minHeight: 40)
                            .padding(.vertical, 10)
                            .background(Color(UIColor.secondarySystemBackground))
                            .foregroundColor(isSelected(name: name, isCustom: isCustom) ? .accentColor : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(isSelected(name: name, isCustom: isCustom) ? Color.accentColor : Color.clear, lineWidth: 2)
                            )
                            .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 1)

                        if showDelete {
                            Button {
                                presetToDelete = name
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .imageScale(.small)
                                    .foregroundColor(.secondary)
                                    .padding(6)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    private var sliders: some View {
        VStack(spacing: 16) {
            ForEach(gains.indices, id: \.self) { i in
                HStack(spacing: 14) {
                    Text("\(Int(frequencies[i])) Hz")
                        .frame(width: 60, alignment: .leading)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Slider(value: $gains[i], in: -12...12, step: 0.5)
                        .tint(.accentColor)
                        .onChange(of: gains[i]) { _ in
                            // Important: do not change selectedPreset on tweak.
                            EQManager.shared.setBands(gains)
                            // Track last-used name so we persist resume behavior.
                            EQManager.shared.saveLastUsed(gains, presetName: selectedPreset.name)
                        }

                    Text("\(Int(gains[i])) dB")
                        .frame(width: 48, alignment: .trailing)
                        .font(.caption)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal)
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            // Built-in + modified → Save Custom
            if case .builtIn = selectedPreset, isDirty {
                Button {
                    newPresetName = ""
                    showingSavePrompt = true
                } label: {
                    Label("Save Custom Preset", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyleProminent()
                .disabled(customNames.count >= 3)
            }

            // Custom + modified → Update existing
            if case .custom = selectedPreset, isDirty {
                Button(role: .destructive) {
                    pendingUpdateConfirm = true
                } label: {
                    Label("Update “\(selectedPreset.name)”", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyleDanger()
            }

            // Revert (whenever modified)
            if isDirty {
                Button {
                    applyGains(baselineGains) // revert UI & EQ
                } label: {
                    Label("Revert Changes", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyleSecondary()
            }

            // Also allow “Save as Custom…” from a clean built-in, if space remains
            if case .builtIn = selectedPreset, !isDirty, customNames.count < 3 {
                Button {
                    newPresetName = ""
                    showingSavePrompt = true
                } label: {
                    Label("Save as Custom…", systemImage: "plus.square.on.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyleSecondary()
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Logic

    private var isDirty: Bool { gains != baselineGains }

    private func isSelected(name: String, isCustom: Bool) -> Bool {
        switch selectedPreset {
        case .builtIn(let n): return !isCustom && n == name
        case .custom(let n):  return isCustom && n == name
        }
    }

    private func selectPreset(named name: String, isCustom: Bool) {
        let kind: PresetKind = isCustom ? .custom(name) : .builtIn(name)
        selectedPreset = kind

        let presetGains = gainsForPreset(kind: kind,
                                         customNames: customNames,
                                         builtIns: Self.builtIns)
        applyGains(presetGains)
        baselineGains = presetGains

        EQManager.shared.saveLastUsed(presetGains, presetName: name)
    }

    private func performSaveAsNew() {
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard customNames.count < 3 else { return }

        EQManager.shared.savePreset(name: name, gains: gains)
        EQManager.shared.saveLastUsed(gains, presetName: name)

        customNames = EQManager.shared.loadCustomPresetNames()
        selectedPreset = .custom(name)
        baselineGains = gains
        showingSavePrompt = false
        newPresetName = ""
    }

    private func performUpdateCurrentCustom() {
        guard case .custom(let name) = selectedPreset else { return }
        EQManager.shared.savePreset(name: name, gains: gains)
        EQManager.shared.saveLastUsed(gains, presetName: name)
        baselineGains = gains
        pendingUpdateConfirm = false
    }

    private func deletePreset(named name: String) {
        EQManager.shared.deleteCustomPreset(named: name)
        customNames = EQManager.shared.loadCustomPresetNames()

        if case .custom(let current) = selectedPreset, current == name {
            let fallback = "Flat"
            selectedPreset = .builtIn(fallback)
            let fallbackGains = Self.builtIns[fallback] ?? [0,0,0,0,0]
            applyGains(fallbackGains)
            baselineGains = fallbackGains
            EQManager.shared.saveLastUsed(fallbackGains, presetName: fallback)
        }

        presetToDelete = nil
    }

    private func applyGains(_ values: [Float]) {
        gains = values
        EQManager.shared.setBands(values)
    }
}

// MARK: - Button styles

private extension Button {
    func buttonStyleProminent() -> some View {
        self.padding()
            .background(Color.accentColor)
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
    }
    func buttonStyleSecondary() -> some View {
        self.padding()
            .background(Color.accentColor.opacity(0.12))
            .foregroundColor(.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    func buttonStyleDanger() -> some View {
        self.padding()
            .background(Color.red.opacity(0.15))
            .foregroundColor(.red)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
