import AVFoundation
import CoreImage
import Foundation

enum VideoMosaicCompositor {
    /// Loads the render size and frame rate for the given asset once so that
    /// repeated composition updates (e.g. while dragging a mosaic box) stay cheap.
    @MainActor
    static func renderInfo(for asset: AVAsset, frameRate: Int) async -> (size: CGSize, fps: Int32)? {
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
            return nil
        }
        let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
        let preferredTransform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
        let transformedSize = naturalSize.applying(preferredTransform)
        let width = max(2, Int(abs(transformedSize.width).rounded()))
        let height = max(2, Int(abs(transformedSize.height).rounded()))
        let fps = Int32(min(max(frameRate, 15), 60))
        return (CGSize(width: width, height: height), fps)
    }

    @MainActor
    static func makeVideoComposition(
        for asset: AVAsset,
        mosaicRegions: [MosaicRegion],
        renderInfo: (size: CGSize, fps: Int32)
    ) async -> AVVideoComposition? {
        let activeRegions = mosaicRegions.filter { $0.endTime > $0.startTime }
        guard !activeRegions.isEmpty else { return nil }

        let config = AVMutableVideoComposition(asset: asset) { request in
            let extent = request.sourceImage.extent
            let timeSeconds = request.compositionTime.seconds
            let matching = activeRegions.filter {
                timeSeconds >= $0.startTime.seconds && timeSeconds <= $0.endTime.seconds
            }

            guard !matching.isEmpty, extent.width > 0, extent.height > 0 else {
                request.finish(with: request.sourceImage, context: nil)
                return
            }

            var outputImage = request.sourceImage
            for region in matching {
                let rect = region.rect.clamped()
                let pixelW = max(4.0, rect.width * extent.width)
                let pixelH = max(4.0, rect.height * extent.height)
                let pixelX = extent.origin.x + rect.x * extent.width
                // Core Image origin is bottom-left; NormalizedRect uses top-left origin.
                let pixelY = extent.origin.y + (1.0 - rect.y - rect.height) * extent.height
                let mosaicRect = CGRect(x: pixelX, y: pixelY, width: pixelW, height: pixelH)
                    .intersection(extent)
                guard !mosaicRect.isEmpty else { continue }

                // Sample and pixellate only inside the target region so pixels from
                // outside the box never bleed into the mosaic edge.
                let regionSource = request.sourceImage
                    .cropped(to: mosaicRect)
                    .clampedToExtent()
                let scale = CGFloat(min(max(region.pixelScale, 8), 64))
                let pixelated = regionSource
                    .applyingFilter("CIPixellate", parameters: [
                        kCIInputScaleKey: scale,
                        kCIInputCenterKey: CIVector(x: mosaicRect.midX, y: mosaicRect.midY)
                    ])
                    .cropped(to: mosaicRect)

                outputImage = pixelated.composited(over: outputImage)
            }

            request.finish(with: outputImage.cropped(to: extent), context: nil)
        }
        config.renderSize = renderInfo.size
        config.frameDuration = CMTime(value: 1, timescale: renderInfo.fps)
        return config
    }
}
