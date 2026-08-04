import SwiftUI

struct BestTranscriptionProgressView: View {
    let progress: BestTranscriptionProgress
    let onCancel: () -> Void
    let onHide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text("Creating best transcript")
                    .font(.title2.weight(.semibold))
            }

            Text("Whisper is reprocessing the full recording on this Mac. Nothing is uploaded.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text(progress.stage.title)
                    .font(.headline)
                ProgressView(value: progress.fraction)
                    .accessibilityLabel(progress.stage.title)
                    .accessibilityValue("\(Int(progress.fraction * 100)) percent")
                HStack {
                    if progress.totalDuration > 0 {
                        Text(
                            "\(format(progress.processedDuration)) of \(format(progress.totalDuration))"
                        )
                    } else {
                        Text("\(Int(progress.fraction * 100))%")
                    }
                    Spacer()
                    if let remaining = progress.estimatedRemaining,
                       remaining.isFinite,
                       remaining > 1 {
                        Text("About \(format(remaining)) remaining")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }

            if let warning = progress.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            if let error = progress.error,
               progress.stage == .failed || progress.stage == .interrupted {
                Label(error, systemImage: "xmark.circle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityAddTraits(.isHeader)
            }

            HStack {
                if progress.isRunning {
                    Button("Cancel", role: .destructive, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                Button(progress.isRunning ? "Continue in Background" : "Close") {
                    onHide()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func format(_ seconds: TimeInterval) -> String {
        let safe = max(0, seconds)
        let hours = Int(safe) / 3600
        let minutes = (Int(safe) % 3600) / 60
        let seconds = Int(safe) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
