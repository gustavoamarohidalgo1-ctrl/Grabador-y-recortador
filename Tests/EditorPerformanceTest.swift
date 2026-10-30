import Foundation
import AppKit
@preconcurrency import AVFoundation
import Combine

/// Holds seek completions so bursts can be tested without decoding timing races.
private final class SeekProbePlayer: AVPlayer, @unchecked Sendable {
    var requests: [CMTime] = []
    var completions: [(Bool) -> Void] = []
    var playCount = 0

    override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime,
                       completionHandler: @escaping @Sendable (Bool) -> Void) {
        requests.append(time)
        completions.append(completionHandler)
    }
    override func play() { playCount += 1 }
    override func pause() {}
    func completeNext(_ finished: Bool = true) {
        precondition(!completions.isEmpty)
        completions.removeFirst()(finished)
    }
}

@main
enum EditorPerformanceTest {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw RecorderError.message("EDITOR: \(message)") }
    }

    @MainActor
    static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw RecorderError.message("EDITOR: operación asincrónica no terminó")
    }

    @MainActor
    static func main() async throws {
        let source = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dist/trim-source.mp4")
        let probe = SeekProbePlayer()
        let editor = VideoEditorModel(url: source, player: probe)
        var thumbnailNotifications = 0
        let observer = editor.$thumbnails.dropFirst().sink { _ in thumbnailNotifications += 1 }
        await editor.load()
        try require(editor.canExport && probe.requests.count == 1, "Carga del editor falló")
        // A thousand pointer events must not cancel/restart a thousand decoders.
        for index in 0..<1000 { editor.seek(to: Double(index) / 1000) }
        try require(probe.requests.count == 1, "Más de una búsqueda activa durante ráfaga")
        probe.completeNext()
        try await waitUntil { probe.requests.count == 2 }
        try require(abs(probe.requests.last!.seconds - 0.999) < 0.00001, "Se perdió el último destino")
        probe.completeNext()
        try await Task.sleep(nanoseconds: 5_000_000)
        try require(probe.requests.count == 2, "Se procesaron destinos descartados")
        print("PASS: 1.000 posiciones rápidas necesitan solo 2 búsquedas; el último destino se conserva.")

        editor.setStart(0.5)
        let beforeRepeatedPosition = probe.requests.count
        for _ in 0..<1000 { editor.setStart(0.5) }
        try require(probe.requests.count == beforeRepeatedPosition, "Se repite búsqueda del mismo fotograma")
        probe.completeNext()
        try await Task.sleep(nanoseconds: 5_000_000)
        editor.seek(to: 0.75, playWhenReady: true)
        editor.pausePlayback()
        probe.completeNext()
        try await Task.sleep(nanoseconds: 5_000_000)
        try require(probe.playCount == 0 && !editor.isPlaying, "Una respuesta antigua reanudó el video")
        editor.seek(to: 0.8, playWhenReady: true)
        probe.completeNext()
        try await waitUntil { editor.isPlaying }
        try require(probe.playCount == 1, "No reanudó tras la búsqueda actual")
        editor.pausePlayback()
        try await waitUntil { editor.thumbnails.count == 12 }
        try require(thumbnailNotifications <= 4, "Demasiadas actualizaciones de miniaturas")
        editor.seek(to: 0.9, playWhenReady: true)
        editor.close()
        probe.completeNext()
        try await Task.sleep(nanoseconds: 5_000_000)
        try require(probe.playCount == 1 && editor.player.currentItem == nil && editor.thumbnails.isEmpty && !editor.canExport,
                    "El cierre dejó reproducción o imágenes retenidas")
        _ = observer
        print("PASS: mismo fotograma sin trabajo repetido; pausa/cierre invalidan búsquedas; 12 miniaturas en 4 actualizaciones y se liberan al cerrar.")
    }
}
