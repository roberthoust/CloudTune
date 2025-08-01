import SwiftUI

struct EQSettingsView: View {
    @Environment(\.dismiss) var dismiss
    @State private var selectedPreset: String? = EQManager.shared.lastUsedPresetName
    @State private var gains: [Float] = EQManager.shared.getCurrentGains()

    @State private var showingSavePrompt = false
    @State private var newPresetName = ""
    @State private var showingDeleteConfirmation = false
    @State private var presetToDelete: String? = nil

    @State private var refreshID = UUID()

    private let frequencies: [Float] = [60, 250, 1000, 4000, 8000]

    private var builtInPresets: [String] {
        ["Flat", "Bass Boost", "Vocal Boost", "Treble Boost", "Lo-Fi"]
    }

    private var customPresets: [String] {
        EQManager.shared.loadCustomPresetNames()
    }

    private var presetNames: [String] {
        _ = refreshID // triggers SwiftUI to recompute
        return builtInPresets + customPresets
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Preset Grid
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                        ForEach(presetNames, id: \.self) { preset in
                            ZStack(alignment: .topTrailing) {
                                Button(action: {
                                    selectedPreset = preset
                                    gains = EQManager.shared.loadPreset(named: preset)
                                    EQManager.shared.setBands(gains)
                                    EQManager.shared.saveLastUsed(gains, presetName: preset)
                                }) {
                                    Text(preset)
                                        .font(.caption)
                                        .frame(minWidth: 80, idealWidth: 100, maxWidth: 120, minHeight: 40)
                                        .background(.ultraThinMaterial)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(selectedPreset == preset ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: 1.5)
                                        )
                                        .foregroundColor(selectedPreset == preset ? .accentColor : .primary)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        .shadow(radius: 3)
                                }
                                if customPresets.contains(preset) {
                                    Button(action: {
                                        presetToDelete = preset
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .resizable()
                                            .frame(width: 16, height: 16)
                                            .foregroundColor(.red)
                                            .background(Color.white.clipShape(Circle()))
                                            .padding(4)
                                            .transition(.scale.combined(with: .opacity))
                                    }
                                    .offset(x: 4, y: -4)
                                    .alert("Delete Preset", isPresented: Binding(
                                        get: { presetToDelete == preset },
                                        set: { newValue in
                                            if !newValue { presetToDelete = nil }
                                        }
                                    )) {
                                        Button("Delete", role: .destructive) {
                                            withAnimation {
                                                EQManager.shared.deleteCustomPreset(named: preset)
                                                if selectedPreset == preset {
                                                    selectedPreset = nil
                                                    gains = [0, 0, 0, 0, 0]
                                                    EQManager.shared.setBands(gains)
                                                    EQManager.shared.saveLastUsed(gains, presetName: nil)
                                                }
                                                refreshID = UUID()
                                            }
                                            #if canImport(UIKit)
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                            #endif
                                        }
                                        Button("Cancel", role: .cancel) {}
                                    } message: {
                                        Text("Are you sure you want to delete \"\(preset)\"?")
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                    .animation(.spring(), value: customPresets)

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
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                    .padding(.horizontal)
                    .disabled(EQManager.shared.loadCustomPresetNames().count >= 3)

                    Spacer()
                }
                .padding(.vertical)
                .background(.ultraThinMaterial)
                .cornerRadius(16)
                .padding()
            }
            .navigationTitle("Equalizer")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Equalizer").font(.title2.bold())
                }
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
