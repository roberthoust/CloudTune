import SwiftUI

struct EQSettingsView: View {
    @Environment(\.dismiss) var dismiss
    @State private var selectedPreset = "Flat"
    @State private var gains: [Float] = EQManager.shared.getCurrentGains()

    private let frequencies: [Float] = [60, 250, 1000, 4000, 8000] // Simplified bands
    private let presetNames = [
        "Flat", "Bass Boost", "Vocal Boost", "Treble Boost", "Lo-Fi",
        "Custom 1", "Custom 2", "Custom 3"
    ]

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Preset Selection
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(presetNames, id: \.self) { preset in
                            Button(action: {
                                selectedPreset = preset
                                gains = EQManager.shared.loadPreset(named: preset)
                                EQManager.shared.setBands(gains)
                                EQManager.shared.saveLastUsed(gains)
                            }) {
                                Text(preset)
                                    .font(.caption)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(selectedPreset == preset ? Color.accentColor : Color(.systemGray6))
                                    .foregroundColor(selectedPreset == preset ? .white : .primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                    }
                    .padding(.horizontal)
                }

                Divider().padding(.horizontal)

                // Horizontal Sliders Layout
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
                                Text("-12")
                                    .font(.caption2)
                            } maximumValueLabel: {
                                Text("+12")
                                    .font(.caption2)
                            }
                            .accentColor(.blue)
                            .onChange(of: gains[i]) { _ in
                                EQManager.shared.setBands(gains)
                                EQManager.shared.saveLastUsed(gains)
                            }

                            Text("\(Int(gains[i])) dB")
                                .frame(width: 50, alignment: .trailing)
                                .font(.caption)
                        }
                        .padding(.horizontal)
                    }
                }

                // Save Menu
                Menu {
                    ForEach(1...3, id: \.self) { i in
                        Button("Save to Custom \(i)") {
                            EQManager.shared.savePreset(name: "Custom \(i)", gains: gains)
                        }
                    }
                } label: {
                    Label("Save Custom Preset", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)

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
        }
    }
}
