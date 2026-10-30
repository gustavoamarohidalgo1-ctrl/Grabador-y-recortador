import Foundation
@preconcurrency import AVFoundation
import ScreenCaptureKit
import CoreImage
import AudioToolbox

/// All media and writer state is owned by `queue`. No capture starts until `start`.
final class CaptureEngine: NSObject, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.foco.capture", qos: .userInitiated)
    private let cameraQueue = DispatchQueue(label: "com.foco.camera", qos: .userInitiated)
    private let onPreview: @Sendable (PreviewVideoFrame) -> Void
    private let onLevels: @Sendable (Double, Double) -> Void
    private let onFailure: @Sendable (Error) -> Void
    private var stream: SCStream?
    private var cameraSession: AVCaptureSession?
    private var microphoneSession: AVCaptureSession?
    private var cameraOutput: AVCaptureVideoDataOutput?
    private var microphoneOutput: AVCaptureAudioDataOutput?
    private var screenOutputAttached = false
    private var expectedScreenSize: CGSize?
    private var changingScreen = false
    private var screenTransitionFailure: Error?
    private var sessionID = UUID()
    private var frameTimer: DispatchSourceTimer?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var compositor: FrameCompositor?
    private var latestScreen: CVPixelBuffer?
    private var latestCamera: CVPixelBuffer?
    private var geometry = RecordingGeometry(width: 1920, height: 1080)
    private var temporaryURL: URL?
    private var destinationURL: URL?
    private var origin = CMTime.zero
    private var timeline = RecordingTimeline(origin: .zero)
    private var latestResumeHost: CMTime?
    private var lastVideoTime = CMTime.invalid
    private var isRecording = false
    private var isStopping = false
    private var didReportFailure = false
    private var frameCount = 0
    private var lastLevelPublication: Double = 0
    private var previewEnabled = true
    private let placementLock = NSLock()
    private var pendingCameraPlacement: CameraPlacement?
    private var lastSuccessfulVideo: Double = 0
    private var lastCameraHost: Double = 0
    private var stoppedDuration: Double = 0
    private var droppedAudioBuffers = 0
    private var systemOffset: CMTime?
    private var microphoneOffset: CMTime?
    private var lastSystemPTS = CMTime.invalid
    private var lastMicrophonePTS = CMTime.invalid
    private var systemLevel = 0.0
    private var microphoneLevel = 0.0
    private var systemLevelTime = 0.0
    private var microphoneLevelTime = 0.0
    private var systemMeterTime = -1.0
    private var microphoneMeterTime = -1.0
    private var systemSamples = 0
    private var microphoneSamples = 0
    private var options: RecordingOptions?

    init(onPreview: @escaping @Sendable (PreviewVideoFrame) -> Void,
         onLevels: @escaping @Sendable (Double, Double) -> Void,
         onFailure: @escaping @Sendable (Error) -> Void) {
        self.onPreview = onPreview
        self.onLevels = onLevels
        self.onFailure = onFailure
        super.init()
    }

    func start(options: RecordingOptions) async throws -> RecordingGeometry {
        let busy = queue.sync { writer != nil || isStopping }
        guard !busy else { throw RecorderError.message("Ya hay una grabación en curso.") }
        guard options.screenEnabled || options.cameraEnabled else {
            throw RecorderError.message("Activa la pantalla o la cámara antes de grabar.")
        }
        // Reading display dimensions does not capture its contents or require a
        // screen permission. Camera-only recording must work without that grant.
        let displayMode = CGDisplayCopyDisplayMode(options.displayID)
        let pixelWidth = displayMode?.pixelWidth ?? CGDisplayPixelsWide(options.displayID)
        let pixelHeight = displayMode?.pixelHeight ?? CGDisplayPixelsHigh(options.displayID)
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw RecorderError.message("La pantalla seleccionada ya no está disponible. Selecciona otra pantalla.")
        }
        let captureGeometry = RecordingGeometry.native(width: pixelWidth, height: pixelHeight)
        try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "Foco \(date.string(from: Date()))-\(UUID().uuidString.prefix(4))"
        let outputURL = options.outputDirectory.appendingPathComponent(name + ".mp4")
        let tempURL = options.outputDirectory.appendingPathComponent("." + name + ".captura.mov")
        do {
            if options.cameraEnabled { try await startCamera() }
            if options.microphoneEnabled { try await startMicrophone() }
            try queue.sync {
                self.sessionID = UUID()
                self.options = options
                self.geometry = captureGeometry
                self.destinationURL = outputURL
                self.temporaryURL = tempURL
                self.compositor = FrameCompositor(geometry: captureGeometry, corner: options.cameraCorner, placement: options.cameraPlacement, screenEnabled: options.screenEnabled)
                self.didReportFailure = false
                self.frameCount = 0
                self.latestScreen = nil
                self.lastVideoTime = .invalid
                self.systemOffset = nil
                self.microphoneOffset = nil
                self.lastSystemPTS = .invalid
                self.lastMicrophonePTS = .invalid
                self.systemSamples = 0
                self.microphoneSamples = 0
                self.droppedAudioBuffers = 0
                self.stoppedDuration = 0
                self.systemLevel = 0
                self.microphoneLevel = 0
                self.systemLevelTime = 0
                self.microphoneLevelTime = 0
                self.systemMeterTime = -1
                self.microphoneMeterTime = -1
                self.latestResumeHost = nil
                try self.prepareWriter(url: tempURL, options: options)
            }
            if options.screenEnabled || options.systemAudioEnabled {
                let identity = queue.sync { self.sessionID }
                _ = try await startScreenStream(options: options, screenEnabled: options.screenEnabled, identity: identity)
            }
            queue.sync {
                self.origin = CMClockGetTime(CMClockGetHostTimeClock())
                self.timeline = RecordingTimeline(origin: self.origin)
                self.lastLevelPublication = -1
                self.lastSuccessfulVideo = 0
                self.isRecording = true
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now(), repeating: .nanoseconds(RecordingQuality.frameIntervalNanoseconds), leeway: .milliseconds(1))
                timer.setEventHandler { [weak self] in autoreleasepool { self?.renderFrame() } }
                self.frameTimer = timer
                timer.resume()
            }
            return captureGeometry
        } catch {
            let failedStream = queue.sync { self.stream }
            try? await failedStream?.stopCapture()
            await stopCamera()
            await stopMicrophone()
            queue.sync {
                self.writer?.cancelWriting()
                self.clearState()
            }
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    /// Screen callbacks are physically disconnected in camera-only mode. Audio
    /// remains on its own outputs, and the movie canvas/timeline never changes.
    func setScreenEnabled(_ enabled: Bool) async throws {
        let state: (RecordingOptions, SCStream?, UUID)? = try queue.sync {
            guard isRecording, !isStopping, let options, !changingScreen else {
                throw RecorderError.message("Espera a que termine el cambio de fuente.")
            }
            guard options.screenEnabled != enabled else { return nil }
            guard enabled || options.cameraEnabled else {
                throw RecorderError.message("La cámara debe estar activada para usar Solo cámara.")
            }
            changingScreen = true
            screenTransitionFailure = nil
            return (options, stream, sessionID)
        }
        guard let (current, previousStream, identity) = state else { return }
        defer { queue.sync { if self.sessionID == identity { self.changingScreen = false } } }
        if enabled {
            var connectedStream: SCStream?
            do {
                if let previousStream {
                    connectedStream = previousStream
                    let configuration = screenConfiguration(options: current, screenEnabled: true)
                    try queue.sync {
                        guard self.isRecording, !self.isStopping, self.sessionID == identity,
                              self.stream === previousStream else { throw CancellationError() }
                        try previousStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                        self.screenOutputAttached = true
                        self.expectedScreenSize = CGSize(width: configuration.width, height: configuration.height)
                        self.latestScreen = nil
                    }
                    try await previousStream.updateConfiguration(configuration)
                } else {
                    connectedStream = try await startScreenStream(options: current, screenEnabled: true, identity: identity)
                }
                guard let connectedStream else { throw CancellationError() }
                // Keep writing full-camera frames while SCK prepares its first
                // native image, rather than freezing or changing the file clock.
                try await waitForScreenFrame(from: connectedStream, identity: identity)
                try queue.sync {
                    guard self.isRecording, !self.isStopping, self.sessionID == identity,
                          self.stream === connectedStream, self.latestScreen != nil else { throw CancellationError() }
                    self.options?.screenEnabled = true
                    self.compositor?.setScreenEnabled(true)
                }
            } catch {
                if let connectedStream {
                    let retainedAudio: Bool = queue.sync {
                        guard self.stream === connectedStream, self.sessionID == identity else { return false }
                        if self.screenOutputAttached { try? connectedStream.removeStreamOutput(self, type: .screen) }
                        self.screenOutputAttached = false
                        self.expectedScreenSize = nil
                        self.latestScreen = nil
                        if !current.systemAudioEnabled { self.stream = nil }
                        return current.systemAudioEnabled && !self.isStopping
                    }
                    if retainedAudio {
                        try? await connectedStream.updateConfiguration(screenConfiguration(options: current, screenEnabled: false))
                    } else { try? await connectedStream.stopCapture() }
                }
                throw error
            }
        } else {
            // Commit removal and camera composition together on the media queue;
            // queued old screen callbacks then fail the attached-output guard.
            try queue.sync {
                guard self.isRecording, !self.isStopping, self.sessionID == identity else { throw CancellationError() }
                if current.systemAudioEnabled, let previousStream, self.screenOutputAttached {
                    try previousStream.removeStreamOutput(self, type: .screen)
                }
                self.screenOutputAttached = false
                self.expectedScreenSize = nil
                self.latestScreen = nil
                self.options?.screenEnabled = false
                self.compositor?.setScreenEnabled(false)
                if !current.systemAudioEnabled { self.stream = nil }
            }
            if let previousStream {
                if current.systemAudioEnabled {
                    // No screen output remains; minimize the unused video canvas
                    // while preserving the independent system-audio output.
                    try? await previousStream.updateConfiguration(screenConfiguration(options: current, screenEnabled: false))
                } else {
                    try? await previousStream.stopCapture()
                }
            }
        }
    }

    private func waitForScreenFrame(from stream: SCStream, identity: UUID) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 8_000_000_000
        while true {
            try Task.checkCancellation()
            let ready = try queue.sync {
                guard self.sessionID == identity, self.isRecording, !self.isStopping,
                      self.stream === stream else { throw CancellationError() }
                if let failure = self.screenTransitionFailure { throw failure }
                return self.latestScreen != nil
            }
            if ready { return }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw RecorderError.message("No llegó la imagen de la pantalla. La grabación continúa con la cámara; revisa el permiso de pantalla y vuelve a intentarlo.")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func screenConfiguration(options: RecordingOptions, screenEnabled: Bool) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let mode = CGDisplayCopyDisplayMode(options.displayID)
        config.width = screenEnabled ? max(2, mode?.pixelWidth ?? CGDisplayPixelsWide(options.displayID)) : 2
        config.height = screenEnabled ? max(2, mode?.pixelHeight ?? CGDisplayPixelsHigh(options.displayID)) : 2
        config.minimumFrameInterval = screenEnabled ? RecordingQuality.frameDuration : CMTime(value: 1, timescale: 1)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3
        config.showsCursor = screenEnabled
        config.captureResolution = .best
        config.preservesAspectRatio = true
        config.captureDynamicRange = .SDR
        config.colorSpaceName = CGColorSpace.sRGB
        config.capturesAudio = options.systemAudioEnabled
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        // The microphone is independent of ScreenCaptureKit, so camera-only
        // capture never needs a screen stream merely to record the user's voice.
        config.captureMicrophone = false
        return config
    }

    private func startScreenStream(options: RecordingOptions, screenEnabled: Bool, identity: UUID) async throws -> SCStream {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == options.displayID }) else {
            throw RecorderError.message("La pantalla seleccionada ya no está disponible.")
        }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let configuration = screenConfiguration(options: options, screenEnabled: screenEnabled)
        let captureStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        if screenEnabled { try captureStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue) }
        if options.systemAudioEnabled { try captureStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        try queue.sync {
            guard self.sessionID == identity, self.writer != nil, !self.isStopping else { throw CancellationError() }
            self.stream = captureStream
            self.screenOutputAttached = screenEnabled
            self.expectedScreenSize = screenEnabled ? CGSize(width: configuration.width, height: configuration.height) : nil
        }
        do {
            try await captureStream.startCapture()
            try queue.sync {
                guard self.sessionID == identity, self.writer != nil, !self.isStopping,
                      self.stream === captureStream else { throw CancellationError() }
            }
            return captureStream
        } catch {
            try? await captureStream.stopCapture()
            queue.sync {
                if self.stream === captureStream {
                    self.stream = nil
                    self.screenOutputAttached = false
                    self.expectedScreenSize = nil
                    self.latestScreen = nil
                }
            }
            throw error
        }
    }

    var elapsedDuration: TimeInterval {
        queue.sync {
            if isRecording { return CMTimeGetSeconds(timeline.elapsed(at: CMClockGetTime(CMClockGetHostTimeClock()))) }
            return stoppedDuration
        }
    }

    /// UI polling must never wait synchronously for GPU composition or encoding.
    func readElapsedDuration() async -> TimeInterval {
        await withCheckedContinuation { continuation in
            queue.async {
                let value = self.isRecording
                    ? CMTimeGetSeconds(self.timeline.elapsed(at: CMClockGetTime(CMClockGetHostTimeClock())))
                    : self.stoppedDuration
                continuation.resume(returning: value)
            }
        }
    }

    func setPreviewEnabled(_ enabled: Bool) {
        queue.async {
            self.previewEnabled = enabled
            if enabled { self.lastLevelPublication = -1 }
        }
    }

    /// Drag events replace one pending value instead of adding work to the writer queue.
    /// During pause the last position waits for the next recorded frame on resume.
    func setCameraPlacement(_ placement: CameraPlacement) {
        placementLock.lock()
        pendingCameraPlacement = placement
        placementLock.unlock()
    }

    private func takeCameraPlacement() -> CameraPlacement? {
        placementLock.lock()
        defer { placementLock.unlock() }
        let value = pendingCameraPlacement
        pendingCameraPlacement = nil
        return value
    }

    /// Both tracks and the render timer observe this transition on the media queue.
    /// Capture devices stay connected, but paused samples are never written to disk.
    func setPaused(_ paused: Bool) throws -> TimeInterval {
        try queue.sync {
            guard isRecording, !isStopping, writer?.status == .writing else {
                throw RecorderError.message("No hay una grabación activa para pausar o reanudar.")
            }
            if paused != timeline.isPaused {
                if paused {
                    // Preserve a final image at the boundary before freezing the timeline.
                    renderFrame()
                    timeline.pause(at: CMClockGetTime(CMClockGetHostTimeClock()))
                    // No video timer wakeups are needed while the timeline is frozen.
                    frameTimer?.schedule(deadline: .distantFuture)
                } else {
                    let host = CMClockGetTime(CMClockGetHostTimeClock())
                    timeline.resume(at: host)
                    latestResumeHost = host
                    let seconds = CMTimeGetSeconds(timeline.elapsed(at: host))
                    // Give devices fresh watchdog grace after even a very long pause.
                    lastSuccessfulVideo = seconds
                    microphoneLevelTime = seconds
                    systemLevelTime = seconds
                    lastCameraHost = CMTimeGetSeconds(host)
                    lastLevelPublication = seconds - 1
                    microphoneMeterTime = seconds - 1
                    systemMeterTime = seconds - 1
                    frameTimer?.schedule(deadline: .now(), repeating: .nanoseconds(RecordingQuality.frameIntervalNanoseconds), leeway: .milliseconds(1))
                }
                microphoneLevel = 0
                systemLevel = 0
                onLevels(0, 0)
            }
            return CMTimeGetSeconds(timeline.elapsed(at: CMClockGetTime(CMClockGetHostTimeClock())))
        }
    }

    func stop() async throws -> RecordingResult {
        let captureStream: SCStream? = try queue.sync {
            guard writer != nil, !isStopping else {
                throw RecorderError.message("No hay una grabación activa para guardar.")
            }
            isStopping = true
            // Give even a very short recording a final video frame.
            if isRecording { renderFrame() }
            stoppedDuration = max(CMTimeGetSeconds(timeline.elapsed(at: CMClockGetTime(CMClockGetHostTimeClock()))),
                                  lastVideoTime.isValid ? CMTimeGetSeconds(CMTimeAdd(lastVideoTime, RecordingQuality.frameDuration)) : 0)
            isRecording = false
            frameTimer?.cancel()
            frameTimer = nil
            return stream
        }
        // A stopped/unplugged display may already have ended the stream; finish its file anyway.
        try? await captureStream?.stopCapture()
        await stopCamera()
        await stopMicrophone()
        let state = queue.sync { () -> (AVAssetWriter?, URL?, URL?, RecordingGeometry, Double, Int, Int, Int, RecordingOptions?, Int) in
            return (writer, temporaryURL, destinationURL, geometry, stoppedDuration, frameCount, systemSamples, microphoneSamples, options, droppedAudioBuffers)
        }
        guard let activeWriter = state.0, let tempURL = state.1, let outputURL = state.2 else {
            queue.sync { clearState() }
            throw RecorderError.message("No se pudo recuperar el archivo de la grabación.")
        }
        guard state.5 > 0 else {
            queue.sync { activeWriter.cancelWriting(); clearState() }
            try? FileManager.default.removeItem(at: tempURL)
            throw RecorderError.message("No se recibió ninguna imagen de la fuente seleccionada. Revisa sus permisos y vuelve a intentarlo.")
        }
        do {
            let recordedDuration = state.4
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    guard let finishingWriter = self.writer, finishingWriter.status == .writing else {
                        continuation.resume(throwing: self.writer?.error ?? RecorderError.message("No se pudo escribir el video. Comprueba el espacio disponible."))
                        return
                    }
                    finishingWriter.endSession(atSourceTime: CMTime(seconds: recordedDuration, preferredTimescale: 60_000))
                    self.videoInput?.markAsFinished()
                    self.systemInput?.markAsFinished()
                    self.microphoneInput?.markAsFinished()
                    finishingWriter.finishWriting {
                        self.queue.async {
                            if self.writer?.status == .completed { continuation.resume() }
                            else { continuation.resume(throwing: self.writer?.error ?? RecorderError.message("No se pudo cerrar el archivo de video.")) }
                        }
                    }
                }
            }
        } catch {
            queue.sync { clearState() }
            throw RecorderError.message("No se pudo terminar la grabación: \(error.localizedDescription). Se conservó el archivo temporal en \(tempURL.path).")
        }
        queue.sync { clearState() }
        var warnings: [String] = []
        if state.8?.systemAudioEnabled == true && state.6 == 0 {
            warnings.append("No se recibieron muestras de audio del equipo.")
        }
        if state.8?.microphoneEnabled == true && state.7 == 0 {
            warnings.append("No se recibieron muestras del micrófono; revisa el dispositivo y su permiso.")
        }
        if state.9 > 0 {
            warnings.append("Hubo pequeños cortes de audio porque el equipo no pudo escribir todas las muestras a tiempo.")
        }
        do {
            try await MediaFinalizer.finalize(input: tempURL, output: outputURL)
            try? FileManager.default.removeItem(at: tempURL)
            return makeResult(url: outputURL, duration: state.4, geometry: state.3, warning: warnings.isEmpty ? nil : warnings.joined(separator: " "))
        } catch {
            // Keep the usable original if final mixing fails; never silently delete a recording.
            let recoveryURL = outputURL.deletingPathExtension().appendingPathExtension("recuperacion.mov")
            var actualURL = tempURL
            if (try? FileManager.default.moveItem(at: tempURL, to: recoveryURL)) != nil { actualURL = recoveryURL }
            warnings.append("Se guardó un MOV de recuperación porque no se pudo mezclar el audio: \(error.localizedDescription). Puede contener las fuentes de audio en pistas separadas.")
            return makeResult(url: actualURL, duration: state.4, geometry: state.3, warning: warnings.joined(separator: " "))
        }
    }

    private func prepareWriter(url: URL, options: RecordingOptions) throws {
        let assetWriter = try AVAssetWriter(outputURL: url, fileType: .mov)
        guard assetWriter.canApply(outputSettings: geometry.videoSettings, forMediaType: .video) else {
            throw RecorderError.message("Este Mac no puede codificar la resolución nativa seleccionada. Elige otra pantalla o ajusta su resolución en macOS.")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: geometry.videoSettings)
        input.expectsMediaDataInRealTime = true
        guard assetWriter.canAdd(input) else { throw RecorderError.message("Este Mac no puede crear el video H.264 solicitado.") }
        assetWriter.add(input)
        videoInput = input
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: geometry.width,
            kCVPixelBufferHeightKey as String: geometry.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        func audioInput(channels: Int) throws -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels == 1 ? 96_000 : 128_000
            ])
            input.expectsMediaDataInRealTime = true
            guard assetWriter.canAdd(input) else { throw RecorderError.message("No se pudo configurar una de las fuentes de audio.") }
            assetWriter.add(input)
            return input
        }
        if options.systemAudioEnabled { systemInput = try audioInput(channels: 2) }
        if options.microphoneEnabled { microphoneInput = try audioInput(channels: 1) }
        writer = assetWriter
        guard assetWriter.startWriting() else { throw assetWriter.error ?? RecorderError.message("No se pudo crear el archivo de grabación.") }
        assetWriter.startSession(atSourceTime: .zero)
    }

    private func startCamera() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            cameraQueue.async {
                do {
                    guard let device = AVCaptureDevice.default(for: .video) else {
                        throw RecorderError.message("No se encontró una cámara. Conecta una o desactiva Cámara.")
                    }
                    let session = AVCaptureSession()
                    session.beginConfiguration()
                    if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
                    else if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else { throw RecorderError.message("La cámara no está disponible en este momento.") }
                    session.addInput(input)
                    let output = AVCaptureVideoDataOutput()
                    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    output.alwaysDiscardsLateVideoFrames = true
                    output.setSampleBufferDelegate(self, queue: self.queue)
                    guard session.canAddOutput(output) else { throw RecorderError.message("No se pudo preparar la imagen de la cámara.") }
                    session.addOutput(output)
                    // Use 60 fps for the camera too when the physical device offers it.
                    // A camera limited to 30 fps remains usable inside the 60 fps movie.
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
                    session.commitConfiguration()
                    self.cameraSession = session
                    self.queue.sync { self.cameraOutput = output }
                    session.startRunning()
                    guard session.isRunning else { throw RecorderError.message("No se pudo iniciar la cámara.") }
                    // On macOS, configure the device after the session applies its preset.
                    if let format = cameraFormats.first {
                        try device.lockForConfiguration()
                        device.activeFormat = format
                        device.activeVideoMinFrameDuration = RecordingQuality.frameDuration
                        device.activeVideoMaxFrameDuration = RecordingQuality.frameDuration
                        device.unlockForConfiguration()
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func startMicrophone() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            cameraQueue.async {
                do {
                    guard let device = AVCaptureDevice.default(for: .audio) else {
                        throw RecorderError.message("No se encontró un micrófono. Conecta uno o desactiva Micrófono.")
                    }
                    let session = AVCaptureSession()
                    session.beginConfiguration()
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else { throw RecorderError.message("El micrófono no está disponible.") }
                    session.addInput(input)
                    let output = AVCaptureAudioDataOutput()
                    output.audioSettings = [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: 48_000,
                        AVNumberOfChannelsKey: 1,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false,
                        AVLinearPCMIsBigEndianKey: false,
                        AVLinearPCMIsNonInterleaved: false
                    ]
                    output.setSampleBufferDelegate(self, queue: self.queue)
                    guard session.canAddOutput(output) else { throw RecorderError.message("No se pudo preparar el audio del micrófono.") }
                    session.addOutput(output)
                    session.commitConfiguration()
                    self.microphoneSession = session
                    self.queue.sync { self.microphoneOutput = output }
                    session.startRunning()
                    guard session.isRunning else { throw RecorderError.message("No se pudo iniciar el micrófono.") }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func stopMicrophone() async {
        await withCheckedContinuation { continuation in
            cameraQueue.async {
                self.microphoneSession?.stopRunning()
                self.microphoneSession = nil
                self.queue.sync { self.microphoneOutput = nil }
                continuation.resume()
            }
        }
    }

    private func stopCamera() async {
        await withCheckedContinuation { continuation in
            cameraQueue.async {
                self.cameraSession?.stopRunning()
                self.cameraSession = nil
                self.queue.sync { self.cameraOutput = nil }
                continuation.resume()
            }
        }
    }

    private func renderFrame() {
        guard isRecording, !timeline.isPaused else { return }
        let now = timeline.elapsed(at: CMClockGetTime(CMClockGetHostTimeClock()))
        let seconds = CMTimeGetSeconds(now)
        if options?.microphoneEnabled == true && seconds > 8 && seconds - microphoneLevelTime > 8 {
            reportFailure(RecorderError.message("El micrófono no está enviando audio. Revisa el dispositivo y vuelve a grabar."))
            return
        }
        if options?.cameraEnabled == true, seconds > 8 {
            let host = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
            if latestCamera == nil || host - lastCameraHost > 8 {
                reportFailure(RecorderError.message("La cámara dejó de enviar imágenes. Revisa su conexión y que otra aplicación no la esté usando."))
                return
            }
        }
        let screenEnabled = options?.screenEnabled ?? true
        guard let input = videoInput, let adaptor, let compositor else { return }
        guard screenEnabled ? latestScreen != nil : latestCamera != nil else {
            if seconds - lastSuccessfulVideo > 8 {
                reportFailure(RecorderError.message(screenEnabled
                    ? "No llegan imágenes de la pantalla. Revisa el permiso de grabación de pantalla."
                    : "No llegan imágenes de la cámara. Revisa su conexión y permiso."))
            }
            return
        }
        guard writer?.status == .writing else {
            reportFailure(writer?.error ?? RecorderError.message("La grabación se interrumpió al escribir el video."))
            return
        }
        guard input.isReadyForMoreMediaData else {
            if seconds - lastSuccessfulVideo > 8 { reportFailure(RecorderError.message("El Mac no pudo seguir escribiendo el video. Comprueba el espacio disponible.")) }
            return
        }
        // Quantize presentation timestamps to the 60 Hz timeline while preserving
        // wall-clock gaps under load, so audio stays synchronized.
        let videoTime = CMTime(value: Int64((seconds * Double(RecordingQuality.framesPerSecond)).rounded()),
                               timescale: RecordingQuality.framesPerSecond)
        guard !lastVideoTime.isValid || CMTimeCompare(videoTime, lastVideoTime) > 0,
              let pool = adaptor.pixelBufferPool else { return }
        if let placement = takeCameraPlacement() { compositor.setCameraPlacement(placement) }
        guard let buffer = compositor.frame(screen: screenEnabled ? latestScreen : nil, camera: options?.cameraEnabled == true ? latestCamera : nil, pool: pool) else {
            reportFailure(RecorderError.message("No hay suficiente memoria para seguir grabando."))
            return
        }
        guard adaptor.append(buffer, withPresentationTime: videoTime) else {
            reportFailure(writer?.error ?? RecorderError.message("No se pudo guardar un fotograma del video."))
            return
        }
        lastVideoTime = videoTime
        lastSuccessfulVideo = seconds
        frameCount += 1
        // The writer owns the completed frame first. Presentation only retains
        // this immutable surface in a bounded stream; no image readback, resize,
        // display wait or separate GPU composition runs on the recording path.
        if previewEnabled { onPreview(PreviewVideoFrame(buffer: buffer)) }
        if seconds - lastLevelPublication >= 0.16 {
            lastLevelPublication = seconds
            onLevels(seconds - microphoneLevelTime < 0.6 ? microphoneLevel : 0,
                     seconds - systemLevelTime < 0.6 ? systemLevel : 0)
        }
    }

    private func appendAudio(_ sample: CMSampleBuffer, microphone: Bool) {
        guard let input = microphone ? microphoneInput : systemInput,
              writer?.status == .writing, CMSampleBufferDataIsReady(sample) else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid, pts.isNumeric else { return }
        // ScreenCaptureKit normally timestamps against the host clock. Some microphone
        // devices expose another clock origin. Normalize that origin once, preserving
        // all subsequent timing and gaps instead of timestamping every arrival.
        var offset = microphone ? microphoneOffset : systemOffset
        if offset == nil {
            let difference = CMTimeSubtract(now, pts)
            let duration = CMSampleBufferGetDuration(sample)
            // Alternate device clocks are aligned by the end of the first buffer;
            // calibrate even while paused, without ever appending that buffer.
            let bufferDuration = duration.isNumeric && CMTimeCompare(duration, .zero) > 0 ? duration : .zero
            offset = abs(CMTimeGetSeconds(difference)) > 2 ? CMTimeSubtract(difference, bufferDuration) : .zero
            if microphone { microphoneOffset = offset } else { systemOffset = offset }
        }
        guard isRecording, !timeline.isPaused else { return }
        let hostPTS = CMTimeAdd(pts, offset ?? .zero)
        // Capture callbacks can arrive after resume even though their audio belongs
        // to the pause. Reject the entire boundary buffer instead of leaking it.
        if let resumed = latestResumeHost, CMTimeCompare(hostPTS, resumed) < 0 { return }
        guard let adjustedPTS = timeline.presentationTime(for: hostPTS) else { return }
        let shift = CMTimeSubtract(adjustedPTS, pts)
        let lastPTS = microphone ? lastMicrophonePTS : lastSystemPTS
        guard !lastPTS.isValid || CMTimeCompare(adjustedPTS, lastPTS) > 0 else { return }
        let seconds = CMTimeGetSeconds(timeline.elapsed(at: now))
        // Meters are displayed at ~6 Hz. Keep audio liveness current for every
        // sample, but calculate RMS at 10 Hz instead of for every audio buffer.
        if microphone {
            microphoneLevelTime = seconds
            if seconds - microphoneMeterTime >= 0.1 {
                microphoneLevel = Self.audioLevel(sample)
                microphoneMeterTime = seconds
            }
        } else {
            systemLevelTime = seconds
            if seconds - systemMeterTime >= 0.1 {
                systemLevel = Self.audioLevel(sample)
                systemMeterTime = seconds
            }
        }
        guard input.isReadyForMoreMediaData else { droppedAudioBuffers += 1; return }
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr, count > 0 else { return }
        var timings = Array(repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: nil) == noErr else { return }
        for index in timings.indices {
            timings[index].presentationTimeStamp = CMTimeAdd(timings[index].presentationTimeStamp, shift)
            if timings[index].decodeTimeStamp.isValid { timings[index].decodeTimeStamp = CMTimeAdd(timings[index].decodeTimeStamp, shift) }
        }
        var adjusted: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: count, sampleTimingArray: &timings, sampleBufferOut: &adjusted) == noErr, let adjusted else { return }
        if input.append(adjusted) {
            if microphone { lastMicrophonePTS = adjustedPTS; microphoneSamples += 1 }
            else { lastSystemPTS = adjustedPTS; systemSamples += 1 }
        } else {
            reportFailure(writer?.error ?? RecorderError.message("No se pudo guardar el audio de la grabación."))
        }
    }

    private static func audioLevel(_ sample: CMSampleBuffer) -> Double {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              let block = CMSampleBufferGetDataBuffer(sample) else { return 0 }
        var length = 0
        var total = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: &total, dataPointerOut: &pointer) == noErr,
              let pointer, length > 0 else { return 0 }
        let stride = max(1, Int(asbd.mBitsPerChannel / 8))
        let count = length / stride
        guard count > 0 else { return 0 }
        let step = max(1, count / 256)
        var sum = 0.0
        var samples = 0
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 && asbd.mBitsPerChannel == 32 {
            pointer.withMemoryRebound(to: Float.self, capacity: count) { values in
                for index in Swift.stride(from: 0, to: count, by: step) { let value = Double(values[index]); sum += value * value; samples += 1 }
            }
        } else if asbd.mBitsPerChannel == 16 {
            pointer.withMemoryRebound(to: Int16.self, capacity: count) { values in
                for index in Swift.stride(from: 0, to: count, by: step) { let value = Double(values[index]) / 32768; sum += value * value; samples += 1 }
            }
        }
        guard samples > 0 else { return 0 }
        let rms = sqrt(sum / Double(samples))
        return max(0, min(1, (20 * log10(max(0.000001, rms)) + 60) / 60))
    }

    private func reportFailure(_ error: Error) {
        guard !didReportFailure, !isStopping else { return }
        didReportFailure = true
        onFailure(error)
    }

    private func makeResult(url: URL, duration: Double, geometry: RecordingGeometry, warning: String?) -> RecordingResult {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return RecordingResult(url: url, duration: duration, geometry: geometry, bytes: size, warning: warning)
    }

    private func clearState() {
        frameTimer?.cancel()
        frameTimer = nil
        stream = nil
        screenOutputAttached = false
        expectedScreenSize = nil
        changingScreen = false
        screenTransitionFailure = nil
        sessionID = UUID()
        writer = nil
        videoInput = nil
        systemInput = nil
        microphoneInput = nil
        adaptor = nil
        compositor = nil
        _ = takeCameraPlacement()
        latestScreen = nil
        latestCamera = nil
        temporaryURL = nil
        destinationURL = nil
        isRecording = false
        isStopping = false
        options = nil
        timeline = RecordingTimeline(origin: .zero)
        latestResumeHost = nil
    }
}

extension CaptureEngine: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard self.stream === stream, CMSampleBufferIsValid(sampleBuffer) else { return }
        switch type {
        case .screen:
            guard screenOutputAttached else { return }
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
               let rawStatus = attachments.first?[.status] as? Int,
               let status = SCFrameStatus(rawValue: rawStatus), status != .complete { return }
            if let image = CMSampleBufferGetImageBuffer(sampleBuffer) {
                // Reject an old 2×2 audio-only configuration frame when the
                // screen output is reconnected to its native-size stream.
                guard let expectedScreenSize,
                      CVPixelBufferGetWidth(image) == Int(expectedScreenSize.width),
                      CVPixelBufferGetHeight(image) == Int(expectedScreenSize.height) else { return }
                latestScreen = image
                compositor?.invalidateFrame()
            }
        case .audio: appendAudio(sampleBuffer, microphone: false)
        case .microphone: appendAudio(sampleBuffer, microphone: true)
        @unknown default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            guard self.isRecording, self.stream === stream else { return }
            if self.changingScreen, self.options?.screenEnabled == false,
               self.options?.systemAudioEnabled == false {
                self.screenTransitionFailure = error
                return
            }
            self.reportFailure(RecorderError.message("La captura se interrumpió: \(error.localizedDescription)"))
        }
    }
}

extension CaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === microphoneOutput {
            appendAudio(sampleBuffer, microphone: true)
            return
        }
        guard output === cameraOutput, let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // AVCaptureVideoDataOutput delivers on the same serial queue as ScreenCaptureKit.
        latestCamera = image
        compositor?.invalidateFrame()
        lastCameraHost = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
    }
}
