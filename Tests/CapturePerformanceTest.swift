import Foundation
@preconcurrency import AVFoundation
import CoreImage

@main
enum CapturePerformanceTest {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw RecorderError.message("TEST: \(message)") }
    }

    static func pixelBuffer(red: UInt8, green: UInt8, blue: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw RecorderError.message("Synthetic buffer unavailable") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let data = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<1080 { for x in 0..<1920 {
            let offset = y * row + x * 4
            data[offset] = blue; data[offset + 1] = green; data[offset + 2] = red; data[offset + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    static func center(_ buffer: CVPixelBuffer) -> (Int, Int, Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let offset = CVPixelBufferGetBytesPerRow(buffer) * 540 + 960 * 4
        return (Int(bytes[offset + 2]), Int(bytes[offset + 1]), Int(bytes[offset]))
    }

    static func main() async throws {
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/capture-cache-test.mp4")
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000,
                AVVideoExpectedSourceFrameRateKey: 60, AVVideoAllowFrameReorderingKey: false]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        writer.add(input)
        try require(writer.startWriting(), "Writer failed to start")
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { throw RecorderError.message("Missing pool") }
        let blue = try pixelBuffer(red: 20, green: 35, blue: 120)
        let green = try pixelBuffer(red: 20, green: 180, blue: 30)
        let camera = try pixelBuffer(red: 220, green: 30, blue: 20)
        let compositor = FrameCompositor(geometry: RecordingGeometry(width: 1920, height: 1080), corner: .bottomRight)
        var surfaces = Set<UInt>()
        var firstFrame: CVPixelBuffer?
        var firstPreviewSample: CMSampleBuffer?
        var lastPreviewSample: CMSampleBuffer?
        let samples = PreviewSampleFactory()
        for frame in 0..<120 {
            while !input.isReadyForMoreMediaData {
                try require(writer.status == .writing, "Writer failed during test")
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            if frame == 60 { compositor.invalidateFrame() }
            let buffer = autoreleasepool {
                compositor.frame(screen: frame < 60 ? blue : green, camera: frame < 60 ? nil : camera, pool: pool)
            }
            guard let buffer else { throw RecorderError.message("Failed to produce frame") }
            if frame == 0 { firstFrame = buffer }
            surfaces.insert(UInt(bitPattern: Unmanaged.passUnretained(buffer).toOpaque()))
            try require(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 60)), "Append failed")
            // Match production ordering: write first, then hand the very same
            // immutable surface to native presentation without reading it back.
            guard let sample = samples.sample(for: PreviewVideoFrame(buffer: buffer)) else {
                throw RecorderError.message("Missing native preview sample")
            }
            try require(CMSampleBufferGetImageBuffer(sample) === buffer, "Preview copied the video surface")
            let dimensions = CMVideoFormatDescriptionGetDimensions(CMSampleBufferGetFormatDescription(sample)!)
            try require(dimensions.width == 1920 && dimensions.height == 1080, "Preview changed resolution")
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
            try require(attachments?.first?[kCMSampleAttachmentKey_DisplayImmediately as String] as? Bool == true,
                        "Native preview would wait for an unrelated display clock")
            if frame == 0 { firstPreviewSample = sample }
            lastPreviewSample = sample
        }
        writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
        input.markAsFinished()
        await writer.finishWriting()
        try require(writer.status == .completed, "Movie failed")
        try require(surfaces.count == 2, "Unchanged sources were recomposed")
        try require(center(firstFrame!).2 > 100 && center(firstFrame!).1 < 60, "Retained frame was mutated")
        try require(CMSampleBufferGetImageBuffer(firstPreviewSample!) === firstFrame!, "First preview lost its original surface")
        try require(center(CMSampleBufferGetImageBuffer(lastPreviewSample!)!).1 > 140, "Preview kept a stale source")

        let asset = AVURLAsset(url: output)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let reader = try AVAssetReader(asset: asset)
        let decode = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(decode)
        try require(reader.startReading(), "Reader failed")
        var count = 0
        while let sample = decode.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            try require(abs(time.seconds - Double(count) / 60) < 0.00001, "Timestamp gap")
            let buffer = CMSampleBufferGetImageBuffer(sample)!
            let color = center(buffer)
            try require(count < 60 ? color.2 > 100 && color.1 < 60 : color.1 > 140 && color.2 < 60, "Wrong cached content")
            count += 1
        }
        let fps = try await track.load(.nominalFrameRate)
        try require(reader.status == .completed && count == 120 && fps == 60, "Lost frames or fps")

        // Isolate the handoff cost using already composed immutable surfaces.
        // This comparison intentionally excludes encoder, display and disk time.
        compositor.invalidateFrame()
        let changed = compositor.frame(screen: green, camera: camera, pool: pool)!
        _ = compositor.preview(from: firstFrame!) // Warm the legacy Core Image path.
        _ = samples.sample(for: PreviewVideoFrame(buffer: firstFrame!))
        let runs = 240
        var nativeTimes: [Double] = []
        var legacyTimes: [Double] = []
        for frame in 0..<runs {
            let buffer = frame.isMultiple(of: 2) ? firstFrame! : changed
            let nativeStart = DispatchTime.now().uptimeNanoseconds
            try autoreleasepool {
                guard let sample = samples.sample(for: PreviewVideoFrame(buffer: buffer)) else {
                    throw RecorderError.message("Missing native handoff")
                }
                try require(CMSampleBufferGetImageBuffer(sample) === buffer, "Native handoff copied pixels")
            }
            nativeTimes.append(Double(DispatchTime.now().uptimeNanoseconds - nativeStart) / 1_000_000)
            let legacyStart = DispatchTime.now().uptimeNanoseconds
            try autoreleasepool {
                guard let image = compositor.preview(from: buffer) else {
                    throw RecorderError.message("Missing legacy readback")
                }
                try require(image.width == 1920 && image.height == 1080, "Legacy benchmark changed dimensions")
            }
            legacyTimes.append(Double(DispatchTime.now().uptimeNanoseconds - legacyStart) / 1_000_000)
        }
        var dynamicTimes: [Double] = []
        for frame in 0..<runs {
            let started = DispatchTime.now().uptimeNanoseconds
            try autoreleasepool {
                compositor.invalidateFrame()
                guard let buffer = compositor.frame(screen: frame.isMultiple(of: 2) ? blue : green, camera: camera, pool: pool),
                      let sample = samples.sample(for: PreviewVideoFrame(buffer: buffer)) else {
                    throw RecorderError.message("Missing dynamic preview frame")
                }
                try require(CMSampleBufferGetImageBuffer(sample) === buffer, "Dynamic preview copied the composite")
            }
            dynamicTimes.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }
        func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }
        func p95(_ values: [Double]) -> Double { values.sorted()[Int(Double(values.count - 1) * 0.95)] }
        print("PASS: 120 frames at 1080p60 from two immutable composite buffers; source transition, timestamps and decoded pixels preserved while preparing native previews.")
        print("PASS: every native sample retains the exact recorded surface without a pixel copy; dimensions, immediate presentation and old-frame contents remain intact.")
        print(String(format: "1080p preview handoff (%d samples): native mean %.3f ms / p95 %.3f ms; legacy CGImage readback mean %.3f ms / p95 %.3f ms.",
                     runs, mean(nativeTimes), p95(nativeTimes), mean(legacyTimes), p95(legacyTimes)))
        print(String(format: "Dynamic 1080p composition + native sample preparation: mean %.2f ms, p95 %.2f ms (60 fps frame budget: 16.67 ms).", mean(dynamicTimes), p95(dynamicTimes)))
        print("Synthetic preparation benchmark only: it does not measure real display cadence, encoder contention or total CPU/GPU use during capture.")
    }
}
