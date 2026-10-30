import AVFoundation
import Foundation

/// Copies compressed video unchanged. A single AAC source is copied too; two
/// sources are mixed into one stereo AAC track. Failed writes remain private,
/// and the original is never modified.
enum MediaFinalizer {
    static func finalize(input source: URL, output destination: URL) async throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw RecorderError.message("Ya existe un archivo con ese nombre. La grabación original se conserva.")
        }
        let asset = AVURLAsset(url: source)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        guard let video = videos.first else {
            throw RecorderError.message("La grabación no contiene imágenes. El archivo original se conserva.")
        }
        let formats = try await video.load(.formatDescriptions)
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration > .zero else {
            throw RecorderError.message("La grabación está vacía o tiene una duración inválida.")
        }
        let transform = try await video.load(.preferredTransform)
        let reader = try AVAssetReader(asset: asset)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".foco-finalize-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        do {
            let videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
            videoOutput.alwaysCopiesSampleData = false
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formats.first)
            videoInput.transform = transform
            guard reader.canAdd(videoOutput), writer.canAdd(videoInput) else {
                throw RecorderError.message("No se pudo preparar el video MP4.")
            }
            reader.add(videoOutput)
            writer.add(videoInput)
            var channels: [(AVAssetReaderOutput, AVAssetWriterInput)] = [(videoOutput, videoInput)]

            var copiedAudio = false
            if audios.count == 1, let audio = audios.first,
               let format = try await audio.load(.formatDescriptions).first,
               CMFormatDescriptionGetMediaSubType(format) == kAudioFormatMPEG4AAC {
                // With one source there is nothing to mix. Keeping its AAC packets
                // avoids a full decode/encode pass and another lossy generation.
                let audioOutput = AVAssetReaderTrackOutput(track: audio, outputSettings: nil)
                audioOutput.alwaysCopiesSampleData = false
                let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
                if reader.canAdd(audioOutput), writer.canAdd(audioInput) {
                    reader.add(audioOutput)
                    writer.add(audioInput)
                    channels.append((audioOutput, audioInput))
                    copiedAudio = true
                }
            }

            if !audios.isEmpty && !copiedAudio {
                let mixOutput = AVAssetReaderAudioMixOutput(audioTracks: audios, audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false
                ])
                mixOutput.alwaysCopiesSampleData = false
                let mix = AVMutableAudioMix()
                // Reserve headroom when adding independent full-scale sources.
                let gain: Float = audios.count > 1 ? 0.5 : 1.0
                mix.inputParameters = audios.map { track in
                    let parameters = AVMutableAudioMixInputParameters(track: track)
                    parameters.setVolume(gain, at: .zero)
                    return parameters
                }
                mixOutput.audioMix = mix
                let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 192_000
                ])
                guard reader.canAdd(mixOutput), writer.canAdd(audioInput) else {
                    throw RecorderError.message("No se pudo preparar la mezcla de audio.")
                }
                reader.add(mixOutput)
                writer.add(audioInput)
                channels.append((mixOutput, audioInput))
            }

            guard writer.startWriting() else { throw writer.error ?? RecorderError.message("No se pudo crear el MP4.") }
            writer.startSession(atSourceTime: .zero)
            guard reader.startReading() else { throw reader.error ?? RecorderError.message("No se pudo leer la grabación.") }
            let pipeline = TransferPipeline(reader: reader, writer: writer, channels: channels, duration: duration)
            try await pipeline.run()
            // Moving into place is atomic on this volume and refuses to overwrite
            // a destination created while the movie was being finalized.
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            reader.cancelReading()
            if writer.status == .writing { writer.cancelWriting() }
            throw error
        }
    }
}

private final class TransferPipeline: @unchecked Sendable {
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let channels: [(AVAssetReaderOutput, AVAssetWriterInput)]
    private let duration: CMTime
    private let coordination = DispatchQueue(label: "app.foco.finalize.coordination")
    private var remaining = 0
    private var completed = false
    private var continuation: CheckedContinuation<Void, Error>?

    init(reader: AVAssetReader, writer: AVAssetWriter,
         channels: [(AVAssetReaderOutput, AVAssetWriterInput)], duration: CMTime) {
        self.reader = reader
        self.writer = writer
        self.channels = channels
        self.duration = duration
    }

    func run() async throws {
        // Callback captures below are weak so completed writers do not retain
        // their pipeline through requestMediaDataWhenReady's stored closure.
        defer { withExtendedLifetime(self) {} }
        try await withCheckedThrowingContinuation { continuation in
            coordination.async { [self] in
                self.continuation = continuation
                self.remaining = self.channels.count
                for (index, pair) in self.channels.enumerated() {
                    let (output, input) = pair
                    let queue = DispatchQueue(label: "app.foco.finalize.track.\(index)")
                    var finished = false
                    input.requestMediaDataWhenReady(on: queue) { [weak self, weak input, weak output] in
                        guard let self, let input, let output else { return }
                        guard !finished else { return }
                        while input.isReadyForMoreMediaData {
                            // Long recordings must not accumulate autoreleased
                            // AVFoundation objects until the queue yields.
                            let shouldContinue = autoreleasepool { () -> Bool in
                                if self.writer.status != .writing {
                                    finished = true
                                    self.failed(self.writer.error ?? RecorderError.message("Se interrumpió el guardado del video."))
                                    return false
                                }
                                guard let sample = output.copyNextSampleBuffer() else {
                                    finished = true
                                    if self.reader.status == .failed {
                                        self.failed(self.reader.error ?? RecorderError.message("No se pudo leer una pista de la grabación."))
                                    } else {
                                        input.markAsFinished()
                                        self.channelFinished()
                                    }
                                    return false
                                }
                                guard input.append(sample) else {
                                    finished = true
                                    self.failed(self.writer.error ?? RecorderError.message("No se pudo escribir una pista del MP4."))
                                    return false
                                }
                                return true
                            }
                            if !shouldContinue { return }
                        }
                    }
                }
            }
        }
    }

    private func channelFinished() {
        coordination.async {
            guard !self.completed else { return }
            self.remaining -= 1
            guard self.remaining == 0 else { return }
            self.completed = true
            self.writer.endSession(atSourceTime: self.duration)
            self.writer.finishWriting {
                self.coordination.async {
                    if self.writer.status == .completed {
                        self.continuation?.resume()
                    } else {
                        self.continuation?.resume(throwing: self.writer.error ?? RecorderError.message("No se pudo finalizar el MP4."))
                    }
                    self.continuation = nil
                }
            }
        }
    }

    private func failed(_ error: Error) {
        coordination.async {
            guard !self.completed else { return }
            self.completed = true
            self.reader.cancelReading()
            self.writer.cancelWriting()
            self.continuation?.resume(throwing: error)
            self.continuation = nil
        }
    }
}
