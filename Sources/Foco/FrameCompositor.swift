import CoreImage
import CoreVideo
import CoreGraphics

/// A reusable GPU-backed compositor. Call it only from the capture render queue.
final class FrameCompositor {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let colorAttachments: CFDictionary = [
        kCVImageBufferCGColorSpaceKey: colorSpace,
        kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
        kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_sRGB,
        kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2
    ] as CFDictionary
    private let canvas: CGRect
    private let background: CIImage
    private let geometry: RecordingGeometry
    private var screenEnabled: Bool
    private var cameraPlacement: CameraPlacement
    private var cameraRect: CGRect
    private var cameraMask: CIImage
    private var cameraBorder: CIImage
    private var cachedFrame: CVPixelBuffer?
    private var sourceChanged = true

    init(geometry: RecordingGeometry, corner: CameraCorner, placement: CameraPlacement? = nil, screenEnabled: Bool = true) {
        self.geometry = geometry
        self.screenEnabled = screenEnabled
        cameraPlacement = placement ?? .from(corner: corner)
        canvas = CGRect(origin: .zero, size: geometry.size)
        background = CIImage(color: .black).cropped(to: canvas)
        cameraRect = Self.compositeRect(cameraPlacement, geometry: geometry)
        let radius = min(20.0 * geometry.overlayScale, cameraRect.width * 0.07)
        let borderWidth = 2.0 * geometry.overlayScale
        cameraMask = Self.roundedRectangle(cameraRect, radius: radius, color: .white)
        cameraBorder = Self.roundedRectangle(cameraRect.insetBy(dx: -borderWidth, dy: -borderWidth), radius: radius + borderWidth,
                                             color: CIColor(red: 0.92, green: 0.96, blue: 1, alpha: 0.88))
    }

    /// Called only on the engine's render queue. Previous composites stay
    /// immutable so moving the overlay cannot alter frames already being saved.
    func setCameraPlacement(_ placement: CameraPlacement) {
        guard cameraPlacement != placement else { return }
        cameraPlacement = placement
        cameraRect = Self.compositeRect(placement, geometry: geometry)
        let radius = min(20.0 * geometry.overlayScale, cameraRect.width * 0.07)
        let borderWidth = 2.0 * geometry.overlayScale
        cameraMask = Self.roundedRectangle(cameraRect, radius: radius, color: .white)
        cameraBorder = Self.roundedRectangle(cameraRect.insetBy(dx: -borderWidth, dy: -borderWidth), radius: radius + borderWidth,
                                             color: CIColor(red: 0.92, green: 0.96, blue: 1, alpha: 0.88))
        invalidateFrame()
    }

    /// The transition changes only future surfaces. Buffers already held by the
    /// encoder or preview remain immutable, and disabled desktop pixels are ignored.
    func setScreenEnabled(_ enabled: Bool) {
        guard screenEnabled != enabled else { return }
        screenEnabled = enabled
        invalidateFrame()
    }

    private static func compositeRect(_ placement: CameraPlacement, geometry: RecordingGeometry) -> CGRect {
        let topLeft = placement.rect(in: geometry)
        return CGRect(x: topLeft.minX, y: CGFloat(geometry.height) - topLeft.maxY,
                      width: topLeft.width, height: topLeft.height)
    }

    func render(screen: CVPixelBuffer?, camera: CVPixelBuffer?, into destination: CVPixelBuffer) {
        var frame = background
        if screenEnabled, let screen {
            frame = Self.fit(CIImage(cvPixelBuffer: screen), into: canvas, fill: false).composited(over: background)
        }
        if let camera {
            let source = CIImage(cvPixelBuffer: camera)
            // Preview and recording share the same mirrored camera and framing.
            let mirrored = source.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1,
                                                                     tx: source.extent.width, ty: 0))
            if screenEnabled {
                let inset = Self.fit(mirrored, into: cameraRect, fill: true)
                let masked = inset.applyingFilter("CIBlendWithAlphaMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: cameraMask
                ])
                frame = masked.composited(over: cameraBorder.composited(over: frame))
            } else {
                // Fill the whole movie canvas without letterboxing, corners or
                // a border. No screen image participates in this composition.
                frame = Self.fit(mirrored, into: canvas, fill: true).composited(over: background)
            }
        }
        context.render(frame.cropped(to: canvas), to: destination, bounds: canvas, colorSpace: Self.colorSpace)
        // Core Image writes sRGB pixels but does not populate video color tags.
        // Tag the owned surface before publishing it to either renderer or
        // encoder so both interpret the same pixels using the same transfer.
        CVBufferSetAttachments(destination, Self.colorAttachments, .shouldPropagate)
    }

    /// A static desktop (or a 30 fps camera) does not need another GPU composition
    /// for every 60 fps output timestamp. Cached buffers remain immutable while
    /// AVAssetWriter or the preview holds them; a changed source gets a new buffer.
    func invalidateFrame() { sourceChanged = true }

    func frame(screen: CVPixelBuffer?, camera: CVPixelBuffer?, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        if !sourceChanged, let cachedFrame { return cachedFrame }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        render(screen: screen, camera: camera, into: buffer)
        cachedFrame = buffer
        sourceChanged = false
        return buffer
    }

    func preview(from buffer: CVPixelBuffer) -> CGImage? {
        // Diagnostic/legacy path only. Production hands the native-size surface
        // directly to the video renderer, without a CPU-sized image readback.
        let image = CIImage(cvPixelBuffer: buffer)
        return context.createCGImage(image, from: image.extent, format: .BGRA8, colorSpace: Self.colorSpace)
    }

    private static func fit(_ source: CIImage, into rect: CGRect, fill: Bool) -> CIImage {
        let extent = source.extent
        // The captured desktop and the output canvas have identical native
        // dimensions. Avoid even a nominal resampling transform for small text.
        if extent == rect { return source }
        // 4:2:0 encoding needs even dimensions. An unusual odd-size display
        // drops only its final row/column instead of resampling every pixel.
        if !fill, extent.origin == rect.origin,
           (0...1).contains(extent.width - rect.width),
           (0...1).contains(extent.height - rect.height) {
            return source.transformed(by: CGAffineTransform(translationX: 0, y: rect.height - extent.height))
                .cropped(to: rect)
        }
        let scale = fill ? max(rect.width / extent.width, rect.height / extent.height)
                         : min(rect.width / extent.width, rect.height / extent.height)
        let width = extent.width * scale, height = extent.height * scale
        let transform = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: rect.midX - width / 2, y: rect.midY - height / 2))
        return source.transformed(by: transform).cropped(to: rect)
    }

    private static func roundedRectangle(_ rect: CGRect, radius: Double, color: CIColor) -> CIImage {
        let filter = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect), "inputRadius": radius, "inputColor": color
        ])!
        return filter.outputImage!.cropped(to: rect)
    }
}

/// Keep image readback off the recording queue and its rendering context.
/// The engine only schedules one preview at a time, so this cannot build a backlog.
final class FramePreviewRenderer {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var previousBuffer: CVPixelBuffer?
    private var previousImage: CGImage?

    /// Input composites are immutable while retained. Reuse their image when a
    /// static screen or lower-rate camera repeats on the 60 Hz output timeline.
    /// Only the preview queue accesses this cache.
    func image(from buffer: CVPixelBuffer) -> CGImage? {
        if let previousBuffer, previousBuffer === buffer { return previousImage }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let result = context.createCGImage(image, from: image.extent, format: .BGRA8, colorSpace: colorSpace) else { return nil }
        previousBuffer = buffer
        previousImage = result
        return result
    }
}
