import SwiftUI

struct TimelineRangeSlider: View {
    let duration: Double
    @Binding var rangeStart: Double
    @Binding var rangeEnd: Double
    let playhead: Double
    var onSeek: (Double) -> Void

    private let minGap: Double = 0.1
    private let inset: CGFloat = 10
    private let handleSize: CGFloat = 14
    private let handleHitSize: CGFloat = 26
    private let trackHeight: CGFloat = 6
    private let totalHeight: CGFloat = 26

    var body: some View {
        GeometryReader { geometry in
            let usable = max(geometry.size.width - inset * 2, 1)
            let startX = inset + x(for: rangeStart, usable: usable)
            let endX = inset + x(for: rangeEnd, usable: usable)
            let headX = inset + x(for: playhead, usable: usable)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: trackHeight)
                    .padding(.horizontal, inset)

                Capsule()
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: max(endX - startX, 2), height: trackHeight)
                    .offset(x: startX)

                Rectangle()
                    .fill(Color.primary.opacity(0.45))
                    .frame(width: 1.5, height: 16)
                    .offset(x: headX - 0.75)

                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .frame(height: totalHeight)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("rangeTrack"))
                            .onChanged { value in
                                onSeek(time(at: value.location.x, usable: usable))
                            }
                    )

                handle(at: startX, isStart: true, usable: usable)
                handle(at: endX, isStart: false, usable: usable)
            }
            .frame(height: totalHeight)
            .coordinateSpace(name: "rangeTrack")
        }
        .frame(height: totalHeight)
        .opacity(duration > 0 ? 1 : 0.35)
        .allowsHitTesting(duration > 0)
    }

    private func handle(at x: CGFloat, isStart: Bool, usable: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                .frame(width: handleSize, height: handleSize)
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
        }
        .frame(width: handleHitSize, height: handleHitSize)
        .contentShape(Rectangle())
        .offset(x: x - handleHitSize / 2)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("rangeTrack"))
                .onChanged { value in
                    let target = time(at: value.location.x, usable: usable)
                    if isStart {
                        rangeStart = min(max(0, target), max(0, rangeEnd - minGap))
                        onSeek(rangeStart)
                    } else {
                        rangeEnd = max(min(duration, target), min(duration, rangeStart + minGap))
                        onSeek(rangeEnd)
                    }
                }
        )
        .help(isStart ? "剪辑起点游标" : "剪辑终点游标")
    }

    private func x(for time: Double, usable: CGFloat) -> CGFloat {
        let clamped = min(max(time, 0), duration)
        return CGFloat(clamped / max(duration, 0.0001)) * usable
    }

    private func time(at x: CGFloat, usable: CGFloat) -> Double {
        let ratio = min(max((x - inset) / usable, 0), 1)
        return Double(ratio) * duration
    }
}
