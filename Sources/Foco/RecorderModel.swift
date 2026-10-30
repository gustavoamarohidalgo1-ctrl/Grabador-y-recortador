import AppKit
import AVFoundation
import Combine
import CoreGraphics
import UniformTypeIdentifiers

struct DisplayChoice: Identifiable {
    let id: CGDirectDisplayID
    let name: String
    let width: Int
    let height: Int
    var geometry: RecordingGeometry { .native(width: width, height: height) }
}

enum RecordingState: Equatable {
    case ready, preparing, recording, paused, saving
    var isBusy: Bool { self != .ready }
    var isSessionActive: Bool { self == .recording || self == .paused }
}

@MainActor
final class RecorderModel: ObservableObject {
    static let shared = RecorderModel()
    @Published var state: RecordingState = .ready { didSet { updateIdlePreview() } }
    @Published var displays: [DisplayChoice] = []
    @Published var selectedDisplayID: CGDirectDisplayID = CGMainDisplayID() { didSet { updateIdlePreview() } }
    @Published private(set) var screenEnabled = true
    @Published private(set) var isSwitchingSource = false
    @Published var cameraEnabled = true { didSet { updateIdlePreview() } }
    @Published var microphoneEnabled = true
    @Published var systemAudioEnabled = true
    @Published var cameraCorner: CameraCorner = .bottomRight {
        didSet { setCameraPlacement(.from(corner: cameraCorner)) }
    }
    @Published private(set) var cameraPlacement = CameraPlacement.from(corner: .bottomRight)
    let presentation = CapturePresentation()
    lazy var livePreview = LivePreviewController(presentation: presentation)
    @Published var elapsed: TimeInterval = 0
    @Published var outputDirectory: URL
    @Published var lastResult: RecordingResult?
    @Published var recentFiles: [URL] = []
    @Published var errorMessage: String?
    @Published var permissionPage: String?
    @Published var note: String?
    @Published var editor: VideoEditorModel? { didSet { updateIdlePreview() } }
    @Published private(set) var editorIsExporting = false
    private var editorExportObservation: AnyCancellable?
    private var editorLoadTask: Task<Void, Never>?
    private var exportProtectedWindows: [NSWindow] = []
    private var engine: CaptureEngine?
    private var timer: Timer?
    private var elapsedTask: Task<Void, Never>?
    private var recentFilesTask: Task<Void, Never>?
    private var previewIsVisible = false
    private var isTerminating = false
    private var captureID = UUID()
    private var recordingStartTask: Task<Void, Never>?
    private var statusItem: NSStatusItem?
    private var pendingCaptureFailure: Error?

    var selectedDisplay: DisplayChoice? { displays.first { $0.id == selectedDisplayID } }
    var canMoveCamera: Bool { screenEnabled && cameraEnabled && !isSwitchingSource && (state == .ready || state == .recording) && editor == nil }
    var canSwitchScreen: Bool {
        !isSwitchingSource && editor == nil && (state == .ready || state.isSessionActive) &&
            (!screenEnabled || cameraEnabled || state == .ready)
    }
    var selectedCameraCorner: CameraCorner? {
        CameraCorner.allCases.first { CameraPlacement.from(corner: $0) == cameraPlacement }
    }
    var geometry: RecordingGeometry {
        if let selectedDisplay { return selectedDisplay.geometry }
        let id = selectedDisplayID
        let mode = CGDisplayCopyDisplayMode(id)
        return .native(width: mode?.pixelWidth ?? CGDisplayPixelsWide(id),
                       height: mode?.pixelHeight ?? CGDisplayPixelsHigh(id))
    }
    var timeLabel: String {
        let t = Int(elapsed)
        return t >= 3600 ? String(format: "%02d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
    }
    var sizeEstimate: String {
        let mb = Double(geometry.bitRate + 192_000) * 60 / 8 / 1_000_000
        return "≈ \(Int(mb)) MB/min"
    }

    private init() {
        let fallback = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Foco", isDirectory: true)
        if let saved = UserDefaults.standard.string(forKey: "outputDirectory") {
            outputDirectory = URL(fileURLWithPath: saved, isDirectory: true)
        } else { outputDirectory = fallback }
        refreshDisplays()
        refreshRecentFiles()
    }

    func refreshDisplays() {
        displays = NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            let mode = CGDisplayCopyDisplayMode(id)
            return DisplayChoice(id: id, name: screen.localizedName,
                                 width: mode?.pixelWidth ?? CGDisplayPixelsWide(id),
                                 height: mode?.pixelHeight ?? CGDisplayPixelsHigh(id))
        }
        if !displays.contains(where: { $0.id == selectedDisplayID }), let first = displays.first { selectedDisplayID = first.id }
    }

