import SwiftUI

struct TimelineRangeSlider: View {
    let duration: Double
    @Binding var rangeStart: Double
    @Binding var rangeEnd: Double
    let playhead: Double
    var onSeek: (Double) -> Void
    var onScrubStateChanged: ((Bool) -> Void)?

    private let minGap: Double = 0.1
    private let inset: CGFloat = 14
    private let trackHeight: CGFloat = 10
    private let splitHandleWidth: CGFloat = 14
    private let splitHandleHeight: CGFloat = 26
    private let splitHitWidth: CGFloat = 28
    private let totalHeight: CGFloat = 34

    var body: some View {
        GeometryReader { geometry in
            let usable = max(geometry.size.width - inset * 2, 1)
            let startX = inset + x(for: rangeStart, usable: usable)
            let endX = inset + x(for: rangeEnd, usable: usable)
            let headX = inset + x(for: playhead, usable: usable)
            let progressEndX = min(max(headX, startX), endX)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: trackHeight)
                    .padding(.horizontal, inset)

                RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous)
                    .fill(Color.accentColor.opacity(0.24))
                    .frame(width: max(endX - startX, 2), height: trackHeight)
                    .offset(x: startX)

                if progressEndX > startX {
                    RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous)
                        .fill(Color.accentColor.opacity(0.75))
                        .frame(width: progressEndX - startX, height: trackHeight)
                        .offset(x: startX)
                }

                Rectangle()
                    .fill(Color.primary.opacity(0.001))
                    .contentShape(Rectangle())
                    .frame(height: totalHeight)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("rangeTrack"))
                            .onChanged { value in
                                onScrubStateChanged?(true)
                                let target = time(at: value.location.x, usable: usable)
                                let clamped = min(max(target, rangeStart), rangeEnd)
                                onSeek(clamped)
                            }
                            .onEnded { _ in
                                onScrubStateChanged?(false)
                            }
                    )

                splitHandle(at: startX, isStart: true, usable: usable)
                splitHandle(at: endX, isStart: false, usable: usable)
            }
            .frame(height: totalHeight)
            .coordinateSpace(name: "rangeTrack")
        }
        .frame(height: totalHeight)
        .opacity(duration > 0 ? 1 : 0.35)
        .allowsHitTesting(duration > 0)
    }

    private func splitHandle(at x: CGFloat, isStart: Bool, usable: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.accentColor)
                .frame(width: splitHandleWidth, height: splitHandleHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                )
                .overlay {
                    Image(systemName: isStart ? "chevron.compact.right" : "chevron.compact.left")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
                .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
        }
        .frame(width: splitHitWidth, height: totalHeight)
        .contentShape(Rectangle())
        .offset(x: x - splitHitWidth / 2)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("rangeTrack"))
                .onChanged { value in
                    onScrubStateChanged?(true)
                    let target = time(at: value.location.x, usable: usable)
                    if isStart {
                        let upper = max(0, rangeEnd - minGap)
                        let nextStart = min(max(0, target), upper)
                        rangeStart = nextStart
                        onSeek(nextStart)
                    } else {
                        let lower = min(duration, rangeStart + minGap)
                        let nextEnd = max(min(duration, target), lower)
                        rangeEnd = nextEnd
                        onSeek(nextEnd)
                    }
                }
                .onEnded { _ in
                    onScrubStateChanged?(false)
                }
        )
        .help(isStart ? "前分割点：拖动设置起始位置" : "后分割点：拖动设置结束位置")
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
