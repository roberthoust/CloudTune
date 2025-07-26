import SwiftUI

struct SeekBarView: View {
    @Binding var currentTime: Double
    var duration: Double
    var onSeek: (Double) -> Void

    @State private var isDragging = false
    @State private var dragPosition: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let barWidth = geometry.size.width
            let progress = CGFloat(currentTime / max(duration, 0.01))
            let effectiveProgress = isDragging ? (dragPosition ?? progress) : progress

            ZStack(alignment: .leading) {
                // Background bar
                Capsule()
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 6)

                // Progress bar (live or preview)
                Capsule()
                    .fill(Color("appAccent"))
                    .frame(width: effectiveProgress * barWidth, height: 6)
                    .animation(.easeOut(duration: 0.2), value: effectiveProgress)

                // Thumb
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color("appAccent"), lineWidth: 2))
                    .frame(width: 22, height: 22)
                    .offset(x: max(0, min(effectiveProgress * barWidth - 11, barWidth - 22)))
                    .shadow(radius: 1)
                    .animation(.easeOut(duration: 0.2), value: effectiveProgress)
            }
            .frame(height: 24)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let clamped = min(max(0, value.location.x / barWidth), 1)
                        dragPosition = clamped
                    }
                    .onEnded { value in
                        let clamped = min(max(0, value.location.x / barWidth), 1)
                        let newTime = clamped * duration
                        currentTime = newTime
                        dragPosition = nil
                        isDragging = false
                        onSeek(newTime)
                    }
            )
        }
        .frame(height: 24)
    }
}
