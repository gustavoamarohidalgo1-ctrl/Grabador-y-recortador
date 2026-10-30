import Foundation
@preconcurrency import AVFoundation
import CoreGraphics
import CoreText
import CryptoKit

/// Synthetic screen and camera only. Does not request device permissions or
/// capture the user's desktop. Uses the production geometry, compositor,
/// encoder settings, preview sample factory and MP4 finalizer.
@main
enum NativeQualityTest {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw RecorderError.message("NATIVE TEST: \(message)") }
    }

    static func buffer(width: Int, height: Int, variant: Bool = false, camera: Bool = false) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result)
        guard status == kCVReturnSuccess, let result else { throw RecorderError.message("Missing synthetic surface") }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        CVBufferSetAttachment(result, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
        CVBufferSetAttachment(result, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(result, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVPixelBufferLockBaseAddress(result, [])
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        let row = CVPixelBufferGetBytesPerRow(result)
        let data = CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height { for x in 0..<width {
            let offset = y * row + x * 4
            let gray: UInt8 = camera ? UInt8(50 + x % 150) : 38
            data[offset] = camera ? 20 : gray
            data[offset + 1] = gray
            data[offset + 2] = camera ? 220 : gray
            data[offset + 3] = 255
        } }
        if !camera {
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            let context = CGContext(data: data, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: row, space: colorSpace, bitmapInfo: bitmapInfo)!
            context.setFillColor(CGColor(gray: 0.95, alpha: 1))
            for (line, fontSize) in [12.0, 16.0, 22.0, 32.0].enumerated() {
                let font = CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
                let text = NSAttributedString(string: "Foco native screen — let resolution = \(width) × \(height); fps = 60; 0123456789",
                    attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                 NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.95, alpha: 1)])
                context.textPosition = CGPoint(x: 32, y: height - 180 - line * 64)
                CTLineDraw(CTLineCreateWithAttributedString(text), context)
            }
            // A pixel-exact alternating strip exposes any accidental 1080p
            // downscale: its spatial frequency cannot survive that reduction.
            for y in 32..<80 { for x in 32..<288 {
                let offset = y * row + x * 4
                let value: UInt8 = x.isMultiple(of: 2) ? 0 : 255
                data[offset] = value; data[offset + 1] = value; data[offset + 2] = value
            } }
            // Source content changes every frame, in addition to camera motion.
            for y in 400..<480 { for x in 32..<512 {
                let offset = y * row + x * 4
                data[offset] = variant ? 20 : 180
                data[offset + 1] = variant ? 180 : 30
                data[offset + 2] = 30
            } }
        }
        return result
    }

    static func pixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> (Int, Int, Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return (Int(p[offset + 2]), Int(p[offset + 1]), Int(p[offset]))
    }

    static func fingerprint(_ url: URL) async throws -> (String, Int) {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        try require(reader.startReading(), "Could not read encoded video")
        var hash = SHA256()
        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            var bytes = Data(count: length)
            let status = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            try require(status == noErr, "Encoded sample unreadable")
            hash.update(data: bytes)
            frames += 1
        }
        try require(reader.status == .completed, "Encoded video read failed")
        return (hash.finalize().description, frames)
    }

    static func main() async throws {
        let mode = CGDisplayCopyDisplayMode(CGMainDisplayID())
        let rawWidth = mode?.pixelWidth ?? 2940
        let rawHeight = mode?.pixelHeight ?? 1912
        let geometry = RecordingGeometry.native(width: rawWidth, height: rawHeight)
        try require(geometry.width <= rawWidth && geometry.height <= rawHeight,
                    "Native geometry enlarged desktop pixels")
        try require(rawWidth - geometry.width <= 1 && rawHeight - geometry.height <= 1,
                    "Native geometry unexpectedly resized desktop")
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("native-test-source.mov")
        let result = directory.appendingPathComponent("native-test.mp4")
        for url in [source, result] { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
        let writer = try AVAssetWriter(outputURL: source, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: geometry.videoSettings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: geometry.width,
            kCVPixelBufferHeightKey as String: geometry.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        try require(writer.canAdd(input), "Native H.264 input unsupported")
        writer.add(input)
        try require(writer.startWriting(), "Could not start native H.264 encoder: \(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { throw RecorderError.message("Missing native writer pool") }
        let first = try buffer(width: geometry.width, height: geometry.height)
        let second = try buffer(width: geometry.width, height: geometry.height, variant: true)
        let camera = try buffer(width: 640, height: 480, camera: true)
        let compositor = FrameCompositor(geometry: geometry, corner: .bottomRight)
        let samples = PreviewSampleFactory()
        guard let warmFrame = compositor.frame(screen: first, camera: camera, pool: pool) else {
            throw RecorderError.message("Missing native composite")
        }
        for x in 32..<288 {
            let value = pixel(warmFrame, x: x, y: 48).0
            try require(value == (x.isMultiple(of: 2) ? 0 : 255), "Pixel-detail strip was resampled or blurred at x=\(x)")
        }
        try require(pixel(warmFrame, x: 1000, y: 500) == (38, 38, 38), "sRGB gray changed in composition")
        guard let sample = samples.sample(for: PreviewVideoFrame(buffer: warmFrame)),
              let format = CMSampleBufferGetFormatDescription(sample) else { throw RecorderError.message("Missing preview format") }
        let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        try require(transfer == kCVImageBufferTransferFunction_sRGB as String, "Native preview lost the sRGB transfer tag")
        try require(CMSampleBufferGetImageBuffer(sample) === warmFrame, "Preview copied or downscaled its frame")
        let frameCount = 180
        let interval = 1_000_000_000.0 / 60
        let start = DispatchTime.now().uptimeNanoseconds
        var frameWork: [Double] = []
        var appendWork: [Double] = []
        var lateFrames = 0
        var backpressureFrames = 0
        var backpressureNS: UInt64 = 0
        for frame in 0..<frameCount {
            let deadline = start + UInt64(Double(frame) * interval)
            let beforeWait = DispatchTime.now().uptimeNanoseconds
            if beforeWait < deadline { try await Task.sleep(nanoseconds: deadline - beforeWait) }
            if DispatchTime.now().uptimeNanoseconds > deadline + UInt64(interval) { lateFrames += 1 }
            if !input.isReadyForMoreMediaData {
                backpressureFrames += 1
                let blockedAt = DispatchTime.now().uptimeNanoseconds
                while !input.isReadyForMoreMediaData {
                    try require(writer.status == .writing, "Native writer failed: \(String(describing: writer.error))")
                    try require(DispatchTime.now().uptimeNanoseconds - blockedAt < 2_000_000_000, "Native encoder stalled for two seconds")
                    try await Task.sleep(nanoseconds: 500_000)
                }
                backpressureNS += DispatchTime.now().uptimeNanoseconds - blockedAt
            }
            let workStarted = DispatchTime.now().uptimeNanoseconds
            try autoreleasepool {
                compositor.invalidateFrame()
                compositor.setCameraPlacement(CameraPlacement(x: 0.75 + 0.24 * sin(Double(frame) / 30), y: 0.8))
                guard let composed = compositor.frame(screen: frame.isMultiple(of: 2) ? first : second, camera: camera, pool: pool) else {
                    throw RecorderError.message("Native composite allocation failed")
                }
                let appendStarted = DispatchTime.now().uptimeNanoseconds
                try require(adaptor.append(composed, withPresentationTime: CMTime(value: Int64(frame), timescale: 60)),
                            "Native video frame append failed: \(String(describing: writer.error))")
                appendWork.append(Double(DispatchTime.now().uptimeNanoseconds - appendStarted) / 1_000_000)
                guard let displayed = samples.sample(for: PreviewVideoFrame(buffer: composed)) else {
                    throw RecorderError.message("Native preview preparation failed")
                }
                try require(CMSampleBufferGetImageBuffer(displayed) === composed, "Preview copied recorded pixels")
            }
            frameWork.append(Double(DispatchTime.now().uptimeNanoseconds - workStarted) / 1_000_000)
        }
        let encodeWall = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        writer.endSession(atSourceTime: CMTime(value: Int64(frameCount), timescale: 60))
        input.markAsFinished()
        await writer.finishWriting()
        try require(writer.status == .completed, "Native movie finalization failed: \(String(describing: writer.error))")
        try require(pixel(warmFrame, x: 1000, y: 500) == (38, 38, 38), "A retained native frame was mutated")
        try await MediaFinalizer.finalize(input: source, output: result)
        let before = try await fingerprint(source)
        let after = try await fingerprint(result)
        try require(before.0 == after.0 && after.1 == frameCount, "MP4 export recompressed or lost native video samples")
        let asset = AVURLAsset(url: result)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let size = try await track.load(.naturalSize)
        let fps = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)
        let encodedFormat = try await track.load(.formatDescriptions).first!
        try require(size == geometry.size && fps == 60 && abs(duration.seconds - 3) < 0.001,
                    "Native output geometry/fps/duration changed")
        try require(CMFormatDescriptionGetMediaSubType(encodedFormat) == kCMVideoCodecType_H264, "Unexpected native codec")
        let encodedTransfer = CMFormatDescriptionGetExtension(encodedFormat, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        try require(encodedTransfer == kCVImageBufferTransferFunction_sRGB as String, "Encoded sRGB transfer tag changed: \(encodedTransfer ?? "nil")")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        try require(reader.startReading(), "Could not decode native recording")
        var count = 0
        var minStripeContrast = 255
        var maxGrayError = 0
        while let decoded = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(decoded).seconds
            try require(abs(time - Double(count) / 60) < 0.00001, "Native recording has a missing frame timestamp")
            let image = CMSampleBufferGetImageBuffer(decoded)!
            try require(CVPixelBufferGetWidth(image) == geometry.width && CVPixelBufferGetHeight(image) == geometry.height,
                        "Decoder did not preserve native dimensions")
            if count.isMultiple(of: 29) {
                let black = pixel(image, x: 128, y: 48).0
                let white = pixel(image, x: 129, y: 48).0
                minStripeContrast = min(minStripeContrast, white - black)
                let gray = pixel(image, x: 1000, y: 500).0
                maxGrayError = max(maxGrayError, abs(gray - 38))
                let changed = pixel(image, x: 100, y: 430)
                try require(count.isMultiple(of: 2) ? changed.2 > 130 && changed.1 < 80 : changed.1 > 130 && changed.2 < 80,
                            "Native recording lost dynamic source content")
            }
            count += 1
        }
        try require(reader.status == .completed && count == frameCount, "Native decoder lost frames")
        try require(minStripeContrast > 180, "Fine single-pixel detail lost excessive contrast: \(minStripeContrast)")
        try require(maxGrayError <= 5, "Encoded sRGB gray shifted more than quantization: \(maxGrayError)")
        func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }
        func percentile95(_ values: [Double]) -> Double { values.sorted()[Int(Double(values.count - 1) * 0.95)] }
        print("PASS: current display backing pixels \(rawWidth) × \(rawHeight), native output \(geometry.width) × \(geometry.height), 180 decoded frames / 3 seconds / 60 fps.")
        print("PASS: exact 1-pixel stripe preserved before encoding; decoded contrast \(minStripeContrast)/255; sRGB gray error ≤\(maxGrayError); matching color tags and zero-copy preview.")
        print("PASS: native MP4 export retains every H.264 sample byte unchanged (SHA-256 \(after.0)).")
        print(String(format: "Paced native composition + encode append + preview preparation: mean %.2f ms, p95 %.2f ms; append mean %.2f ms, p95 %.2f ms; frame budget 16.67 ms.",
                     mean(frameWork), percentile95(frameWork), mean(appendWork), percentile95(appendWork)))
        print(String(format: "180-frame wall time %.3f s; starts >1 frame late: %d; encoder backpressure: %d frames / %.2f ms total.",
                     encodeWall, lateFrames, backpressureFrames, Double(backpressureNS) / 1_000_000))
        print("Synthetic test includes real encoding and MP4 export, but excludes screen/camera device capture, actual display scanout, audio and competing applications.")
        print("Synthetic native video: \(result.path)")
    }
}
