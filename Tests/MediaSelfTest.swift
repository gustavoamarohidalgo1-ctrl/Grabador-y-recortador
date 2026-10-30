import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

#if !PAUSE_TEST
@main
#endif
enum MediaSelfTest {
    static func main() async throws {
        try geometryTests()
        try compositorTests()
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("self-test-source.mov")
        let destination = directory.appendingPathComponent("self-test.mp4")
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: destination)
        try await makeSyntheticMovie(at: source)
        try await MediaFinalizer.finalize(input: source, output: destination)
        try await validateMovie(source: source, result: destination)
        try await finalizerEdgeTests(source: source, directory: directory)
        print("PASS: geometría, cuatro esquinas, espejo, bordes, video H.264 intacto, audio AAC mezclado y fallos seguros.")
        print("Video sintético: \(destination.path)")
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw RecorderError.message("TEST: \(message)") }
    }

    static func geometryTests() throws {
        for (width, height, expected) in [
            (3840, 2160, RecordingGeometry(width: 3840, height: 2160)),
            (2560, 1600, RecordingGeometry(width: 2560, height: 1600)),
            (3440, 1440, RecordingGeometry(width: 3440, height: 1440)),
            (1080, 1920, RecordingGeometry(width: 1080, height: 1920)),
            (2940, 1912, RecordingGeometry(width: 2940, height: 1912)),
            (6016, 3384, RecordingGeometry(width: 6016, height: 3384)),
            (1921, 1081, RecordingGeometry(width: 1920, height: 1080)),
            (1280, 720, RecordingGeometry(width: 1280, height: 720))
        ] {
            try require(RecordingGeometry.native(width: width, height: height) == expected,
                        "Geometría incorrecta para \(width) × \(height)")
        }
        print("PASS: 16:9, 16:10, ultrapanorámico, vertical y pantalla pequeña.")
    }

    static func pixelBuffer(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result)
        guard status == kCVReturnSuccess, let buffer = result else { throw RecorderError.message("No se pudo crear el buffer sintético.") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * row + x * 4
                bytes[index] = blue; bytes[index + 1] = green; bytes[index + 2] = red; bytes[index + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    static func rgb(_ buffer: CVPixelBuffer, x: Int, y: Int) -> (Int, Int, Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let pointer = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let index = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return (Int(pointer[index + 2]), Int(pointer[index + 1]), Int(pointer[index]))
    }

    static func compositorTests() throws {
        let geometry = RecordingGeometry(width: 1920, height: 1080)
        let screen = try pixelBuffer(width: 960, height: 540, red: 20, green: 35, blue: 120)
        let camera = try pixelBuffer(width: 320, height: 240, red: 220, green: 30, blue: 20)
        let destination = try pixelBuffer(width: 1920, height: 1080, red: 0, green: 0, blue: 0)
        // Right half green, left half red: verify that the recorded camera is mirrored.
        CVPixelBufferLockBaseAddress(camera, [])
        let data = CVPixelBufferGetBaseAddress(camera)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<240 { for x in 160..<320 {
            let i = y * CVPixelBufferGetBytesPerRow(camera) + x * 4
            data[i] = 20; data[i + 1] = 220; data[i + 2] = 30
        } }
        CVPixelBufferUnlockBaseAddress(camera, [])
        for corner in CameraCorner.allCases {
            let compositor = FrameCompositor(geometry: geometry, corner: corner)
            compositor.render(screen: screen, camera: camera, into: destination)
            let isRight = corner == .bottomRight || corner == .topRight
            let isTop = corner == .topRight || corner == .topLeft
            // CVPixelBuffer rows start at the top, whereas CI cameraRect uses a bottom-left origin.
            let x = isRight ? 1920 - 24 - 420 : 24
            let y = isTop ? 24 : 1080 - 24 - 315
            let mirroredLeft = rgb(destination, x: x + 100, y: y + 150)
            let mirroredRight = rgb(destination, x: x + 320, y: y + 150)
            try require(mirroredLeft.1 > 150 && mirroredLeft.0 < 100, "Espejo/esquina incorrectos: \(corner)")
            try require(mirroredRight.0 > 150 && mirroredRight.1 < 100, "Mitad derecha de cámara incorrecta")
            let center = rgb(destination, x: 960, y: 540)
            try require(center.2 > 100 && center.0 < 50, "La composición modificó la pantalla")
            try require(compositor.preview(from: destination) != nil, "Vista previa vacía")
        }
        let square = FrameCompositor(geometry: RecordingGeometry(width: 300, height: 300), corner: .bottomRight)
        let box = try pixelBuffer(width: 300, height: 300, red: 0, green: 0, blue: 0)
        square.render(screen: screen, camera: nil, into: box)
        try require(rgb(box, x: 150, y: 10) == (0, 0, 0), "La pantalla se deformó en lugar de encajar")
        try require(rgb(box, x: 150, y: 150).2 > 100, "Pantalla central ausente")
        let image = FrameCompositor(geometry: geometry, corner: .bottomRight)
        image.render(screen: screen, camera: camera, into: destination)
        if let preview = image.preview(from: destination) {
            let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/self-test-composite.png")
            if let file = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(file, preview, nil)
                CGImageDestinationFinalize(file)
            }
        }
        print("PASS: composición sin deformación, cámara en cuatro esquinas y espejo horizontal.")
    }

    static func audioSample(start: Int, count: Int, frequency: Double, presentationTime: CMTime? = nil) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        guard formatStatus == noErr, let format else { throw RecorderError.message("Formato sintético inválido") }
        let values: [Float] = (0..<count * 2).map { index in
            Float(0.22 * sin(2 * .pi * frequency * Double(start + index / 2) / 48_000))
        }
        var block: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: values.count * 4, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: values.count * 4, flags: 0, blockBufferOut: &block)
        guard blockStatus == noErr, let block else { throw RecorderError.message("Buffer de audio inválido") }
        let copyStatus = values.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count) }
        guard copyStatus == noErr else { throw RecorderError.message("No se pudo copiar el tono") }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                       presentationTimeStamp: presentationTime ?? CMTime(value: Int64(start), timescale: 48_000), decodeTimeStamp: .invalid)
        var sampleSize = 8
        let status = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format, sampleCount: count,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw RecorderError.message("Muestra de audio inválida: \(status)") }
        return sample
    }

    static func makeSyntheticMovie(at url: URL, audioTrackCount: Int = 2, simulatePause: Bool = false) async throws {
        // Simulate seven seconds of incoming samples: one active second,
        // five paused seconds, and one active second. The file must still be 2 s.
        var configuredTimeline = RecordingTimeline(origin: .zero)
        if simulatePause {
            configuredTimeline.pause(at: CMTime(value: 1, timescale: 1))
            configuredTimeline.resume(at: CMTime(value: 6, timescale: 1))
        }
        let timeline = configuredTimeline
        let sourceSeconds = simulatePause ? 7 : 2
        let geometry = RecordingGeometry(width: 1920, height: 1080)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: geometry.bitRate,
                AVVideoExpectedSourceFrameRateKey: RecordingQuality.framesPerSecond,
                AVVideoAllowFrameReorderingKey: false
            ]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        writer.add(video)
        let audios = (0..<audioTrackCount).map { _ -> AVAssetWriterInput in
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000
            ])
            writer.add(input)
            return input
        }
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        let screen = try pixelBuffer(width: 960, height: 540, red: 20, green: 35, blue: 120)
        let camera = try pixelBuffer(width: 320, height: 240, red: 220, green: 80, blue: 30)
        let compositor = FrameCompositor(geometry: geometry, corner: .bottomRight)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()
            group.enter()
            var frame = 0
            var videoFinished = false
            video.requestMediaDataWhenReady(on: DispatchQueue(label: "test.video")) {
                guard !videoFinished else { return }
                while video.isReadyForMoreMediaData {
                    if frame == Int(RecordingQuality.framesPerSecond) * sourceSeconds {
                        videoFinished = true; video.markAsFinished(); group.leave(); return
                    }
                    let hostTime = CMTime(value: Int64(frame), timescale: RecordingQuality.framesPerSecond)
                    frame += 1
                    guard let presentationTime = timeline.presentationTime(for: hostTime) else { continue }
                    var buffer: CVPixelBuffer?
                    if let pool = adaptor.pixelBufferPool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) }
                    guard let buffer else { fatalError("No pixel pool") }
                    compositor.render(screen: screen, camera: camera, into: buffer)
                    guard adaptor.append(buffer, withPresentationTime: presentationTime) else {
                        fatalError("Synthetic append failed: \(String(describing: writer.error))")
                    }
                }
            }
            for (index, input) in audios.enumerated() {
                group.enter()
                var position = 0
                var finished = false
                input.requestMediaDataWhenReady(on: DispatchQueue(label: "test.audio.\(index)")) {
                    guard !finished else { return }
                    while input.isReadyForMoreMediaData {
                        if position >= sourceSeconds * 48_000 {
                            finished = true; input.markAsFinished(); group.leave(); return
                        }
                        var count = min(1024, sourceSeconds * 48_000 - position)
                        if simulatePause {
                            // Split buffers at both boundaries, never writing paused samples.
                            for boundary in [48_000, 288_000] where position < boundary {
                                count = min(count, boundary - position)
                            }
                        }
                        do {
                            if let presentationTime = timeline.presentationTime(for: CMTime(value: Int64(position), timescale: 48_000)) {
                                let sample = try audioSample(start: position, count: count, frequency: index == 0 ? 440 : 880,
                                                             presentationTime: presentationTime)
                                guard input.append(sample) else { fatalError("Audio append: \(String(describing: writer.error))") }
                            }
                        } catch { fatalError(error.localizedDescription) }
                        position += count
                    }
                }
            }
            group.notify(queue: .global()) {
                writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
                writer.finishWriting {
                    if writer.status == .completed { continuation.resume() }
                    else { continuation.resume(throwing: writer.error ?? RecorderError.message("Error sintético")) }
                }
            }
        }
    }

    static func compressedVideoSamples(_ url: URL) async throws -> [Data] {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        try require(reader.startReading(), "No se pudo leer el video comprimido")
        var samples = [Data]()
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let size = CMBlockBufferGetDataLength(block)
            var data = Data(count: size)
            let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!) }
            try require(status == noErr, "Muestra de video inválida")
            samples.append(data)
        }
        try require(reader.status == .completed, "Lectura de video incompleta: \(reader.status.rawValue), \(String(describing: reader.error)), \(url.lastPathComponent)")
        return samples
    }

    static func validateMovie(source: URL, result: URL) async throws {
        let asset = AVURLAsset(url: result)
        let duration = try await asset.load(.duration)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        try require(abs(duration.seconds - 2) < 0.05, "Duración final incorrecta: \(duration.seconds)")
        try require(videos.count == 1 && audios.count == 1, "La salida debe tener un video y una pista de audio")
        let dimensions = try await videos[0].load(.naturalSize)
        try require(dimensions == CGSize(width: 1920, height: 1080), "La resolución final cambió")
        let nominalFrameRate = try await videos[0].load(.nominalFrameRate)
        try require(abs(nominalFrameRate - 60) < 0.001, "Frecuencia final incorrecta: \(nominalFrameRate) fps")
        let videoFormat = try await videos[0].load(.formatDescriptions).first!
        let audioFormat = try await audios[0].load(.formatDescriptions).first!
        try require(CMFormatDescriptionGetMediaSubType(videoFormat) == kCMVideoCodecType_H264, "Codec de video incorrecto")
        try require(CMFormatDescriptionGetMediaSubType(audioFormat) == kAudioFormatMPEG4AAC, "Codec de audio incorrecto")
        let sourceSamples = try await compressedVideoSamples(source)
        let resultSamples = try await compressedVideoSamples(result)
        try require(sourceSamples == resultSamples && resultSamples.count == 120, "El video fue recodificado o perdió frames")
        try await validateFrameTiming(result)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: audios[0], outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        try require(reader.startReading(), "No se pudo analizar el audio")
        var mono = [Float]()
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var floats = [Float](repeating: 0, count: length / 4)
            let status = floats.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            try require(status == noErr, "No se pudo decodificar el audio final")
            mono.append(contentsOf: stride(from: 0, to: floats.count, by: 2).map { floats[$0] })
        }
        try require(reader.status == .completed && mono.count > 90_000, "Audio final incompleto")
        for frequency in [440.0, 880.0] {
            var sine = 0.0, cosine = 0.0
            for (index, value) in mono.enumerated() {
                let phase = 2 * Double.pi * frequency * Double(index) / 48_000
                sine += Double(value) * sin(phase)
                cosine += Double(value) * cos(phase)
            }
            let amplitude = 2 * hypot(sine, cosine) / Double(mono.count)
            try require(amplitude > 0.07, "Falta la fuente de audio de \(frequency) Hz; amplitud \(amplitude)")
            print("PASS: fuente \(Int(frequency)) Hz presente, amplitud \(String(format: "%.3f", amplitude)).")
        }
        print("PASS: MP4 1920 × 1080 a 60 fps, H.264 sin recodificar, 2 segundos, 120 frames y una pista AAC.")
    }

    static func validateFrameTiming(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        try require(reader.startReading(), "No se pudo comprobar el tiempo de los fotogramas")
        var previous: CMTime?
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            // Asset readers can emit empty edit-boundary markers. Count encoded
            // frames, as compressedVideoSamples does, rather than those markers.
            guard CMSampleBufferGetNumSamples(sample) > 0,
                  CMSampleBufferGetDataBuffer(sample) != nil else { continue }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
            try require(timestamp.isNumeric, "Un fotograma tiene un tiempo inválido")
            try require(CMTimeCompare(timestamp, CMTime(value: Int64(count), timescale: 60)) == 0,
                        "Fotograma \(count) fuera de su intervalo de 1/60: \(timestamp.seconds)")
            if let previous {
                try require(CMTimeCompare(CMTimeSubtract(timestamp, previous), CMTime(value: 1, timescale: 60)) == 0,
                            "La separación entre fotogramas no es 1/60")
            }
            previous = timestamp
            count += 1
        }
        try require(reader.status == .completed && count == 120,
                    "La secuencia final debe contener 120 fotogramas en dos segundos")
        print("PASS: frecuencia nominal 60 fps y 120 timestamps consecutivos separados exactamente 1/60 s.")
    }

    static func finalizerEdgeTests(source: URL, directory: URL) async throws {
        let existing = directory.appendingPathComponent("self-test-existing.txt")
        let sentinel = Data("preserve existing file".utf8)
        try sentinel.write(to: existing)
        var refusedOverwrite = false
        do {
            try await MediaFinalizer.finalize(input: source, output: existing)
        } catch {
            refusedOverwrite = true
        }
        let preserved = try Data(contentsOf: existing)
        try require(refusedOverwrite && preserved == sentinel, "Se modificó un destino existente")
        try FileManager.default.removeItem(at: existing)
        for count in [0, 1] {
            let temporary = directory.appendingPathComponent("self-test-\(count)-source.mov")
            let target = directory.appendingPathComponent("self-test-\(count)-audio.mp4")
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(at: target)
            try await makeSyntheticMovie(at: temporary, audioTrackCount: count)
            try await MediaFinalizer.finalize(input: temporary, output: target)
            let tracks = try await AVURLAsset(url: target).loadTracks(withMediaType: .audio)
            try require(tracks.count == count, "Número de pistas incorrecto para \(count) fuentes")
            try FileManager.default.removeItem(at: temporary)
        }
        print("PASS: video sin audio, una fuente de audio y protección de archivos existentes.")
    }
}
