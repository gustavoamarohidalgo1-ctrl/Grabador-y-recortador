import Foundation
@preconcurrency import AVFoundation

/// A temporal edit that copies encoded media. The original is never modified.
enum VideoTrimmer {
    static func export(source: URL, destination: URL, range: CMTimeRange,
                       overwrite: Bool = false,
                       onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        let files = FileManager.default
        guard source.isFileURL, destination.isFileURL else {
            throw RecorderError.message("El video y la exportación deben estar en tu Mac.")
        }
        let original = source.standardizedFileURL.resolvingSymlinksInPath()
        let target = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard original != target, !sameFile(original, target) else {
            throw RecorderError.message("Elige otro nombre para conservar el video original.")
        }
        guard !files.fileExists(atPath: target.path) || overwrite else {
            throw RecorderError.message("Ya existe un archivo con ese nombre. Elige otro nombre para exportar.")
        }
        guard range.isValid, range.start.isNumeric, range.duration.isNumeric,
              CMTimeCompare(range.start, .zero) >= 0, CMTimeCompare(range.duration, .zero) > 0 else {
            throw RecorderError.message("Elige un inicio y un final válidos para el recorte.")
        }

        let asset = AVURLAsset(url: original)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard duration.isNumeric, !tracks.isEmpty,
              CMTimeCompare(CMTimeRangeGetEnd(range), duration) <= 0 else {
            throw RecorderError.message("El recorte debe estar dentro de la duración del video.")
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough),
              session.supportedFileTypes.contains(.mp4) else {
            throw RecorderError.message("Este archivo no se puede exportar a MP4 conservando su calidad original.")
        }
        // Passthrough keeps the encoded samples. Between keyframes, MP4 edit
        // lists hide the decoder's preroll; normal playback starts at the cut.
        session.timeRange = range
        session.shouldOptimizeForNetworkUse = true
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".foco-export-\(UUID().uuidString).mp4")
        defer { try? files.removeItem(at: temporary) }
        onProgress(0)
        let monitor = Task {
            for await state in session.states(updateInterval: 0.1) {
                if Task.isCancelled { break }
                if case .exporting(let progress) = state {
                    onProgress(min(0.99, max(0, progress.fractionCompleted)))
                }
            }
        }
        defer { monitor.cancel() }

        try await session.export(to: temporary, as: .mp4)
        monitor.cancel()
        await monitor.value
        try Task.checkCancellation()
        // Check again after export in case another process created the destination.
        guard original != target, !sameFile(original, target) else {
            throw RecorderError.message("No se reemplazará el archivo original. Elige otro nombre.")
        }
        if files.fileExists(atPath: target.path) {
            guard overwrite else {
                throw RecorderError.message("Ya existe un archivo con ese nombre. Tu video original se conserva.")
            }
            _ = try files.replaceItemAt(target, withItemAt: temporary)
        } else {
            try files.moveItem(at: temporary, to: target)
        }
        onProgress(1)
    }

    private static func sameFile(_ first: URL, _ second: URL) -> Bool {
        guard let a = try? FileManager.default.attributesOfItem(atPath: first.path),
              let b = try? FileManager.default.attributesOfItem(atPath: second.path),
              let inodeA = a[.systemFileNumber] as? NSNumber, let inodeB = b[.systemFileNumber] as? NSNumber,
              let deviceA = a[.systemNumber] as? NSNumber, let deviceB = b[.systemNumber] as? NSNumber else { return false }
        return inodeA == inodeB && deviceA == deviceB
    }
}
