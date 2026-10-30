import AVFoundation
import Foundation

/// Optional benchmark over an existing synthetic movie. It never captures devices.
/// Usage: finalizer-performance-test source.mov output-directory [--baseline]
@main
enum FinalizerPerformanceTest {
    static func main() async throws {
        guard CommandLine.arguments.count >= 3 else {
            throw RecorderError.message("Indica un video sintético de al menos 10 s y una carpeta de pruebas.")
        }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceAsset = AVURLAsset(url: source)
        let sourceDuration = try await sourceAsset.load(.duration)
        try require(sourceDuration.seconds >= 10, "El benchmark necesita al menos 10 segundos")
        let sourceAudios = try await sourceAsset.loadTracks(withMediaType: .audio)
        try require(sourceAudios.count == 1, "El benchmark necesita exactamente una pista AAC")
        let sourceFormat = try await sourceAudios[0].load(.formatDescriptions).first!
        try require(CMFormatDescriptionGetMediaSubType(sourceFormat) == kAudioFormatMPEG4AAC, "Se necesita AAC")
        let sourceAudio = try await packets(source, media: .audio)
        let sourceVideo = try await packets(source, media: .video)
        let sourceBytes = try Data(contentsOf: source)
        var durations: [Double] = []
        for index in 0..<5 {
            let output = directory.appendingPathComponent("finalizer-run-\(index).mp4")
            try? FileManager.default.removeItem(at: output)
            let start = ProcessInfo.processInfo.systemUptime
            try await MediaFinalizer.finalize(input: source, output: output)
            durations.append(ProcessInfo.processInfo.systemUptime - start)
            let resultAsset = AVURLAsset(url: output)
            let resultDuration = try await resultAsset.load(.duration)
            try require(abs(resultDuration.seconds - sourceDuration.seconds) < 0.02, "Duración modificada")
            let video = try await resultAsset.loadTracks(withMediaType: .video).first!
            let fps = try await video.load(.nominalFrameRate)
            let size = try await video.load(.naturalSize)
            try require(abs(fps - 60) < 0.001 && size == CGSize(width: 1920, height: 1080), "Calidad incorrecta")
            let videoPackets = try await packets(output, media: .video)
            try require(videoPackets == sourceVideo, "Video comprimido modificado")
            if !CommandLine.arguments.contains("--baseline") {
                let audioPackets = try await packets(output, media: .audio)
                try require(audioPackets == sourceAudio, "La pista AAC se recodificó")
                let audio = try await resultAsset.loadTracks(withMediaType: .audio).first!
                let format = try await audio.load(.formatDescriptions).first!
                let before = CMAudioFormatDescriptionGetStreamBasicDescription(sourceFormat)!.pointee
                let after = CMAudioFormatDescriptionGetStreamBasicDescription(format)!.pointee
                try require(before.mChannelsPerFrame == after.mChannelsPerFrame && before.mSampleRate == after.mSampleRate,
                            "Se modificaron los canales o la frecuencia de audio")
            }
            print(String(format: "run=%d finalize_seconds=%.5f", index, durations.last!))
        }
        let preserved = try Data(contentsOf: source)
        try require(sourceBytes == preserved, "El archivo original fue modificado")
        let residue = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".foco-finalize-") }
        try require(residue.isEmpty, "Quedan temporales tras finalizar")
        print(String(format: "median_seconds=%.5f source_seconds=%.3f", durations.sorted()[2], sourceDuration.seconds))
        print("PASS: cinco guardados, H.264 idéntico, duración/1080p60 y original conservados" + (CommandLine.arguments.contains("--baseline") ? "" : ", AAC idéntico y canales conservados"))
    }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw RecorderError.message("TEST: \(message)") }
    }

    static func packets(_ url: URL, media: AVMediaType) async throws -> [Data] {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: media).first!
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        try require(reader.startReading(), "No se pudo leer la pista")
        var packets: [Data] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let count = CMBlockBufferGetDataLength(block)
            if count == 0 { continue }
            var bytes = Data(count: count)
            let status = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!)
            }
            try require(status == noErr, "Datos de muestra inválidos")
            var offset = 0
            for index in 0..<CMSampleBufferGetNumSamples(sample) {
                let length = CMSampleBufferGetSampleSize(sample, at: index)
                try require(length > 0 && offset + length <= count, "Paquete inválido")
                packets.append(bytes.subdata(in: offset..<(offset + length)))
                offset += length
            }
            try require(offset == count, "Paquetes incompletos")
        }
        try require(reader.status == .completed, "Lectura incompleta")
        return packets
    }
}
