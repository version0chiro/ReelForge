@preconcurrency import AVFoundation
import CoreImage
import CoreVideo
import Foundation

final class ReelVideoInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = true
    let containsTweening = false
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let sourceTrackID: CMPersistentTrackID
    let preferredTransform: CGAffineTransform
    let displaySize: CGSize
    let cropCenter: CGFloat
    let framing: FramingMode
    let quality: OutputQuality

    init(
        timeRange: CMTimeRange,
        sourceTrackID: CMPersistentTrackID,
        preferredTransform: CGAffineTransform,
        displaySize: CGSize,
        cropCenter: CGFloat,
        framing: FramingMode,
        quality: OutputQuality
    ) {
        self.timeRange = timeRange
        self.sourceTrackID = sourceTrackID
        self.requiredSourceTrackIDs = [NSNumber(value: sourceTrackID)]
        self.preferredTransform = preferredTransform
        self.displaySize = displaySize
        self.cropCenter = cropCenter
        self.framing = framing
        self.quality = quality
        super.init()
    }
}

final class ReelVideoCompositor: NSObject, AVVideoCompositing {
    let sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [
            kCVPixelFormatType_32BGRA,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ],
    ]

    let requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    private let renderQueue = DispatchQueue(
        label: "com.reelforge.video-compositor",
        qos: .userInitiated
    )
    private let contextLock = NSLock()
    private var renderContext: AVVideoCompositionRenderContext?
    private let ciContext = CIContext(options: [
        .cacheIntermediates: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB) as Any,
    ])
    private let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        contextLock.lock()
        renderContext = newRenderContext
        contextLock.unlock()
    }

    func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [weak self] in
            self?.render(asyncVideoCompositionRequest)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        renderQueue.sync(flags: .barrier) {}
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? ReelVideoInstruction else {
            request.finish(with: ReelForgeError.exportFailed("Invalid video composition instruction"))
            return
        }
        guard let sourceBuffer = request.sourceFrame(byTrackID: instruction.sourceTrackID) else {
            request.finish(with: ReelForgeError.exportFailed("A source frame was unavailable"))
            return
        }

        contextLock.lock()
        let currentContext = renderContext
        contextLock.unlock()
        guard let outputBuffer = currentContext?.newPixelBuffer() else {
            request.finish(with: ReelForgeError.exportFailed("Could not allocate an output frame"))
            return
        }

        let targetSize = currentContext?.size ?? instruction.quality.renderSize
        let target = CGRect(origin: .zero, size: targetSize)
        var source = CIImage(cvPixelBuffer: sourceBuffer)
            .transformed(by: instruction.preferredTransform)
        let transformedExtent = source.extent.standardized
        source = source.transformed(
            by: CGAffineTransform(
                translationX: -transformedExtent.minX,
                y: -transformedExtent.minY
            )
        )
        source = source.cropped(to: CGRect(origin: .zero, size: transformedExtent.size))

        let composed = compose(
            source: source,
            target: target,
            cropCenter: instruction.cropCenter,
            framing: instruction.framing,
            quality: instruction.quality
        )
        ciContext.render(
            composed,
            to: outputBuffer,
            bounds: target,
            colorSpace: outputColorSpace
        )
        request.finish(withComposedVideoFrame: outputBuffer)
    }

    private func compose(
        source: CIImage,
        target: CGRect,
        cropCenter: CGFloat,
        framing: FramingMode,
        quality: OutputQuality
    ) -> CIImage {
        let sourceSize = source.extent.size
        let sourceAspect = sourceSize.width / max(1, sourceSize.height)
        let targetAspect = target.width / target.height
        let cropScale = sourceAspect > targetAspect
            ? target.height / sourceSize.height
            : target.width / sourceSize.width
        let adaptiveFit = sourceAspect > targetAspect
            && (sourceSize.height < 720 || cropScale > 2.45)
        let resolvedFraming: FramingMode = {
            switch framing {
            case .adaptive: adaptiveFit ? .fit : .crop
            case .crop: .crop
            case .fit: .fit
            }
        }()

        let result: CIImage
        if resolvedFraming == .fit {
            let coverScale = max(
                target.width / sourceSize.width,
                target.height / sourceSize.height
            ) * 1.06
            let cover = place(
                scale(source, by: coverScale),
                x: (target.width - sourceSize.width * coverScale) / 2,
                y: (target.height - sourceSize.height * coverScale) / 2
            )
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: max(18, target.width * 0.032),
            ])
            .cropped(to: target)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: -0.12,
                kCIInputContrastKey: 0.9,
                kCIInputSaturationKey: 0.82,
            ])
            let shade = CIImage(
                color: CIColor(red: 0.01, green: 0.015, blue: 0.025, alpha: 0.24)
            ).cropped(to: target)
            let background = shade.composited(over: cover)

            let containScale = min(
                target.width / sourceSize.width,
                target.height / sourceSize.height
            )
            let foreground = place(
                scale(source, by: containScale),
                x: (target.width - sourceSize.width * containScale) / 2,
                y: (target.height - sourceSize.height * containScale) / 2
            )
            result = foreground.composited(over: background)
        } else {
            let scaled = scale(source, by: cropScale)
            let scaledWidth = sourceSize.width * cropScale
            let scaledHeight = sourceSize.height * cropScale
            let desiredX = target.midX - min(0.96, max(0.04, cropCenter)) * scaledWidth
            let x = min(0, max(target.width - scaledWidth, desiredX))
            let y = (target.height - scaledHeight) / 2
            result = place(scaled, x: x, y: y).cropped(to: target)
        }

        guard quality == .enhanced else { return result.cropped(to: target) }
        return result
            .applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.035,
                kCIInputSaturationKey: 1.045,
            ])
            .applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: 0.22,
            ])
            .cropped(to: target)
    }

    private func scale(_ image: CIImage, by value: CGFloat) -> CIImage {
        guard abs(value - 1) > 0.001 else { return image }
        return image.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: value,
            kCIInputAspectRatioKey: 1,
        ])
    }

    private func place(_ image: CIImage, x: CGFloat, y: CGFloat) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: x, y: y))
    }
}
