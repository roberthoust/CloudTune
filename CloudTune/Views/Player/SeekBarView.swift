import SwiftUI
import UIKit

struct SeekBarView: View {
    @Binding var currentTime: Double
    var duration: Double
    var onSeek: (Double) -> Void

    // Visual constants
    private let barHeight: CGFloat = 6
    private let thumbSize: CGFloat = 20
    private let cornerRadius: CGFloat = 3

    // Drag state
    @GestureState private var isPressing: Bool = false
    @State private var isDragging: Bool = false
    @State private var dragProgress: CGFloat? = nil

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1) // avoid div-by-zero
            let safeDuration = max(duration, 0.0001)
            let liveProgress = CGFloat(min(max(currentTime / safeDuration, 0), 1))
            let effective = isDragging ? (dragProgress ?? liveProgress) : liveProgress
            let clamped = min(max(effective, 0), 1)
            let thumbX = clamped * width

            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: Color.gray.opacity(0.18), location: 0),
                                .init(color: Color.gray.opacity(0.28), location: 1)
                            ]),
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(height: barHeight)

                // Filled progress track
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: Color("appAccent").opacity(0.95), location: 0),
                                .init(color: Color("appAccent").opacity(0.70), location: 1)
                            ]),
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: max(thumbX, barHeight), height: barHeight) // never collapse to 0 for nicer look
                    .animation(isDragging ? nil : .interactiveSpring(response: 0.25, dampingFraction: 0.85), value: clamped)

                // Thumb
                Circle()
                    .fill(.ultraThickMaterial)
                    .overlay(
                        Circle().stroke(Color.white.opacity(0.9), lineWidth: 1)
                    )
                    .overlay(
                        Circle()
                            .stroke(Color("appAccent"), lineWidth: isDragging ? 2 : 1)
                            .blur(radius: isDragging ? 0.2 : 0)
                            .opacity(isDragging ? 0.9 : 0.7)
                    )
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: Color.black.opacity(0.15), radius: 3, x: 0, y: 1)
                    .contentShape(Rectangle()) // larger tap area with padding below
                    .offset(x: min(max(thumbX - thumbSize/2, 0), width - thumbSize))
                    .animation(isDragging ? nil : .interactiveSpring(response: 0.25, dampingFraction: 0.85), value: clamped)
            }
            .frame(height: max(barHeight, thumbSize))
            .padding(.vertical, 6) // nicer touch target
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressing) { _, state, _ in
                        if state == false { state = true }
                    }
                    .onChanged { value in
                        isDragging = true
                        let pos = min(max(value.location.x, 0), width)
                        let p = pos / width
                        dragProgress = p
                    }
                    .onEnded { value in
                        let pos = min(max(value.location.x, 0), width)
                        let p = pos / width
                        let newTime = Double(p) * safeDuration
                        // Update binding without animation to avoid rubber-band glitch
                        withTransaction(Transaction(animation: nil)) {
                            currentTime = newTime
                        }
                        dragProgress = nil
                        isDragging = false
                        onSeek(newTime)

                        // Subtle haptic on commit
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
            )
            // Allow single-tap seek (no drag)
            .simultaneousGesture(
                TapGesture()
                    .onEnded {
                        isDragging = true
                        defer { isDragging = false; dragProgress = nil }
                        // Use the most recent cursor position from the system via geo frame center (approx hit)
                        // Because TapGesture doesn't give location, we approximate by using the OS hit rect center.
                        // Users typically tap near the thumb; for precise taps, they can drag.
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Playback position")
            .accessibilityValue(accessibilityTime(clamped * safeDuration))
            .accessibilityAdjustableAction { direction in
                let step = safeDuration * 0.05 // 5% step
                var new = currentTime
                switch direction {
                case .increment: new = min(currentTime + step, safeDuration)
                case .decrement: new = max(currentTime - step, 0)
                @unknown default: break
                }
                withTransaction(Transaction(animation: .easeOut(duration: 0.15))) {
                    currentTime = new
                }
                onSeek(new)
            }
        }
        .frame(height: max(barHeight, thumbSize) + 12)
    }

    private func accessibilityTime(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let mins = s / 60
        let secs = s % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
