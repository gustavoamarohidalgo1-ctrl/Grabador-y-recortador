import Foundation
import CoreVideo
import CoreMedia
import Combine
import CoreGraphics

@main
struct PresentationPerformanceTest {
    @MainActor
    static func main() async throws {
        let presentation = CapturePresentation()
        let first = presentation.begin()
        let red = makeFrame()
        let green = makeFrame()
        var imageUpdates = 0
        var availabilityUpdates = 0
        var meterUpdates = 0
        let images = presentation.frames.sink { if $0 != nil { imageUpdates += 1 } }
        let availability = presentation.$hasPreview.dropFirst().sink { _ in availabilityUpdates += 1 }
        let meters = presentation.$levels.dropFirst().sink { _ in meterUpdates += 1 }
        // Simulate a temporarily occupied UI thread. No capture callback must wait
        // for it, retain all these images, or create one UI task per callback.
        for _ in 0..<999 {
            first.previews.yield(red)
            first.levels.yield(AudioMeterLevels(microphone: 0.1, system: 0.9))
        }
        first.previews.yield(green)
        first.levels.yield(AudioMeterLevels(microphone: 0.11, system: 0.91))
        try await waitUntil { presentation.preview?.buffer === green.buffer }
        try await waitUntil { presentation.levels.microphone == 1 && presentation.levels.system == 4 }
        precondition(imageUpdates == 1, "Buffered preview published every obsolete frame")
        precondition(meterUpdates == 1, "Buffered meters published obsolete values")
        precondition(availabilityUpdates == 1 && presentation.hasPreview, "Unexpected SwiftUI availability updates")
        first.levels.yield(AudioMeterLevels(microphone: 0.12, system: 0.95))
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(meterUpdates == 1, "Unchanged meter bars redrew the view")

        for _ in 0..<60 {
            first.previews.yield(green)
            await Task.yield()
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(imageUpdates == 1, "An unchanged immutable image redrew the view")

        // A full second of changing preview frames reaches the native subscriber
        // without publishing 60 observable image changes to the SwiftUI tree.
        for i in 0..<60 {
            let frame = i.isMultiple(of: 2) ? red : green
            first.previews.yield(frame)
            try await waitUntil { presentation.preview?.buffer === frame.buffer }
        }
        precondition(imageUpdates == 61, "Changing native preview frames were lost")
        precondition(availabilityUpdates == 1, "Each video frame invalidated SwiftUI")

        first.previews.yield(red)
        let second = presentation.begin()
        if case .terminated = first.previews.yield(red) {} else { fatalError("Old capture feed remained active") }
        second.previews.yield(green)
        try await waitUntil { presentation.preview?.buffer === green.buffer }
        presentation.end()
        if case .terminated = second.previews.yield(red) {} else { fatalError("Stopped capture feed remained active") }
        presentation.clearPreview()
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(presentation.preview == nil && !presentation.hasPreview && presentation.levels == .silent,
                     "Late event updated stopped UI")
        withExtendedLifetime((images, meters, availability)) {}

        let factory = PreviewSampleFactory()
        let sample = factory.sample(for: red)!
        precondition(CMSampleBufferGetImageBuffer(sample) === red.buffer, "Native sample copied the composed surface")
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as! [[String: Any]]
        precondition(attachments.first?[kCMSampleAttachmentKey_DisplayImmediately as String] as? Bool == true,
                     "Preview sample would queue on a playback timeline")
        factory.reset()
        precondition(factory.sample(for: green) != nil, "Format reset prevented subsequent preview")
        testNativeDetailAndColor(factory: factory)
        print("PASS: 1.000 frames se reducen al más reciente; 60 cambios llegan a la vista nativa con una sola actualización de disponibilidad SwiftUI.")
        print("PASS: superficies originales compartidas sin copia CGImage; presentación inmediata; sesiones cerradas rechazan frames tardíos.")
        print("PASS: detalle de un píxel y grises preservados a 2940×1912; vista previa nativa recibe etiquetas sRGB y primarias 709.")
    }

    static func testNativeDetailAndColor(factory: PreviewSampleFactory) {
        let width = 2940, height = 1912
        func buffer(width: Int, height: Int) -> CVPixelBuffer {
            var value: CVPixelBuffer?
            precondition(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &value) == kCVReturnSuccess)
            return value!
        }
        let source = buffer(width: width + 1, height: height + 1)
        CVBufferSetAttachment(source, kCVImageBufferCGColorSpaceKey,
                              CGColorSpace(name: CGColorSpace.sRGB)!, .shouldPropagate)
        CVPixelBufferLockBaseAddress(source, [])
        let bytes = CVPixelBufferGetBaseAddress(source)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(source)
        func gray(_ x: Int, _ y: Int) -> UInt8 {
            if y % 3 == 0 { return 38 }
            if y % 3 == 1 { return x.isMultiple(of: 2) ? 0 : 255 }
            return UInt8(x % 256)
        }
        for y in 0...height {
            for x in 0...width {
                let offset = y * stride + x * 4, value = gray(x, y)
                bytes[offset] = value; bytes[offset + 1] = value; bytes[offset + 2] = value
                bytes[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(source, [])
        let output = buffer(width: width, height: height)
        let compositor = FrameCompositor(geometry: RecordingGeometry(width: width, height: height), corner: .bottomRight)
        compositor.render(screen: source, camera: nil, into: output)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        let result = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(output)
        // Aligning an odd-size source drops its last row/column without
        // shifting the top-left origin or resampling one-pixel detail.
        for y in [0, 1, 2, height / 2, height - 2, height - 1] {
            for x in [0, 1, 2, 127, width / 2, width - 2, width - 1] {
                let offset = y * rowBytes + x * 4, expected = Int(gray(x, y))
                precondition(abs(Int(result[offset]) - expected) <= 1 &&
                             abs(Int(result[offset + 1]) - expected) <= 1 &&
                             abs(Int(result[offset + 2]) - expected) <= 1 && result[offset + 3] == 255,
                             "Native image was resampled or its gray levels changed")
            }
        }
        CVPixelBufferUnlockBaseAddress(output, .readOnly)
        let sample = factory.sample(for: PreviewVideoFrame(buffer: output))!
        precondition(CMSampleBufferGetImageBuffer(sample) === output, "Native preview copied the tagged surface")
        let format = CMSampleBufferGetFormatDescription(sample)!
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        precondition(dimensions.width == width && dimensions.height == height, "Native preview reduced image dimensions")
        let extensions = CMFormatDescriptionGetExtensions(format) as! [String: Any]
        precondition(extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String ==
                     kCVImageBufferTransferFunction_sRGB as String, "Preview lost the rendered sRGB transfer function")
        precondition(extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String ==
                     kCVImageBufferColorPrimaries_ITU_R_709_2 as String, "Preview lost its color primaries")
    }

    static func makeFrame() -> PreviewVideoFrame {
        var buffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer) == kCVReturnSuccess)
        return PreviewVideoFrame(buffer: buffer!)
    }

    @MainActor
    static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        fatalError("Presentation update timed out")
    }
}
