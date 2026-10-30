import Foundation
@preconcurrency import AVFoundation
import CoreImage
import CryptoKit

@main
enum TrimSelfTest {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw RecorderError.message("TRIM TEST: \(message)") }
    }

    static func main() async throws {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist")
        let raw = folder.appendingPathComponent("trim-source.mov")
        let source = folder.appendingPathComponent("trim-source.mp4")
        let result = folder.appendingPathComponent("trim-test.mp4")
        let overwrite = folder.appendingPathComponent("trim-overwrite.mp4")
        let cancel = folder.appendingPathComponent("trim-cancelled.mp4")
        let alias = folder.appendingPathComponent("trim-source-alias.mp4")
        let hardlink = folder.appendingPathComponent("trim-source-hardlink.mp4")
        for file in [raw, source, result, overwrite, cancel, alias, hardlink] { try? FileManager.default.removeItem(at: file) }
        try await makeMovie(raw)
        try await MediaFinalizer.finalize(input: raw, output: source)
        let originalHash = try hash(source)
        let range = CMTimeRange(start: CMTime(value: 30, timescale: 60), duration: CMTime(value: 60, timescale: 60))
        try await VideoTrimmer.export(source: source, destination: result, range: range)
        try await validate(source: source, cut: result)
        try require(try hash(source) == originalHash, "La exportación alteró el original")

        for invalid in [CMTimeRange(start: .zero, duration: .zero),
                        CMTimeRange(start: CMTime(value: -1, timescale: 1), duration: CMTime(value: 1, timescale: 1)),
                        CMTimeRange(start: .zero, duration: CMTime(value: 3, timescale: 1))] {
            try await expectFailure {
                try await VideoTrimmer.export(source: source, destination: cancel, range: invalid)
            }
        }
        try await expectFailure { try await VideoTrimmer.export(source: source, destination: source, range: range, overwrite: true) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        try await expectFailure { try await VideoTrimmer.export(source: source, destination: alias, range: range, overwrite: true) }
        try FileManager.default.linkItem(at: source, to: hardlink)
        try await expectFailure { try await VideoTrimmer.export(source: source, destination: hardlink, range: range, overwrite: true) }

        try Data("archivo existente".utf8).write(to: overwrite)
        try await expectFailure { try await VideoTrimmer.export(source: source, destination: overwrite, range: range) }
        try require(try Data(contentsOf: overwrite) == Data("archivo existente".utf8), "Se reemplazó un archivo sin autorización")
        try await VideoTrimmer.export(source: source, destination: overwrite, range: range, overwrite: true)
        try await validate(source: source, cut: overwrite)

        let task = Task { try await VideoTrimmer.export(source: source, destination: cancel, range: range) }
        task.cancel()
        do { try await task.value; throw RecorderError.message("La tarea cancelada terminó correctamente") }
        catch is CancellationError {}
        try require(!FileManager.default.fileExists(atPath: cancel.path), "La cancelación dejó un archivo")
        let cancelBox = CancelOnExportStart()
        let preparedTask = Task {
            try await VideoTrimmer.export(source: source, destination: cancel, range: range,
                onProgress: { progress in if progress == 0 { cancelBox.cancel() } })
        }
        cancelBox.install(preparedTask)
        do { try await preparedTask.value; throw RecorderError.message("La exportación preparada ignoró la cancelación") }
        catch is CancellationError {}
        try require(!FileManager.default.fileExists(atPath: cancel.path), "La exportación cancelada dejó un archivo incompleto")
        try require(try hash(source) == originalHash, "Una validación o cancelación alteró el original")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".foco-export-") }
        try require(leftovers.isEmpty, "Quedaron temporales de exportación")
        print("PASS: rangos inválidos, original/symlink/hardlink protegidos, reemplazo atómico y cancelación sin restos.")
        print("Recorte sintético: \(result.path)")
    }

    static func hash(_ file: URL) throws -> SHA256.Digest { SHA256.hash(data: try Data(contentsOf: file)) }

    static func expectFailure(_ operation: () async throws -> Void) async throws {
        var failed = false
        do { try await operation() } catch { failed = true }
        try require(failed, "Se aceptó una operación inválida")
    }

    static func makeMovie(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000,
                AVVideoExpectedSourceFrameRateKey: 60, AVVideoMaxKeyFrameIntervalKey: 120,
                AVVideoAllowFrameReorderingKey: false]
        ])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        writer.add(video)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000])
        writer.add(audio)
        try require(writer.startWriting(), "No pudo iniciarse el generador")
        writer.startSession(atSourceTime: .zero)
        let context = CIContext(options: [.cacheIntermediates: false])
        let rect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()
            group.enter()
            var frame = 0
            var videoDone = false
            video.requestMediaDataWhenReady(on: DispatchQueue(label: "test.trim.video")) {
                guard !videoDone else { return }
                while video.isReadyForMoreMediaData {
                    if frame == 120 { videoDone = true; video.markAsFinished(); group.leave(); return }
                    var buffer: CVPixelBuffer?
                    if let pool = adapter.pixelBufferPool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) }
                    guard let buffer else { fatalError("Missing test buffer") }
                    let background = CIImage(color: CIColor(red: Double(frame) / 150, green: 0.2, blue: 0.35)).cropped(to: rect)
                    let marker = CIImage(color: .white).cropped(to: CGRect(x: 20 + frame * 10, y: 400, width: 100, height: 200))
                    context.render(marker.composited(over: background), to: buffer)
                    guard adapter.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 60)) else { fatalError("Test video append failed") }
                    frame += 1
                }
            }
            group.enter()
            var position = 0
            var audioDone = false
            audio.requestMediaDataWhenReady(on: DispatchQueue(label: "test.trim.audio")) {
                guard !audioDone else { return }
                while audio.isReadyForMoreMediaData {
                    if position == 96_000 { audioDone = true; audio.markAsFinished(); group.leave(); return }
                    let count = min(1024, 96_000 - position)
                    guard let sample = try? MediaSelfTest.audioSample(start: position, count: count, frequency: 440), audio.append(sample) else { fatalError("Test audio append failed") }
                    position += count
                }
            }
            group.notify(queue: .global()) {
                writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
                writer.finishWriting {
                    if writer.status == .completed { continuation.resume() }
                    else { continuation.resume(throwing: writer.error ?? RecorderError.message("No se cerró el generador")) }
                }
            }
        }
    }

    static func validate(source: URL, cut: URL) async throws {
        let asset = AVURLAsset(url: cut)
        let duration = try await asset.load(.duration)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        try require(abs(duration.seconds - 1) < 1.0 / 600, "Duración inesperada: \(duration.seconds)")
        try require(videos.count == 1 && audios.count == 1, "Pistas de salida incorrectas")
        let size = try await videos[0].load(.naturalSize)
        let fps = try await videos[0].load(.nominalFrameRate)
        try require(size == CGSize(width: 1920, height: 1080) && abs(fps - 60) < 0.01, "Cambió resolución/fps")
        let sourceSamples = try await MediaSelfTest.compressedVideoSamples(source)
        let resultSamples = try await MediaSelfTest.compressedVideoSamples(cut)
        try require(!resultSamples.isEmpty && resultSamples.allSatisfy { sourceSamples.contains($0) }, "Se recodificó el video")
        let sourceAudio = try await compressedAudio(source)
        let resultAudio = try await compressedAudio(cut)
        try require(!resultAudio.isEmpty && resultAudio.allSatisfy { sourceAudio.contains($0) }, "Se recodificó o perdió el audio")
        let inputImage = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        let outputImage = AVAssetImageGenerator(asset: asset)
        for generator in [inputImage, outputImage] {
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.appliesPreferredTrackTransform = true
        }
        for frame in [0, 30, 59] {
            let input = try await inputImage.image(at: CMTime(value: Int64(frame + 30), timescale: 60)).image
            let output = try await outputImage.image(at: CMTime(value: Int64(frame), timescale: 60)).image
            let a = input.dataProvider!.data! as Data
            let b = output.dataProvider!.data! as Data
            try require(a == b, "El fotograma \(frame) no coincide con el original o no se pudo decodificar")
        }
        print("PASS: corte entre keyframes de 0,5 a 1,5 s; duración 1 s, 1920×1080 a 60 fps, audio y H.264 intactos; primer/medio/último fotograma decodifican idénticos.")
    }

    static func compressedAudio(_ url: URL) async throws -> [Data] {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .audio).first!
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        try require(reader.startReading(), "No se pudo leer el audio comprimido")
        var packets: [Data] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample), CMBlockBufferGetDataLength(block) > 0 else { continue }
            let count = CMBlockBufferGetDataLength(block)
            var data = Data(count: count)
            let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!) }
            try require(status == noErr, "No se pudo copiar el audio")
            // Reader buffers can group AAC packets differently after a trim.
            // Compare each encoded packet, rather than the buffer grouping.
            var offset = 0
            for index in 0..<CMSampleBufferGetNumSamples(sample) {
                let length = CMSampleBufferGetSampleSize(sample, at: index)
                try require(length > 0 && offset + length <= data.count, "Paquete AAC inválido")
                packets.append(data.subdata(in: offset..<(offset + length)))
                offset += length
            }
            try require(offset == data.count, "No se comparó todo el audio")
        }
        try require(reader.status == .completed, "Lectura de audio incompleta")
        return packets
    }
}

private final class CancelOnExportStart: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Error>?
    private var requested = false
    func install(_ task: Task<Void, Error>) {
        lock.lock(); defer { lock.unlock() }
        self.task = task
        if requested { task.cancel() }
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        requested = true
        task?.cancel()
    }
}
