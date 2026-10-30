import Foundation
import CoreGraphics
@preconcurrency import AVFoundation

private actor PreviewLedger {
    private(set) var active = 0
    private(set) var maximum = 0
    func opened() { active += 1; maximum = max(maximum, active) }
    func closed() { active -= 1 }
}

private actor PreviewGate {
    let ledger: PreviewLedger
    let delayed: Bool
    private(set) var options: PreviewOptions?
    private(set) var stopped = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(ledger: PreviewLedger, delayed: Bool) { self.ledger = ledger; self.delayed = delayed }
    func start(_ options: PreviewOptions) async {
        await ledger.opened()
        self.options = options
        if delayed { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { continuation?.resume(); continuation = nil }
    func stop() async {
        guard !stopped else { return }
        stopped = true
        await ledger.closed()
    }
}

private final class FakePreviewEngine: PreviewCapturing, @unchecked Sendable {
    let gate: PreviewGate
    let failsOnStart: Bool
    let frame: @Sendable (PreviewVideoFrame) -> Void
    let failure: @Sendable (Error) -> Void
    private let placementLock = NSLock()
    private var placement: CameraPlacement?
    var latestPlacement: CameraPlacement? {
        placementLock.lock()
        defer { placementLock.unlock() }
        return placement
    }
    func setCameraPlacement(_ value: CameraPlacement) {
        placementLock.lock()
        placement = value
        placementLock.unlock()
    }
    init(ledger: PreviewLedger, delayed: Bool, failsOnStart: Bool = false,
         frame: @escaping @Sendable (PreviewVideoFrame) -> Void, failure: @escaping @Sendable (Error) -> Void) {
        gate = PreviewGate(ledger: ledger, delayed: delayed)
        self.failsOnStart = failsOnStart
        self.frame = frame
        self.failure = failure
    }
    func start(options: PreviewOptions) async throws {
        await gate.start(options)
        if failsOnStart { throw RecorderError.message("Synthetic startup failure") }
    }
    func stop() async { await gate.stop() }
}

@main
enum LivePreviewTest {
    static func testCadence() {
        var cadence = PreviewFrameCadence()
        var now = 100.0
        var deadlines: [Double] = []
        let interval = 1.0 / Double(RecordingQuality.framesPerSecond)
        precondition(RecordingQuality.framesPerSecond == 60)
        for frame in 0..<600 {
            let deadline = cadence.deadline(at: now)
            deadlines.append(deadline)
            let jitter = Double(frame % 7) * 0.00008
            cadence.advance(scheduledFor: deadline, startedAt: deadline + jitter)
            // Composition takes 8 ms, but that cost must not delay every next slot.
            now = deadline + jitter + 0.008
        }
        precondition(abs(deadlines.last! - (100.0 + 599.0 * interval)) < 0.000001)
        precondition(zip(deadlines, deadlines.dropFirst()).allSatisfy { abs($1 - $0 - interval) < 0.000001 })
        let deadline = cadence.deadline(at: now)
        let stalled = deadline + 0.125
        cadence.advance(scheduledFor: deadline, startedAt: stalled)
        precondition(cadence.nextDeadline > stalled)
        precondition(cadence.nextDeadline - stalled <= interval + 0.000001)
        precondition(cadence.deadline(at: stalled) == cadence.nextDeadline)
        let afterIdle = stalled + 5
        precondition(cadence.deadline(at: afterIdle) == afterIdle)
        print("PASS: 600 plazos a 60 fps pese a 8 ms de composición y jitter; atrasos saltan plazos sin ráfagas y una fuente inactiva vuelve inmediatamente.")
    }

    @MainActor
    static func waitUntil(_ predicate: () async -> Bool) async throws {
        for _ in 0..<300 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        fatalError("Preview operation timed out")
    }

    static func frame(red: UInt8, green: UInt8) throws -> PreviewVideoFrame {
        var value: CVPixelBuffer?
        let result = CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &value)
        guard result == kCVReturnSuccess, let buffer = value else {
            throw RecorderError.message("Could not allocate synthetic preview surface")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<2 { for x in 0..<2 {
            let offset = y * stride + x * 4
            bytes[offset] = 0; bytes[offset + 1] = green
            bytes[offset + 2] = red; bytes[offset + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return PreviewVideoFrame(buffer: buffer)
    }

    @MainActor
    static func main() async throws {
        testCadence()
        let a = PreviewOptions(displayID: 1, cameraEnabled: true, cameraCorner: .bottomRight)
        let b = PreviewOptions(displayID: 2, cameraEnabled: true, cameraCorner: .topRight)
        let c = PreviewOptions(displayID: 3, cameraEnabled: false, cameraCorner: .topLeft)
        let red = try frame(red: 255, green: 0)
        let green = try frame(red: 0, green: 255)

        var screenAllowed = true
        var cameraStatus = AVAuthorizationStatus.authorized
        var requests = 0
        var settings: [String] = []
        let permissions = PreviewPermissionAccess(
            screenAllowed: { screenAllowed }, cameraStatus: { cameraStatus },
            requestScreen: { requests += 1; return screenAllowed },
            requestCamera: { requests += 1; return cameraStatus == .authorized },
            openSettings: { settings.append($0) })
        let presentation = CapturePresentation()
        let ledger = PreviewLedger()
        var engines: [FakePreviewEngine] = []
        let controller = LivePreviewController(presentation: presentation, permissions: permissions) { frame, failure in
            let engine = FakePreviewEngine(ledger: ledger, delayed: true, frame: frame, failure: failure)
            engines.append(engine)
            return engine
        }
        controller.update(options: a)
        try await waitUntil { guard !engines.isEmpty else { return false }; return await engines[0].gate.options == a }
        precondition(controller.state == .starting && requests == 0)
        await engines[0].gate.release()
        engines[0].frame(green)
        try await waitUntil { controller.state == .live && presentation.preview?.buffer === green.buffer }

        var moved = a
        for index in 0..<1000 {
            moved.cameraPlacement = CameraPlacement(x: Double(index % 100) / 99, y: Double(index / 100) / 9)
            controller.update(options: moved)
        }
        try await waitUntil { engines[0].latestPlacement == moved.cameraPlacement }
        precondition(engines.count == 1 && controller.state == .live,
                     "Dragging reopened devices or interrupted the live preview")
        precondition(presentation.preview?.buffer === green.buffer,
                     "Dragging unnecessarily cleared the current preview")
        print("PASS: 1.000 posiciones de cámara conservan el mismo motor y la vista previa; solo se aplica la posición más reciente.")

        controller.update(options: b)
        controller.update(options: c)
        try await waitUntil { guard engines.count == 2 else { return false }; return await engines[1].gate.options == c }
        let maximum = await ledger.maximum
        precondition(maximum == 1, "Preview engines overlapped")
        let firstStopped = await engines[0].gate.stopped
        precondition(firstStopped, "Changed preview kept old devices")
        // A new recording requests exclusive ownership while preview is starting.
        let suspension = Task { await controller.suspend() }
        try await Task.sleep(nanoseconds: 10_000_000)
        controller.update(options: a) // An obsolete visibility update cannot undo suspension.
        await engines[1].gate.release()
        await suspension.value
        precondition(controller.state == .idle && engines.count == 2)
        let activeAfterSuspension = await ledger.active
        precondition(activeAfterSuspension == 0)

        let recordingFeed = presentation.begin()
        controller.update(options: nil)
        recordingFeed.previews.yield(green)
        engines[0].frame(red)
        engines[1].frame(red)
        try await waitUntil { presentation.preview?.buffer === green.buffer }
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(presentation.preview?.buffer === green.buffer, "Old preview replaced a recording frame")
        if case .terminated = recordingFeed.previews.yield(green) { fatalError("Idle preview ended recording feed") }
        presentation.end()
        print("PASS: cambios rápidos usan la última configuración, no se superponen motores, suspender espera el inicio y las imágenes antiguas no afectan a la grabación.")

        // Automatic checks never open privacy UI. Camera-off preview needs no camera grant.
        screenAllowed = false
        cameraStatus = .denied
        var immediate: [FakePreviewEngine] = []
        let otherLedger = PreviewLedger()
        let other = LivePreviewController(presentation: presentation, permissions: permissions) { frame, failure in
            let engine = FakePreviewEngine(ledger: otherLedger, delayed: false, frame: frame, failure: failure)
            immediate.append(engine)
            return engine
        }
        other.update(options: c)
        try await waitUntil { other.state == .needsPermission }
        precondition(immediate.isEmpty && requests == 0 && settings.isEmpty)
        await other.activate()
        precondition(requests == 1 && settings == ["Privacy_ScreenCapture"])
        screenAllowed = true
        other.update(options: c)
        try await waitUntil { guard immediate.count == 1 else { return false }; return await immediate[0].gate.options == c }
        immediate[0].frame(green)
        try await waitUntil { other.state == .live }
        other.update(options: a)
        try await waitUntil { other.state == .needsPermission && other.permissionPage == "Privacy_Camera" }
        let activeWhileDenied = await otherLedger.active
        precondition(activeWhileDenied == 0)
        cameraStatus = .authorized
        other.update(options: a)
        try await waitUntil { guard immediate.count == 2 else { return false }; return await immediate[1].gate.options == a }
        immediate[1].frame(green)
        try await waitUntil { other.state == .live }
        immediate[1].failure(RecorderError.message("Synthetic interrupted stream"))
        try await waitUntil { other.state == .failed }
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(immediate.count == 2, "Failed capture automatically restarted in a loop")
        other.update(options: a)
        try await waitUntil { guard immediate.count == 3 else { return false }; return await immediate[2].gate.options == a }
        immediate[2].frame(green)
        immediate[0].failure(RecorderError.message("Obsolete error"))
        try await waitUntil { other.state == .live }
        await other.suspend()
        let finalActive = await otherLedger.active
        precondition(finalActive == 0 && other.state == .idle)
        print("PASS: permisos sin solicitudes automáticas, cámara desactivada sin permiso, permiso recién concedido se reevalúa, errores sin bucles y reintento explícito correcto.")

        // Camera-only preview must neither check nor request screen access.
        var cameraOnlyScreenChecks = 0
        var cameraOnlyScreenRequests = 0
        var cameraOnlyRequests = 0
        var cameraOnlyAuthorization = AVAuthorizationStatus.authorized
        var cameraOnlySettings: [String] = []
        let cameraOnlyPermissions = PreviewPermissionAccess(
            screenAllowed: { cameraOnlyScreenChecks += 1; return false },
            cameraStatus: { cameraOnlyAuthorization },
            requestScreen: { cameraOnlyScreenRequests += 1; return false },
            requestCamera: { cameraOnlyRequests += 1; cameraOnlyAuthorization = .authorized; return true },
            openSettings: { cameraOnlySettings.append($0) })
        var cameraOnlyEngines: [FakePreviewEngine] = []
        let cameraOnlyLedger = PreviewLedger()
        let cameraOnlyController = LivePreviewController(presentation: presentation, permissions: cameraOnlyPermissions) { frame, failure in
            let engine = FakePreviewEngine(ledger: cameraOnlyLedger, delayed: false, frame: frame, failure: failure)
            cameraOnlyEngines.append(engine)
            return engine
        }
        var cameraOnly = a
        cameraOnly.screenEnabled = false
        cameraOnlyController.update(options: cameraOnly)
        try await waitUntil { guard cameraOnlyEngines.count == 1 else { return false }; return await cameraOnlyEngines[0].gate.options == cameraOnly }
        cameraOnlyEngines[0].frame(green)
        try await waitUntil { cameraOnlyController.state == .live }
        precondition(cameraOnlyScreenChecks == 0 && cameraOnlyScreenRequests == 0 && cameraOnlyRequests == 0 && cameraOnlySettings.isEmpty,
                     "Camera-only preview requested screen access")
        cameraOnlyController.update(options: a)
        try await waitUntil { cameraOnlyController.state == .needsPermission && cameraOnlyController.permissionPage == "Privacy_ScreenCapture" }
        let cameraReleasedForScreen = await cameraOnlyEngines[0].gate.stopped
        precondition(cameraReleasedForScreen && cameraOnlyEngines.count == 1,
                     "Enabling screen kept the camera-only source alive or skipped screen permission")
        cameraOnlyController.update(options: cameraOnly)
        try await waitUntil { cameraOnlyEngines.count == 2 }
        cameraOnlyEngines[1].frame(green)
        try await waitUntil { cameraOnlyController.state == .live }
        cameraOnlyEngines[0].frame(red)
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(presentation.preview?.buffer === green.buffer, "Old camera-only session replaced current content")
        cameraOnlyEngines[1].failure(RecorderError.message("Synthetic camera-only failure"))
        try await waitUntil { cameraOnlyController.state == .failed }
        let failedCameraReleased = await cameraOnlyEngines[1].gate.stopped
        precondition(failedCameraReleased && presentation.preview == nil, "Failed camera-only preview retained devices or stale image")
        await cameraOnlyController.suspend()
        cameraOnlyAuthorization = .notDetermined
        cameraOnlyController.update(options: cameraOnly)
        try await waitUntil { cameraOnlyController.state == .needsPermission && cameraOnlyController.permissionPage == "Privacy_Camera" }
        let checksBeforeCameraActivation = cameraOnlyScreenChecks
        await cameraOnlyController.activate()
        try await waitUntil { cameraOnlyEngines.count == 3 }
        cameraOnlyEngines[2].frame(green)
        try await waitUntil { cameraOnlyController.state == .live }
        precondition(cameraOnlyScreenChecks == checksBeforeCameraActivation && cameraOnlyScreenRequests == 0 &&
                     cameraOnlyRequests == 1 && cameraOnlySettings.isEmpty,
                     "Camera-only activation opened unrelated screen privacy settings")
        await cameraOnlyController.suspend()
        let cameraOnlyMaximum = await cameraOnlyLedger.maximum
        let cameraOnlyActive = await cameraOnlyLedger.active
        precondition(cameraOnlyMaximum == 1 && cameraOnlyActive == 0)
        print("PASS: solo cámara sin permiso de pantalla; alternar fuentes libera dispositivos; errores descartan imágenes; activar pide únicamente cámara.")

        // A display-mode change needs new native surfaces, unlike a camera drag.
        var resizedEngines: [FakePreviewEngine] = []
        let resizedLedger = PreviewLedger()
        let resized = LivePreviewController(presentation: presentation, permissions: permissions) { frame, failure in
            let engine = FakePreviewEngine(ledger: resizedLedger, delayed: false, frame: frame, failure: failure)
            resizedEngines.append(engine)
            return engine
        }
        var native = a
        native.geometry = .native(width: 2940, height: 1912)
        resized.update(options: native)
        try await waitUntil { guard resizedEngines.count == 1 else { return false }; return await resizedEngines[0].gate.options == native }
        resizedEngines[0].frame(green)
        try await waitUntil { resized.state == .live }
        native.geometry = .native(width: 2560, height: 1664)
        resized.update(options: native)
        try await waitUntil { guard resizedEngines.count == 2 else { return false }; return await resizedEngines[1].gate.options == native }
        let oldSizeStopped = await resizedEngines[0].gate.stopped
        let maxResizedEngines = await resizedLedger.maximum
        precondition(oldSizeStopped && maxResizedEngines == 1, "Display resize kept old-sized surfaces or overlapped devices")
        await resized.suspend()
        print("PASS: cambiar el modo de pantalla reconstruye superficies nativas; arrastrar la cámara conserva el motor.")

        // A start that partially opens devices and then throws must release them before retry.
        var startupEngines: [FakePreviewEngine] = []
        let startupLedger = PreviewLedger()
        let startup = LivePreviewController(presentation: presentation, permissions: permissions) { frame, failure in
            let engine = FakePreviewEngine(ledger: startupLedger, delayed: false,
                                           failsOnStart: startupEngines.isEmpty, frame: frame, failure: failure)
            startupEngines.append(engine)
            return engine
        }
        startup.update(options: c)
        try await waitUntil { startup.state == .failed }
        let releasedAfterFailure = await startupLedger.active
        let failedStartStopped = await startupEngines[0].gate.stopped
        precondition(releasedAfterFailure == 0 && failedStartStopped && presentation.preview == nil)
        await startup.activate()
        try await waitUntil { guard startupEngines.count == 2 else { return false }; return await startupEngines[1].gate.options == c }
        startupEngines[1].frame(green)
        try await waitUntil { startup.state == .live && presentation.preview?.buffer === green.buffer }
        await startup.suspend()
        let releasedAfterRetry = await startupLedger.active
        precondition(releasedAfterRetry == 0 && startup.state == .idle)
        print("PASS: fallo durante el inicio libera los recursos y permite reintentar y detener correctamente.")
        print("Vista previa probada con motores simulados: ningún dispositivo real ni archivo de video utilizado.")
    }
}
