import SwiftUI

struct MosaicOverlayEditor: View {
    let videoSize: CGSize
    let regions: [MosaicRegion]
    @Binding var selectedRegionID: UUID?
    let currentTime: Double
    let isDrawMode: Bool
    var onCreateRegion: (NormalizedRect) -> Void
    var onBeginEdit: () -> Void
    var onUpdateRect: (UUID, NormalizedRect) -> Void
    var onEndEdit: () -> Void
    var onSelectRegion: (UUID?) -> Void

    @State private var draftOrigin: CGPoint?
    @State private var draftCurrent: CGPoint?
    @State private var dragStartRects: [UUID: NormalizedRect] = [:]

    var body: some View {
        GeometryReader { geometry in
            let frame = fittedVideoRect(in: geometry.size, videoSize: videoSize)

            ZStack(alignment: .topLeading) {
                Color.clear

                if frame.width > 0 && frame.height > 0 {
                    ZStack(alignment: .topLeading) {
                        if isDrawMode {
                            Color.black.opacity(0.08)
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 4)
                                        .onChanged { value in
                                            let clampedStart = clampPoint(value.startLocation, inside: frame.size)
                                            let clampedCurrent = clampPoint(value.location, inside: frame.size)
                                            draftOrigin = clampedStart
                                            draftCurrent = clampedCurrent
                                        }
                                        .onEnded { value in
                                            let p1 = clampPoint(value.startLocation, inside: frame.size)
                                            let p2 = clampPoint(value.location, inside: frame.size)
                                            draftOrigin = nil
                                            draftCurrent = nil

                                            let minX = min(p1.x, p2.x)
                                            let minY = min(p1.y, p2.y)
                                            let width = abs(p2.x - p1.x)
                                            let height = abs(p2.y - p1.y)
                                            guard width >= 10, height >= 10 else { return }

                                            let normalized = NormalizedRect(
                                                x: minX / frame.width,
                                                y: minY / frame.height,
                                                width: width / frame.width,
                                                height: height / frame.height
                                            ).clamped()
                                            onCreateRegion(normalized)
                                        }
                                )
                        }

                        if let origin = draftOrigin, let current = draftCurrent {
                            let rect = CGRect(
                                x: min(origin.x, current.x),
                                y: min(origin.y, current.y),
                                width: abs(current.x - origin.x),
                                height: abs(current.y - origin.y)
                            )
                            Rectangle()
                                .fill(Color.orange.opacity(0.22))
                                .overlay(
                                    Rectangle()
                                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                                )
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                        }

                        ForEach(regions.filter { $0.isActive(at: currentTime) || $0.id == selectedRegionID }) { region in
                            regionBox(for: region, in: frame.size)
                        }
                    }
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .clipped()
                }
            }
        }
    }

    @ViewBuilder
    private func regionBox(for region: MosaicRegion, in size: CGSize) -> some View {
        let isSelected = region.id == selectedRegionID
        let isActive = region.isActive(at: currentTime)
        let boxWidth = max(16, region.rect.width * size.width)
        let boxHeight = max(16, region.rect.height * size.height)
        let centerX = (region.rect.x + region.rect.width / 2) * size.width
        let centerY = (region.rect.y + region.rect.height / 2) * size.height

        ZStack(alignment: .bottomTrailing) {
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .overlay(
                    Rectangle()
                        .stroke(
                            isSelected ? Color.orange : Color.white.opacity(isActive ? 0.75 : 0.35),
                            style: StrokeStyle(
                                lineWidth: isSelected ? 2 : 1.2,
                                dash: isActive ? [] : [4, 4]
                            )
                        )
                )
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            if dragStartRects[region.id] == nil {
                                onBeginEdit()
                                onSelectRegion(region.id)
                                dragStartRects[region.id] = region.rect
                            }
                            let base = dragStartRects[region.id] ?? region.rect
                            let dx = value.translation.width / max(size.width, 1)
                            let dy = value.translation.height / max(size.height, 1)
                            let updated = NormalizedRect(
                                x: base.x + dx,
                                y: base.y + dy,
                                width: base.width,
                                height: base.height
                            ).clamped()
                            onUpdateRect(region.id, updated)
                        }
                        .onEnded { _ in
                            dragStartRects.removeValue(forKey: region.id)
                            onEndEdit()
                        }
                )
                .onTapGesture {
                    onSelectRegion(region.id)
                }

            if isSelected {
                Circle()
                    .fill(Color.orange)
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                    .frame(width: 12, height: 12)
                    .padding(2)
                    .offset(x: 6, y: 6)
                    .contentShape(Rectangle().size(width: 24, height: 24))
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                if dragStartRects[region.id] == nil {
                                    onBeginEdit()
                                    dragStartRects[region.id] = region.rect
                                }
                                let base = dragStartRects[region.id] ?? region.rect
                                let dw = value.translation.width / max(size.width, 1)
                                let dh = value.translation.height / max(size.height, 1)
                                let maxW = 1.0 - base.x
                                let maxH = 1.0 - base.y
                                let updated = NormalizedRect(
                                    x: base.x,
                                    y: base.y,
                                    width: min(max(base.width + dw, 0.03), maxW),
                                    height: min(max(base.height + dh, 0.03), maxH)
                                ).clamped()
                                onUpdateRect(region.id, updated)
                            }
                            .onEnded { _ in
                                dragStartRects.removeValue(forKey: region.id)
                            }
                    )
                    .help("拖动调整马赛克区域大小")
            }
        }
        .frame(width: boxWidth, height: boxHeight)
        .position(x: centerX, y: centerY)
    }

    private func clampPoint(_ point: CGPoint, inside size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), size.width),
            y: min(max(point.y, 0), size.height)
        )
    }

    private func fittedVideoRect(in container: CGSize, videoSize: CGSize) -> CGRect {
        guard container.width > 0, container.height > 0,
              videoSize.width > 0, videoSize.height > 0 else {
            return .zero
        }
        let scale = min(container.width / videoSize.width, container.height / videoSize.height)
        let width = videoSize.width * scale
        let height = videoSize.height * scale
        let originX = (container.width - width) / 2
        let originY = (container.height - height) / 2
        return CGRect(x: originX, y: originY, width: width, height: height)
    }
}
