import Foundation
@preconcurrency import AVFoundation
import CoreGraphics
import CryptoKit

/// Synthetic sources only: no screen, microphone or camera device is opened.
@main
enum CameraOnlyTest {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw RecorderError.message("CAMERA-ONLY TEST: \(message)") }
    }

    static func buffer(width: Int, height: Int, camera: Bool) throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &value) == kCVReturnSuccess,
              let value else { throw RecorderError.message("Missing test buffer") }
        CVBufferSetAttachment(value, kCVImageBufferCGColorSpaceKey, CGColorSpace(name: CGColorSpace.sRGB)!, .shouldPropagate)
        CVPixelBufferLockBaseAddress(value, [])
        let data = CVPixelBufferGetBaseAddress(value)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(value)
        for y in 0..<height { for x in 0..<width {
            let i = y * row + x * 4
            let edge = camera && (y < 12 || y >= height - 12)
            data[i] = camera ? (edge ? 220 : 15) : 220
            data[i + 1] = camera && x >= width / 2 ? 210 : 20
            data[i + 2] = camera && x < width / 2 ? 220 : 20
            data[i + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(value, [])
        return value
    }

    static func rgb(_ buffer: CVPixelBuffer, x: Int, y: Int) -> (Int, Int, Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let data = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let i = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return (Int(data[i + 2]), Int(data[i + 1]), Int(data[i]))
    }

    static func verifyFullCamera(_ image: CVPixelBuffer, geometry: RecordingGeometry, compressed: Bool = false) throws {
        // The 4:3 source must fill this wider canvas. Its colored top/bottom
        // strips are outside the center crop, so neither bars nor edge strips remain.
        for y in [8, geometry.height / 2, geometry.height - 9] {
            let left = rgb(image, x: 8, y: y)
            let right = rgb(image, x: geometry.width - 9, y: y)
            try require(left.1 > 170 && left.0 < 60 && left.2 < 60,
                        "Full camera has bars, borders, unmirrored pixels or desktop on its left edge")
            try require(right.0 > 180 && right.1 < 60 && right.2 < 60,
                        "Full camera has bars, borders, unmirrored pixels or desktop on its right edge")
        }
        if !compressed {
            try require(rgb(image, x: 8, y: 8) == (20, 210, 15), "Full camera altered its sRGB pixels")
        }
    }

    static func fingerprint(_ url: URL) async throws -> String {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        try require(reader.startReading(), "Cannot inspect encoded video")
        var hash = SHA256()
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var data = Data(count: CMBlockBufferGetDataLength(block))
            let status = data.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            try require(status == noErr, "Cannot read video packet")
            hash.update(data: data)
        }
        try require(reader.status == .completed, "Encoded video inspection failed")
        return hash.finalize().description
    }

    static func main() async throws {
        // Fixed native-sized canvas keeps the test representative and ensures a
        // 4:3 camera needs center cropping, independently of attached displays.
        let geometry = RecordingGeometry.native(width: 2940, height: 1912)
        let screen = try buffer(width: geometry.width, height: geometry.height, camera: false)
        let camera = try buffer(width: 640, height: 480, camera: true)
        var pool: CVPixelBufferPool?
        try require(CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferWidthKey as String: geometry.width,
            kCVPixelBufferHeightKey as String: geometry.height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ] as CFDictionary, &pool) == kCVReturnSuccess, "Cannot create native pool")
        let compositor = FrameCompositor(geometry: geometry, corner: .bottomRight)
        let desktop = compositor.frame(screen: screen, camera: camera, pool: pool!)!
        try require(rgb(desktop, x: 8, y: 8).2 > 200, "Initial screen composition is wrong")
        compositor.setScreenEnabled(false)
        let full = compositor.frame(screen: screen, camera: camera, pool: pool!)!
        try require(full !== desktop, "Mode change mutated a retained movie frame")
        try verifyFullCamera(full, geometry: geometry)
        compositor.setScreenEnabled(false)
        try require(compositor.frame(screen: nil, camera: camera, pool: pool!) === full,
                    "Unchanged mode recomposed its immutable frame")
        compositor.invalidateFrame()
        let withoutScreen = compositor.frame(screen: nil, camera: camera, pool: pool!)!
        try verifyFullCamera(withoutScreen, geometry: geometry)
        compositor.setCameraPlacement(.from(corner: .topLeft))
        compositor.setScreenEnabled(true)
        let restored = compositor.frame(screen: screen, camera: camera, pool: pool!)!
        let inset = CameraPlacement.from(corner: .topLeft).rect(in: geometry)
        try require(rgb(restored, x: Int(inset.minX + inset.width * 0.25), y: Int(inset.midY)).1 > 170,
                    "Returning to screen mode lost camera placement or mirroring")
        try require(rgb(restored, x: geometry.width / 2, y: geometry.height / 2).2 > 200,
                    "Returning to screen mode did not restore the desktop")
        try verifyFullCamera(full, geometry: geometry)
        try require(rgb(desktop, x: 8, y: 8).2 > 200, "Previously recorded desktop changed")
        compositor.setScreenEnabled(false)
        let black = compositor.frame(screen: screen, camera: nil, pool: pool!)!
        try require(rgb(black, x: geometry.width / 2, y: geometry.height / 2) == (0, 0, 0),
                    "Missing camera exposed disabled desktop content")

        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist")
        let source = directory.appendingPathComponent("camera-only-test-source.mov")
        let result = directory.appendingPathComponent("camera-only-test.mp4")
        let trimmed = directory.appendingPathComponent("camera-only-trim-test.mp4")
        for file in [source, result, trimmed] {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        let writer = try AVAssetWriter(outputURL: source, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: geometry.videoSettings)
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        try require(writer.startWriting(), "Cannot encode native camera movie")
        writer.startSession(atSourceTime: .zero)
        let samples = PreviewSampleFactory()
        for index in 0..<120 {
            while !input.isReadyForMoreMediaData {
                try require(writer.status == .writing, "Camera movie encoder failed")
                try await Task.sleep(nanoseconds: 500_000)
            }
            // Screen -> full camera -> screen in one uninterrupted 60 fps file.
            compositor.setScreenEnabled(index < 40 || index >= 80)
            let frame = compositor.frame(screen: screen, camera: camera, pool: pool!)!
            try require(adapter.append(frame, withPresentationTime: CMTime(value: Int64(index), timescale: 60)),
                        "Camera mode transition failed to encode")
            let sample = samples.sample(for: PreviewVideoFrame(buffer: frame))!
            try require(CMSampleBufferGetImageBuffer(sample) === frame, "Preview copied or resized its mode-switch frame")
        }
        writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
        input.markAsFinished()
        await writer.finishWriting()
        try require(writer.status == .completed, "Camera movie did not finish")
        try await MediaFinalizer.finalize(input: source, output: result)
        let originalHash = try await fingerprint(source)
        let resultHash = try await fingerprint(result)
        try require(originalHash == resultHash, "Finalization recompressed camera-mode video")
        let asset = AVURLAsset(url: result)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let size = try await track.load(.naturalSize)
        let fps = try await track.load(.nominalFrameRate)
        let format = try await track.load(.formatDescriptions).first!
        try require(size == geometry.size && fps == 60, "Mode switching changed native resolution or 60 fps")
        try require(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String == kCVImageBufferTransferFunction_sRGB as String,
                    "Camera movie lost its sRGB color metadata")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        try require(reader.startReading(), "Cannot decode mode-switch recording")
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            try require(abs(CMSampleBufferGetPresentationTimeStamp(sample).seconds - Double(count) / 60) < 0.00001,
                        "Mode switching broke the 60 fps timeline")
            let frame = CMSampleBufferGetImageBuffer(sample)!
            if (40..<80).contains(count) { try verifyFullCamera(frame, geometry: geometry, compressed: true) }
            else { try require(rgb(frame, x: geometry.width / 2, y: geometry.height / 2).2 > 170, "Desktop missing from screen segment") }
            count += 1
        }
        try require(reader.status == .completed && count == 120, "Mode-switch movie lost frames")
        try await VideoTrimmer.export(source: result, destination: trimmed,
            range: CMTimeRange(start: CMTime(value: 40, timescale: 60), duration: CMTime(value: 40, timescale: 60)))
        let trimAsset = AVURLAsset(url: trimmed)
        let trimTrack = try await trimAsset.loadTracks(withMediaType: .video).first!
        let trimSize = try await trimTrack.load(.naturalSize)
        let trimFPS = try await trimTrack.load(.nominalFrameRate)
        let trimDuration = try await trimAsset.load(.duration)
        try require(trimSize == geometry.size && abs(trimFPS - 60) < 0.001 && abs(trimDuration.seconds - 40.0 / 60) < 0.001,
                    "Trimming the full-camera section changed quality or duration: \(trimSize), fps \(trimFPS), duration \(trimDuration.seconds)")
        let afterTrimHash = try await fingerprint(result)
        try require(afterTrimHash == resultHash, "Trimming modified the original")
        print("PASS: full camera fills 2940×1912 with mirrored center crop, no borders or desktop pixels; nil screen works, missing camera stays black.")
        print("PASS: mode switches preserve old surfaces and camera placement; one native 60 fps movie has 120 consecutive frames across screen/camera/screen.")
        print("PASS: sRGB and zero-copy preview retained; finalization preserves H.264 bytes; camera-only trim keeps native resolution, 60 fps and original file.")
    }
}
