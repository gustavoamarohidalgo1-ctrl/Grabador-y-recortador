import Foundation
import CoreMedia

@main
enum PauseSelfTest {
    static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 48_000) }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw RecorderError.message("PAUSE TEST: \(message)") }
    }

    static func equals(_ actual: CMTime?, _ expected: Double) -> Bool {
        guard let actual, actual.isNumeric else { return false }
        return abs(actual.seconds - expected) < 0.000_001
    }

    static func main() async throws {
        try timelineTests()
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("pause-test-source.mov")
        let destination = directory.appendingPathComponent("pause-test.mp4")
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: destination)
        try await MediaSelfTest.makeSyntheticMovie(at: source, simulatePause: true)
        try await MediaFinalizer.finalize(input: source, output: destination)
        try await MediaSelfTest.validateMovie(source: source, result: destination)
        print("PASS: 1 s de grabación + 5 s de pausa + 1 s de grabación = MP4 continuo de 2 s, 120 frames y ambas fuentes de audio.")
        print("Video de pausa sintético: \(destination.path)")
    }

    static func timelineTests() throws {
        var timeline = RecordingTimeline(origin: time(100))
        try require(!timeline.isPaused, "La sesión nueva empieza pausada")
        try require(timeline.presentationTime(for: time(99)) == nil, "Se aceptó una muestra anterior al origen")
        try require(equals(timeline.presentationTime(for: time(100)), 0), "Origen incorrecto")
        try require(equals(timeline.elapsed(at: time(101)), 1), "Tiempo inicial incorrecto")
        timeline.pause(at: time(102))
        try require(timeline.isPaused, "No se activó la pausa")
        timeline.pause(at: time(103))
        try require(equals(timeline.elapsed(at: time(106)), 2), "El contador no se congeló o pausar dos veces cambió el límite")
        try require(timeline.presentationTime(for: time(104)) == nil, "Se aceptó una muestra durante la pausa")
        timeline.resume(at: time(107))
        try require(!timeline.isPaused, "No se reanudó la sesión")
        timeline.resume(at: time(108))
        try require(equals(timeline.elapsed(at: time(110)), 5), "2 s + pausa de 5 s + 3 s no equivalen a 5 s")
        try require(equals(timeline.presentationTime(for: time(101)), 1), "Cambió el tiempo histórico antes de la pausa")
        try require(timeline.presentationTime(for: time(102)) == nil, "Se aceptó el inicio exacto de la pausa")
        try require(timeline.presentationTime(for: time(106.999)) == nil, "Se aceptó el final de la pausa")
        try require(equals(timeline.presentationTime(for: time(107)), 2), "El primer instante reanudado no es continuo")
        try require(equals(timeline.presentationTime(for: time(108)), 3), "La pausa no se descontó de la presentación")

        timeline.pause(at: time(111))
        timeline.resume(at: time(114))
        try require(equals(timeline.elapsed(at: time(116)), 8), "Varias pausas no se acumulan correctamente")
        try require(timeline.presentationTime(for: time(112)) == nil, "La segunda pausa no se excluyó")
        try require(equals(timeline.presentationTime(for: time(115)), 7), "Presentación después de dos pausas incorrecta")
        timeline.pause(at: time(116))
        try require(equals(timeline.elapsed(at: time(300)), 8), "Detener mientras está pausado incluye tiempo de espera")

        // Both sources use a shared timeline, including a frame just after resume.
        var shared = RecordingTimeline(origin: time(100))
        shared.pause(at: time(102)); shared.resume(at: time(107))
        for frame in 0..<60 {
            let host = CMTimeAdd(time(107), CMTime(value: Int64(frame), timescale: 60))
            let video = shared.presentationTime(for: host)
            let audio = shared.presentationTime(for: host)
            try require(video != nil && audio != nil && CMTimeCompare(video!, audio!) == 0,
                        "Audio y video no comparten el eje temporal")
            try require(CMTimeCompare(video!, CMTime(value: Int64(120 + frame), timescale: 60)) == 0,
                        "Un fotograma reanudado se desplazó fuera del intervalo de 60 fps")
        }
        try require(shared.presentationTime(for: time(102.001)) == nil,
                    "Se aceptó una muestra del lado pausado de un buffer que cruza el borde")
        try require(equals(shared.presentationTime(for: time(101.999)), 1.999),
                    "Se perdió el lado activo del límite de pausa")
        print("PASS: contador congelado, pausas múltiples/idempotentes, límites, tiempos históricos, parada en pausa y sincronía de audio/video.")
    }
}
