import Foundation
@preconcurrency import AVFoundation
import ScreenCaptureKit
import CoreImage

struct PreviewOptions: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let cameraEnabled: Bool
    let cameraCorner: CameraCorner
    var cameraPlacement: CameraPlacement? = nil
    var geometry: RecordingGeometry? = nil
    var screenEnabled: Bool = true
}

protocol PreviewCapturing: AnyObject, Sendable {
    func start(options: PreviewOptions) async throws
    func stop() async
    func setCameraPlacement(_ placement: CameraPlacement)
}

/// Deadlines follow the requested cadence, not the end of image composition.
/// Late work skips expired slots instead of queuing a burst of stale frames.
struct PreviewFrameCadence {
    private(set) var nextDeadline = -Double.infinity
    private let interval = 1.0 / Double(RecordingQuality.framesPerSecond)

    func deadline(at now: TimeInterval) -> TimeInterval { max(now, nextDeadline) }

    mutating func advance(scheduledFor deadline: TimeInterval, startedAt now: TimeInterval) {
        nextDeadline = deadline + interval
        if nextDeadline <= now {
            nextDeadline += (floor((now - nextDeadline) / interval) + 1) * interval
        }
    }
}

/// Live composition only: no writer, audio capture, output URL or recording clock.
/// The controller serializes start/stop, and all frame state belongs to `queue`.
final class PreviewEngine: NSObject, PreviewCapturing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.foco.idle-preview", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let cameraQueue = DispatchQueue(label: "com.foco.idle-preview.camera", qos: .userInitiated)
    private let onFrame: @Sendable (PreviewVideoFrame) -> Void
    private let onFailure: @Sendable (Error) -> Void
    private var stream: SCStream?
    private var compositor: FrameCompositor?
    private var pool: CVPixelBufferPool?
    private var latestScreen: CVPixelBuffer?
    private var latestCamera: CVPixelBuffer?
    private var cameraOutput: AVCaptureVideoDataOutput?
    private var acceptingFrames = false
    private var expectsCamera = false
    private var screenEnabled = true
    private var didReportFailure = false
    private var generation: UInt64 = 0
    private var pendingRender: DispatchWorkItem?
    private var firstFrameTimeout: DispatchWorkItem?
    private var lastRenderedHost = -Double.infinity
    private var cadence = PreviewFrameCadence()
    private let placementLock = NSLock()
    private var pendingCameraPlacement: CameraPlacement?
    private var placementWakePending = false

    // Only cameraQueue reads/writes the session and its notification observer.
    private var cameraSession: AVCaptureSession?
    private var cameraErrorObserver: NSObjectProtocol?

    init(onFrame: @escaping @Sendable (PreviewVideoFrame) -> Void,
         onFailure: @escaping @Sendable (Error) -> Void) {
        self.onFrame = onFrame
        self.onFailure = onFailure
        super.init()
    }

    func start(options: PreviewOptions) async throws {
        try Task.checkCancellation()
        guard queue.sync(execute: { !acceptingFrames && stream == nil }) else {
            throw RecorderError.message("La vista previa ya está iniciada.")
        }
        do {
            guard options.screenEnabled || options.cameraEnabled else {
                throw RecorderError.message("Activa la cámara o la pantalla para previsualizar.")
            }
            // Camera-only preview never enumerates screen content or creates a
            // ScreenCaptureKit stream. The display mode only sets the canvas.
            var content: SCShareableContent?
            var display: SCDisplay?
            if options.screenEnabled {
                let available = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                try Task.checkCancellation()
                guard let selected = available.displays.first(where: { $0.displayID == options.displayID }) else {
                    throw RecorderError.message("La pantalla seleccionada no está disponible. Elige otra pantalla para previsualizar.")
                }
                content = available
                display = selected
            }
            let mode = CGDisplayCopyDisplayMode(options.displayID)
            let pixelWidth = mode?.pixelWidth ?? display?.width ?? options.geometry?.width ?? 1920
            let pixelHeight = mode?.pixelHeight ?? display?.height ?? options.geometry?.height ?? 1080
            let geometry = RecordingGeometry.native(width: pixelWidth, height: pixelHeight)
            try queue.sync {
                var bufferPool: CVPixelBufferPool?
                let result = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                    [kCVPixelBufferPoolMinimumBufferCountKey as String: 2] as CFDictionary,
                    [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                     kCVPixelBufferWidthKey as String: geometry.width,
                     kCVPixelBufferHeightKey as String: geometry.height,
                     kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                    &bufferPool)
                guard result == kCVReturnSuccess, let bufferPool else {
                    throw RecorderError.message("No se pudo preparar la memoria de la vista previa.")
                }
                pool = bufferPool
                compositor = FrameCompositor(geometry: geometry, corner: options.cameraCorner, placement: options.cameraPlacement, screenEnabled: options.screenEnabled)
                latestScreen = nil
                latestCamera = nil
                lastRenderedHost = -Double.infinity
                cadence = PreviewFrameCadence()
                didReportFailure = false
                expectsCamera = options.cameraEnabled
                screenEnabled = options.screenEnabled
                generation &+= 1
                acceptingFrames = true
            }
            if options.cameraEnabled { try await startCamera() }
            try Task.checkCancellation()

            if let content, let display {
                let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
                let configuration = SCStreamConfiguration()
                configuration.width = max(2, pixelWidth)
                configuration.height = max(2, pixelHeight)
                configuration.minimumFrameInterval = RecordingQuality.frameDuration
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.queueDepth = 3
                configuration.showsCursor = true
                configuration.captureResolution = .best
                configuration.preservesAspectRatio = true
                configuration.captureDynamicRange = .SDR
                configuration.colorSpaceName = CGColorSpace.sRGB
                configuration.capturesAudio = false
                configuration.captureMicrophone = false
                let captureStream = SCStream(filter: filter, configuration: configuration, delegate: self)
                try captureStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                queue.sync { stream = captureStream }
                try await captureStream.startCapture()
            }
            try Task.checkCancellation()
            queue.async { [weak self] in self?.scheduleFirstFrameTimeout() }
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        let previous: SCStream? = await withCheckedContinuation { continuation in
            queue.async {
                self.acceptingFrames = false
                self.generation &+= 1
                self.pendingRender?.cancel(); self.pendingRender = nil
                self.firstFrameTimeout?.cancel(); self.firstFrameTimeout = nil
                let previous = self.stream
                self.stream = nil
                self.cameraOutput = nil
                self.latestScreen = nil
                self.latestCamera = nil
                self.expectsCamera = false
                self.screenEnabled = true
                self.compositor = nil
                self.pool = nil
                _ = self.takeCameraPlacement()
                continuation.resume(returning: previous)
            }
        }
        try? await previous?.stopCapture()
        await withCheckedContinuation { continuation in
            cameraQueue.async {
                if let observer = self.cameraErrorObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self.cameraErrorObserver = nil
                }
                self.cameraSession?.stopRunning()
                self.cameraSession = nil
                continuation.resume()
            }
        }
    }

    /// A drag updates one mailbox and at most one wakeup. Static desktops still
    /// repaint a moved camera, without restarting any capture devices.
    func setCameraPlacement(_ placement: CameraPlacement) {
        placementLock.lock()
        pendingCameraPlacement = placement
        let shouldWake = !placementWakePending
        placementWakePending = true
        placementLock.unlock()
        guard shouldWake else { return }
        queue.async { [weak self] in
            guard let self else { return }
            guard self.acceptingFrames, !self.didReportFailure, self.hasVideoSource else {
                self.placementLock.lock()
                self.placementWakePending = false
                self.placementLock.unlock()
                return
            }
            self.scheduleRender()
        }
    }

    private func takeCameraPlacement() -> CameraPlacement? {
        placementLock.lock()
        defer { placementLock.unlock() }
        let value = pendingCameraPlacement
        pendingCameraPlacement = nil
        placementWakePending = false
        return value
    }

    private func startCamera() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            cameraQueue.async { [self] in
                do {
                    guard let device = AVCaptureDevice.default(for: .video) else {
                        throw RecorderError.message("No se encontró una cámara. Conecta una o desactiva Cámara para ver la pantalla.")
                    }
                    let session = AVCaptureSession()
                    let output = AVCaptureVideoDataOutput()
                    do {
                        session.beginConfiguration()
                        defer { session.commitConfiguration() }
                        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
                        else if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
                        let input = try AVCaptureDeviceInput(device: device)
                        guard session.canAddInput(input) else {
                            throw RecorderError.message("La cámara no está disponible para la vista previa.")
                        }
                        session.addInput(input)
                        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                        output.alwaysDiscardsLateVideoFrames = true
                        output.setSampleBufferDelegate(self, queue: self.queue)
                        guard session.canAddOutput(output) else {
                            throw RecorderError.message("No se pudo preparar la cámara para la vista previa.")
                        }
                        session.addOutput(output)
                    }
                    self.cameraSession = session
                    self.queue.sync { self.cameraOutput = output }
                    self.cameraErrorObserver = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                        object: session, queue: nil) { [weak self, weak output] notification in
                            let detail = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription
                            self?.queue.async { [weak self, weak output] in
                                guard let self, let output, self.cameraOutput === output else { return }
                                self.reportFailure(RecorderError.message(detail ?? "La cámara se interrumpió durante la vista previa."))
                            }
                        }
                    session.startRunning()
                    guard session.isRunning else {
                        throw RecorderError.message("No se pudo iniciar la cámara para la vista previa.")
                    }
                    // Match the recorder's camera cadence when the hardware
                    // supports it. A 30 fps camera retains its native cadence.
                    let cameraFormats = device.formats.filter { format in
                        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                        return size.width >= 640 && size.width <= 1920 && size.height >= 480 && size.height <= 1080
                            && format.videoSupportedFrameRateRanges.contains {
                                $0.minFrameRate <= Double(RecordingQuality.framesPerSecond)
                                    && $0.maxFrameRate >= Double(RecordingQuality.framesPerSecond)
                            }
                    }.sorted { first, second in
                        let a = CMVideoFormatDescriptionGetDimensions(first.formatDescription)
                        let b = CMVideoFormatDescriptionGetDimensions(second.formatDescription)
                        return abs(Int(a.width * a.height) - 1920 * 1080) < abs(Int(b.width * b.height) - 1920 * 1080)
                    }
                    // Apply after startRunning, once the session preset is active.
                    if let format = cameraFormats.first {
                        try device.lockForConfiguration()
                        defer { device.unlockForConfiguration() }
                        device.activeFormat = format
                        device.activeVideoMinFrameDuration = RecordingQuality.frameDuration
                        device.activeVideoMaxFrameDuration = RecordingQuality.frameDuration
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private var hasVideoSource: Bool {
        screenEnabled ? latestScreen != nil : latestCamera != nil
    }

    private func scheduleRender() {
        guard acceptingFrames, !didReportFailure, hasVideoSource, pendingRender == nil else { return }
        let generation = generation
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let deadline = cadence.deadline(at: now)
        let delay = max(0, deadline - now)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.acceptingFrames, self.generation == generation else { return }
            self.pendingRender = nil
            self.cadence.advance(scheduledFor: deadline,
                                 startedAt: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
            autoreleasepool { self.render() }
        }
        pendingRender = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func render() {
        guard acceptingFrames, !didReportFailure, hasVideoSource, let pool, let compositor else { return }
        if let placement = takeCameraPlacement() { compositor.setCameraPlacement(placement) }
        guard let frame = compositor.frame(screen: screenEnabled ? latestScreen : nil, camera: latestCamera, pool: pool) else {
            reportFailure(RecorderError.message("No se pudo preparar la imagen de la vista previa."))
            return
        }
        lastRenderedHost = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        if !expectsCamera || latestCamera != nil {
            firstFrameTimeout?.cancel(); firstFrameTimeout = nil
        }
        onFrame(PreviewVideoFrame(buffer: frame))
    }

    private func scheduleFirstFrameTimeout() {
        guard acceptingFrames, !lastRenderedHost.isFinite || (expectsCamera && latestCamera == nil) else { return }
        let generation = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.acceptingFrames, self.generation == generation else { return }
            if !self.lastRenderedHost.isFinite {
                self.reportFailure(RecorderError.message(self.screenEnabled
                    ? "No llegan imágenes para la vista previa. Revisa el permiso de pantalla y vuelve a intentarlo."
                    : "No llegan imágenes de la cámara. Revisa su conexión y el permiso de cámara."))
            } else if self.expectsCamera && self.latestCamera == nil {
                self.reportFailure(RecorderError.message("No llegan imágenes de la cámara. Revisa su conexión o desactiva Cámara para previsualizar la pantalla."))
            }
        }
        firstFrameTimeout = work
        queue.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func reportFailure(_ error: Error) {
        guard acceptingFrames, !didReportFailure else { return }
        didReportFailure = true
        onFailure(error)
    }
}

extension PreviewEngine: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard acceptingFrames, screenEnabled, stream === self.stream, type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let rawStatus = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: rawStatus), status != .complete { return }
        guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latestScreen = image
        compositor?.invalidateFrame()
        scheduleRender()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            guard let self, stream === self.stream else { return }
            self.reportFailure(RecorderError.message("La vista previa se interrumpió: \(error.localizedDescription)"))
        }
    }
}

extension PreviewEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard acceptingFrames, output === cameraOutput, let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latestCamera = image
        compositor?.invalidateFrame()
        scheduleRender()
    }
}
