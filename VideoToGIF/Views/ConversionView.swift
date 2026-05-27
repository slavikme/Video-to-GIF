import SwiftUI

/// View displayed during the video-to-GIF conversion process
struct ConversionView: View {
    /// The input video file being converted
    let inputURL: URL

    /// Current conversion progress (0.0 to 1.0)
    let progress: Double

    /// Human-readable status (e.g. "Downloading FFmpeg… 42%", "Converting to GIF…")
    let statusMessage: String

    /// Callback when cancel is requested
    let onCancel: () -> Void
    
    /// Animation state for the processing icon
    @State private var isAnimating = false
    
    var body: some View {
        VStack(spacing: 32) {
            // Animated processing icon
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 100, height: 100)
                
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 40, weight: .light))
                    .foregroundColor(.accentColor)
                    .rotationEffect(.degrees(isAnimating ? 360 : 0))
                    .animation(
                        .linear(duration: 2)
                        .repeatForever(autoreverses: false),
                        value: isAnimating
                    )
            }
            .onAppear {
                isAnimating = true
            }
            
            // File info and status
            VStack(spacing: 12) {
                Text(statusMessage)
                    .font(.title2)
                    .fontWeight(.medium)
                    .multilineTextAlignment(.center)

                Text(FileNaming.displayName(for: inputURL))
                    .font(.body)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            
            // Progress section
            VStack(spacing: 8) {
                // Progress bar
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 280)
                
                // Percentage text
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            
            // Cancel button
            Button(action: onCancel) {
                Text("Cancel")
                    .frame(width: 100)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

#Preview {
    ConversionView(
        inputURL: URL(fileURLWithPath: "/Users/test/video.mov"),
        progress: 0.45,
        statusMessage: "Converting to GIF…",
        onCancel: {}
    )
    .frame(width: 400, height: 350)
}