    func beginRecording() {
        guard state == .ready, editor == nil, !isSwitchingSource else { return }
        state = .preparing
        presentation.end()
        captureID = UUID()
        let captureID = captureID
        elapsed = 0
        lastResult = nil
        note = nil
        permissionPage = nil
        pendingCaptureFailure = nil
        recordingStartTask = Task { [self] in
            defer { recordingStartTask = nil }
            do {
                // Release preview devices before the recording engine acquires them.
                await livePreview.suspend()
                try Task.checkCancellation()
                refreshDisplays()
                guard selectedDisplay != nil else { throw RecorderError.message("No se encontró una pantalla conectada.") }
                if (screenEnabled || systemAudioEnabled) && !CGPreflightScreenCaptureAccess() && !CGRequestScreenCaptureAccess() {
                    permissionPage = "Privacy_ScreenCapture"
                    throw RecorderError.message("Activa Foco en Ajustes del Sistema → Privacidad y seguridad → Grabación de pantalla y audio del sistema. Después vuelve a abrir Foco si macOS lo solicita.")
                }
                if microphoneEnabled { try await requestPermission(.audio, name: "micrófono", page: "Privacy_Microphone") }
                if cameraEnabled { try await requestPermission(.video, name: "cámara", page: "Privacy_Camera") }
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                let feed = presentation.begin()
                let recorder = CaptureEngine(
                    onPreview: { frame in feed.previews.yield(frame) },
                    onLevels: { mic, system in feed.levels.yield(AudioMeterLevels(microphone: mic, system: system)) },
                    onFailure: { [weak self] error in Task { @MainActor in
                        guard let self, self.captureID == captureID else { return }
                        await self.handleCaptureFailure(error)
                    } }
                )
                engine = recorder
                recorder.setPreviewEnabled(previewIsVisible)
                let options = RecordingOptions(displayID: selectedDisplayID, cameraEnabled: cameraEnabled,
                    microphoneEnabled: microphoneEnabled, systemAudioEnabled: systemAudioEnabled,
                    cameraCorner: cameraCorner, outputDirectory: outputDirectory, cameraPlacement: cameraPlacement,
                    screenEnabled: screenEnabled)
                _ = try await recorder.start(options: options)
                state = .recording
                if let pending = pendingCaptureFailure {
                    await handleCaptureFailure(pending)
                    return
                }
                installRecordingMenu()
                timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.updateElapsed() }
                }
                timer?.tolerance = 0.1
            } catch is CancellationError {
                presentation.end()
                state = .ready
            } catch {
                engine = nil
                presentation.end()
                state = .ready
                errorMessage = error.localizedDescription
            }
        }
    }

    func setPreviewVisible(_ visible: Bool) {
        guard previewIsVisible != visible else { return }
        previewIsVisible = visible
        engine?.setPreviewEnabled(visible)
        updateIdlePreview()
    }

    func updateIdlePreview() {
        guard previewIsVisible, state == .ready, editor == nil, !isTerminating, !isSwitchingSource else {
            livePreview.update(options: nil)
            return
        }
        livePreview.update(options: PreviewOptions(displayID: selectedDisplayID,
            cameraEnabled: cameraEnabled, cameraCorner: cameraCorner, cameraPlacement: cameraPlacement, geometry: geometry,
            screenEnabled: screenEnabled))
    }

    /// Publish the new mode only after the engine has switched its actual source.
    /// Turning the screen off always leaves a camera image, never a blank movie.
    func toggleScreen() async {
        guard canSwitchScreen else { return }
        let enabled = !screenEnabled
        isSwitchingSource = true
        defer { isSwitchingSource = false; updateIdlePreview() }
        permissionPage = nil
        do {
            if state.isSessionActive, let engine {
                if enabled && !CGPreflightScreenCaptureAccess() && !CGRequestScreenCaptureAccess() {
                    permissionPage = "Privacy_ScreenCapture"
                    throw RecorderError.message("Permite la grabación de pantalla en Ajustes del Sistema para volver a mostrarla. La cámara sigue grabando.")
                }
                try await engine.setScreenEnabled(enabled)
            } else if state == .ready {
                // One serialized preview update after both source flags change.
                if !enabled { cameraEnabled = true }
            } else { return }
            screenEnabled = enabled
        } catch { errorMessage = error.localizedDescription }
    }

    func setCameraPlacement(_ placement: CameraPlacement) {
        guard canMoveCamera, placement != cameraPlacement else { return }
        cameraPlacement = placement
        if state == .recording {
            engine?.setCameraPlacement(placement)
        } else {
            updateIdlePreview()
        }
    }

    func shutdownPreview() async {
        isTerminating = true
        await livePreview.suspend()
    }

    private func updateElapsed() {
        guard state == .recording, elapsedTask == nil, let recorder = engine else { return }
        let captureID = captureID
        elapsedTask = Task { [weak self] in
            let value = await recorder.readElapsedDuration()
            guard let self, !Task.isCancelled, self.captureID == captureID else { return }
            self.elapsedTask = nil
            guard self.state == .recording else { return }
            // The UI displays whole seconds; subsecond changes need no redraw.
            if Int(self.elapsed) != Int(value) { self.elapsed = value }
            let title = " \(self.timeLabel)"
            if self.statusItem?.button?.title != title { self.statusItem?.button?.title = title }
        }
    }

    func togglePause() {
        guard state.isSessionActive, let recorder = engine else { return }
        let shouldPause = state == .recording
        do {
            elapsed = try recorder.setPaused(shouldPause)
            state = shouldPause ? .paused : .recording
            updateRecordingMenu()
        } catch { errorMessage = error.localizedDescription }
    }

    private func requestPermission(_ media: AVMediaType, name: String, page: String) async throws {
        let status = AVCaptureDevice.authorizationStatus(for: media)
        var granted = status == .authorized
        if status == .notDetermined { granted = await AVCaptureDevice.requestAccess(for: media) }
        guard granted else {
            permissionPage = page
            throw RecorderError.message("Foco necesita acceso al \(name). Puedes activarlo en Privacidad y seguridad o desactivar esta fuente antes de grabar.")
        }
    }

    func stopRecording(showEditor: Bool = true) async {
        guard state.isSessionActive, let recorder = engine else { return }
        state = .saving
        timer?.invalidate(); timer = nil
        elapsedTask?.cancel(); elapsedTask = nil
        presentation.end()
        statusItem?.button?.title = " Guardando…"
        statusItem?.menu?.items.first(where: { $0.tag == 100 })?.isEnabled = false
        statusItem?.menu?.items.first(where: { $0.tag == 101 })?.isEnabled = false
        do {
            let result = try await recorder.stop()
            lastResult = result
            elapsed = result.duration
            note = [note, result.warning].compactMap { $0 }.joined(separator: " ")
            if note?.isEmpty == true { note = nil }
        } catch { errorMessage = error.localizedDescription }
        engine = nil
        state = .ready
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item); statusItem = nil }
        refreshRecentFiles()
        if showEditor, let result = lastResult, result.url.pathExtension.lowercased() == "mp4" {
            openEditor(for: result.url)
        }
        NSApplication.shared.requestUserAttention(.informationalRequest)
    }

    func openEditor(for url: URL) {
        guard state == .ready, !editorIsExporting else { return }
        closeEditor()
        presentation.clearPreview()
        let newEditor = VideoEditorModel(url: url)
        editor = newEditor
        editorExportObservation = newEditor.$isExporting.sink { [weak self] exporting in
            guard let self else { return }
            self.editorIsExporting = exporting
            self.protectEditorWindow(whileExporting: exporting)
        }
        editorLoadTask = Task { await newEditor.load() }
        showWindow()
    }

    private func protectEditorWindow(whileExporting exporting: Bool) {
        if exporting {
            exportProtectedWindows = NSApp.windows.filter { $0.canBecomeMain && $0.styleMask.contains(.closable) }
            for window in exportProtectedWindows { window.styleMask.remove(.closable) }
        } else {
            for window in exportProtectedWindows { window.styleMask.insert(.closable) }
            exportProtectedWindows.removeAll()
        }
    }

    func closeEditor() {
        guard !editorIsExporting else { return }
        editorLoadTask?.cancel()
        editorLoadTask = nil
        editor?.close()
        editorExportObservation = nil
        editor = nil
        refreshRecentFiles()
    }

    func chooseVideoForEditing() {
        guard state == .ready, !editorIsExporting else { return }
        let panel = NSOpenPanel()
        panel.title = "Abrir video para recortar"
        panel.prompt = "Abrir"
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputDirectory
        if panel.runModal() == .OK, let url = panel.url { openEditor(for: url) }
    }

    private func handleCaptureFailure(_ error: Error) async {
        if state.isSessionActive {
            note = "La captura se interrumpió: \(error.localizedDescription)"
            await stopRecording()
        } else if state == .preparing {
            pendingCaptureFailure = error
        }
    }

    func chooseOutputDirectory() {
        guard state == .ready else { return }
        let panel = NSOpenPanel()
        panel.title = "Dónde guardar tus grabaciones"
        panel.prompt = "Elegir carpeta"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputDirectory
        if panel.runModal() == .OK, let directory = panel.url {
            outputDirectory = directory
            UserDefaults.standard.set(directory.path, forKey: "outputDirectory")
            refreshRecentFiles()
        }
    }

    func openFolder() {
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(outputDirectory)
        } catch { errorMessage = error.localizedDescription }
    }

    func showPermissions() {
        let page = permissionPage ?? "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(page)") { NSWorkspace.shared.open(url) }
    }

    func refreshRecentFiles() {
        recentFilesTask?.cancel()
        let directory = outputDirectory
        let scan = Task.detached(priority: .utility) { () -> [URL] in
            let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
            var newest: [(url: URL, date: Date)] = []
            for file in files where ["mp4", "mov"].contains(file.pathExtension.lowercased()) {
                guard !Task.isCancelled else { return [] }
                guard let values = try? file.resourceValues(forKeys: [.creationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true else { continue }
                newest.append((file, values.creationDate ?? .distantPast))
                newest.sort { $0.date > $1.date }
                if newest.count > 3 { newest.removeLast() }
            }
            return newest.map(\.url)
        }
        recentFilesTask = Task { [weak self] in
            let files = await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel() }
            guard let self, !Task.isCancelled, self.outputDirectory == directory else { return }
            if self.recentFiles != files { self.recentFiles = files }
        }
    }

    private func installRecordingMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Foco está grabando")
        item.button?.contentTintColor = .labelColor
        item.button?.title = " 00:00"
        let menu = NSMenu()
        menu.autoenablesItems = false
        let pause = NSMenuItem(title: "Pausar", action: #selector(pauseFromMenu), keyEquivalent: "")
        pause.tag = 101; pause.target = self
        menu.addItem(pause)
        let stop = NSMenuItem(title: "Detener y guardar", action: #selector(stopFromMenu), keyEquivalent: "")
        stop.tag = 100; stop.target = self
        menu.addItem(stop)
        let show = NSMenuItem(title: "Mostrar Foco", action: #selector(showWindow), keyEquivalent: "")
        show.target = self; menu.addItem(show)
        item.menu = menu
        statusItem = item
        updateRecordingMenu()
    }

    private func updateRecordingMenu() {
        let paused = state == .paused
        statusItem?.button?.image = NSImage(systemSymbolName: paused ? "pause.circle.fill" : "record.circle.fill",
                                            accessibilityDescription: paused ? "Grabación en pausa" : "Foco está grabando")
        statusItem?.button?.contentTintColor = .labelColor
        statusItem?.button?.title = paused ? " Pausa · \(timeLabel)" : " \(timeLabel)"
        statusItem?.menu?.items.first(where: { $0.tag == 101 })?.title = paused ? "Reanudar" : "Pausar"
    }

    @objc private func stopFromMenu() { Task { await stopRecording() } }
    @objc private func pauseFromMenu() { togglePause() }
    @objc private func showWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }
}
