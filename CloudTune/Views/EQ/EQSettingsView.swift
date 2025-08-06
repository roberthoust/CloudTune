import SwiftUI

struct EQSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedPreset: String = EQManager.shared.lastUsedPresetName
    @State private var gains: [Float] = EQManager.shared.getCurrentGains()
    
    @State private var showingSavePrompt = false
    @State private var newPresetName = ""
    @State private var presetToDelete: String? = nil
    
    private let frequencies: [Float] = [60, 250, 1000, 4000, 8000]
    private var builtInPresets: [String] = ["Flat", "Bass Boost", "Vocal Boost", "Treble Boost", "Lo-Fi"]
    private var customPresets: [String] { EQManager.shared.loadCustomPresetNames() }
    private var allPresets: [String] { builtInPresets + customPresets }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Selected Preset Banner
                    Text("Selected EQ Preset: \(selectedPreset)")
                        .font(.headline)
                        .foregroundColor(Color.accentColor)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                        .padding(.top, 10)

                    // Preset Buttons Grid (with highlight)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                        ForEach(allPresets, id: \.self) { preset in
                            Button(action: {
                                selectPreset(named: preset)
                            }) {
                                Text(preset)
                                    .font(.caption)
                                    .frame(minWidth: 80, idealWidth: 100, maxWidth: 120, minHeight: 40)
                                    .background(Color(UIColor.secondarySystemBackground))
                                    .foregroundColor(selectedPreset == preset ? Color.accentColor : .primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(selectedPreset == preset ? Color.accentColor : Color.clear, lineWidth: 2)
                                    )
                                    .shadow(color: Color.black.opacity(0.05), radius: 3, x: 0, y: 1)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.horizontal)
                    
                    Divider().padding(.horizontal)
                    
                    // EQ Sliders
                    VStack(spacing: 18) {
                        ForEach(gains.indices, id: \.self) { index in
                            HStack(spacing: 14) {
                                Text("\(Int(frequencies[index])) Hz")
                                    .frame(width: 60, alignment: .leading)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                
                                Slider(value: $gains[index], in: -12...12, step: 0.5)
                                    .tint(Color.accentColor)
                                    .onChange(of: gains[index]) { _ in
                                        EQManager.shared.setBands(gains)
                                        EQManager.shared.saveLastUsed(gains, presetName: nil)
                                    }
                                
                                Text("\(Int(gains[index])) dB")
                                    .frame(width: 50, alignment: .trailing)
                                    .font(.caption)
                            }
                            .padding(.horizontal)
                        }
                    }
                    
                    // Save Custom Preset Button
                    Button {
                        showingSavePrompt = true
                        newPresetName = ""
                    } label: {
                        Label("Save Custom Preset", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                    .padding(.horizontal)
                    .disabled(customPresets.count >= 3)
                    
                    Spacer()
                }
                .padding(.vertical)
                .background(Color(UIColor.systemBackground))
                .cornerRadius(16)
                .padding()
            }
            .navigationTitle("Equalizer")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Equalizer").font(.title2.bold())
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
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
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Name your new custom EQ preset.")
            }
            .alert("Delete Preset", isPresented: Binding(
                get: { presetToDelete != nil },
                set: { newValue in if !newValue { presetToDelete = nil } }
            )) {
                Button("Delete", role: .destructive) {
                    if let preset = presetToDelete {
                        deletePreset(named: preset)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to delete \"\(presetToDelete ?? "")\"?")
            }
        }
    }
    
    // MARK: - Helpers
    
    private func selectPreset(named preset: String) {
        selectedPreset = preset
        gains = EQManager.shared.loadPreset(named: preset)
        EQManager.shared.setBands(gains)
        EQManager.shared.saveLastUsed(gains, presetName: preset)
    }
    
    private func deletePreset(named preset: String) {
        EQManager.shared.deleteCustomPreset(named: preset)
        if selectedPreset == preset {
            selectedPreset = "Flat"
            gains = Array(repeating: 0, count: frequencies.count)
            EQManager.shared.setBands(gains)
            EQManager.shared.saveLastUsed(gains, presetName: nil)
        }
        presetToDelete = nil
    }
}
