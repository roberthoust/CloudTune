import SwiftUI

struct EQSettingsView: View {
    @Environment(\.dismiss) var dismiss
    @State private var selectedPreset: String? = EQManager.shared.lastUsedPresetName
    @State private var gains: [Float] = EQManager.shared.getCurrentGains()

    @State private var showingSavePrompt = false
    @State private var newPresetName = ""

    @State private var refreshID = UUID()

    private let frequencies: [Float] = [60, 250, 1000, 4000, 8000]

    private var builtInPresets: [String] {
        ["Flat", "Bass Boost", "Vocal Boost", "Treble Boost", "Lo-Fi"]
    }

    private var presetNames: [String] {
        _ = refreshID // triggers SwiftUI to recompute
        return builtInPresets + EQManager.shared.loadCustomPresetNames()
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Preset Grid
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                    ForEach(presetNames, id: \.self) { preset in
                        Button(action: {
                            selectedPreset = preset
                            gains = EQManager.shared.loadPreset(named: preset)
                            EQManager.shared.setBands(gains)
                            EQManager.shared.saveLastUsed(gains, presetName: preset)
                        }) {
                            Text(preset)
                                .font(.caption2)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 6)
                                .frame(maxWidth: .infinity)
                                .background(selectedPreset == preset ? Color.accentColor : Color(.systemGray6))
                                .foregroundColor(selectedPreset == preset ? .white : .primary)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .contextMenu {
                            if !builtInPresets.contains(preset) {
                                Button(role: .destructive) {
                                    EQManager.shared.deleteCustomPreset(named: preset)
                                    if selectedPreset == preset {
                                        selectedPreset = nil
                                        gains = [0, 0, 0, 0, 0]
                                        EQManager.shared.setBands(gains)
                                        EQManager.shared.saveLastUsed(gains, presetName: nil)
                                    }
                                    refreshID = UUID()
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)

                Divider().padding(.horizontal)

                // EQ Sliders
                VStack(spacing: 18) {
                    ForEach(0..<gains.count, id: \.self) { i in
                        HStack(spacing: 14) {
                            Text("\(Int(frequencies[i])) Hz")
                                .frame(width: 60, alignment: .leading)
                                .font(.subheadline)
                                .foregroundColor(.secondary)

                            Slider(value: $gains[i], in: -12...12, step: 0.5) {
                                Text("Gain")
                            } minimumValueLabel: {
                                Text("-12").font(.caption2)
                            } maximumValueLabel: {
                                Text("+12").font(.caption2)
                            }
                            .tint(Color.accentColor)
                            .onChange(of: gains[i]) { _ in
                                selectedPreset = nil
                                EQManager.shared.setBands(gains)
                                EQManager.shared.saveLastUsed(gains, presetName: nil)
                            }

                            Text("\(Int(gains[i])) dB")
                                .frame(width: 50, alignment: .trailing)
                                .font(.caption)
                        }
                        .padding(.horizontal)
                    }
                }

                // Save Button
                Button {
                    showingSavePrompt = true
                    newPresetName = ""
                } label: {
                    Label("Save Custom Preset", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                .disabled(EQManager.shared.loadCustomPresetNames().count >= 3)

                Spacer()
            }
            .padding(.vertical)
            .navigationTitle("Equalizer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .alert("Save Custom Preset", isPresented: $showingSavePrompt) {
                TextField("Preset Name", text: $newPresetName)
                Button("Save") {
                    let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }

                    EQManager.shared.savePreset(name: name, gains: gains)
                    EQManager.shared.saveLastUsed(gains, presetName: name)
                    selectedPreset = name
                    refreshID = UUID()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Name your new custom EQ preset.")
            }
        }
    }
}
