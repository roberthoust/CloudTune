import SwiftUI

struct SeekBarView: View {
    @Binding var currentTime: Double
    var duration: Double
    var onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let percentage = CGFloat(currentTime / max(duration, 0.01))
            let barWidth = geometry.size.width

            ZStack(alignment: .leading) {
                // Background bar
                Capsule()
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 6)

                // Progress bar
                Capsule()
                    .fill(Color.blue)
                    .frame(width: percentage * barWidth, height: 6)

                // Thumb
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.blue, lineWidth: 2))
                    .frame(width: 14, height: 14)
                    .offset(x: max(0, min(percentage * barWidth - 7, barWidth - 14)))
                    .shadow(radius: 1)
            }
            .frame(height: 20)
            .contentShape(Rectangle()) // Makes the entire area tappable
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let clamped = min(max(0, value.location.x / barWidth), 1)
                        currentTime = clamped * duration
                    }
                    .onEnded { value in
                        let clamped = min(max(0, value.location.x / barWidth), 1)
                        let newTime = clamped * duration
                        currentTime = newTime
                        onSeek(newTime)
                    }
            )
        }
        .frame(height: 24)
    }
}
