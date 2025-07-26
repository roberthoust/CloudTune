//
//  AudioLevelMonitor.swift
//  CloudTune
//
//  Created by Robert Houst on 7/26/25.
//


import Foundation
import AVFoundation
import Combine

class AudioLevelMonitor: ObservableObject {
    static let shared = AudioLevelMonitor()

    private var cancellable: AnyCancellable?
    private var timer: Timer?
    private var tapInstalled = false

    @Published var level: Float = 0.0

    func startMonitoring(from node: AVAudioNode, bus: AVAudioNodeBus = 0) {
        guard !tapInstalled else { return }
        let format = node.outputFormat(forBus: bus)

        node.installTap(onBus: bus, bufferSize: 1024, format: format) { buffer, _ in
            guard let channelData = buffer.floatChannelData?[0] else { return }

            let frameLength = Int(buffer.frameLength)
            let strideVal = buffer.stride

            let rms: Float = {
                let samples = stride(from: 0, to: frameLength, by: strideVal).map {
                    channelData[$0]
                }
                let meanSquare = samples.reduce(0) { $0 + $1 * $1 } / Float(frameLength)
                return sqrt(meanSquare)
            }()

            let avgPower = 20 * log10(rms)
            let normalizedLevel = max(0.0, min(1.0, (avgPower + 50) / 50)) // Normalize to 0–1
            DispatchQueue.main.async {
                self.level = normalizedLevel
            }
        }

        tapInstalled = true
    }

    func stopMonitoring(from node: AVAudioNode, bus: AVAudioNodeBus = 0) {
        node.removeTap(onBus: bus)
        tapInstalled = false
    }
}