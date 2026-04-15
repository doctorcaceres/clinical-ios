import SwiftUI

/// Animated green record button — pulses while recording.
struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            ZStack {
                // Pulse ring (recording only)
                if isRecording {
                    Circle()
                        .stroke(C.accent.opacity(pulse ? 0 : 0.4), lineWidth: 2)
                        .frame(width: 96, height: 96)
                        .scaleEffect(pulse ? 1.4 : 1.0)
                        .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: pulse)
                }

                Circle()
                    .fill(C.accent)
                    .frame(width: 80, height: 80)

                if isRecording {
                    // Red dot
                    Circle()
                        .fill(C.error)
                        .frame(width: 14, height: 14)
                } else {
                    // Inner circle
                    Circle()
                        .fill(Color.black.opacity(0.3))
                        .frame(width: 28, height: 28)
                }
            }
        }
        .buttonStyle(PressStyle())
        .onAppear { if isRecording { pulse = true } }
        .onChange(of: isRecording) { new in pulse = new }
    }
}

/// Waveform visualization driven by metering level.
struct WaveformView: View {
    let metering: Float
    @State private var levels: [CGFloat] = Array(repeating: 0.05, count: 32)

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<levels.count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(C.accent.opacity(0.5))
                    .frame(width: 3, height: max(3, levels[i] * 36))
            }
        }
        .frame(height: 40)
        .onChange(of: metering) { val in
            let norm = CGFloat(max(0, (val + 60) / 60))
            levels.removeFirst()
            levels.append(max(0.05, norm))
        }
    }
}
