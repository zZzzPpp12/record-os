import SwiftUI

struct PageHeading: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 25, weight: .semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct RecordingPulseDot: View {
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.red.opacity(0.28))
                .frame(width: 16, height: 16)
                .scaleEffect(isPulsing ? 1.35 : 0.85)
                .opacity(isPulsing ? 0.15 : 0.75)
            Circle()
                .fill(Color.red)
                .frame(width: 9, height: 9)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}

struct RecordingStatusBanner: View {
    let sourceSummary: String?
    let audioSummary: String
    let startedAt: Date
    let isStopping: Bool
    let onStop: () -> Void

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(startedAt))
            HStack(spacing: 12) {
                RecordingPulseDot()

                VStack(alignment: .leading, spacing: 2) {
                    Text("正在录制")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let sourceSummary {
                        Text("正在采集「\(sourceSummary)」· \(audioSummary)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("正在采集\(audioSummary)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text(elapsed.formattedDuration)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.1), in: Capsule())

                Button(action: onStop) {
                    Label(isStopping ? "正在保存…" : "停止录制", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
                .disabled(isStopping)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color.red.opacity(0.08))
            .overlay(alignment: .bottom) {
                Divider()
            }
        }
    }
}

extension Double {
    var formattedDuration: String {
        guard isFinite, self >= 0 else { return "00:00" }
        let totalSeconds = Int(self.rounded(.down))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
