import AppKit
@preconcurrency import AVFoundation
import Combine
import CoreGraphics

enum LivePreviewState: Equatable {
    case idle, starting, live, needsPermission, failed
}

/// Injected by the lifecycle tests; automatic preview only checks permissions.
/// Requests are made exclusively by the explicit activation action.
@MainActor
struct PreviewPermissionAccess {
    var screenAllowed: () -> Bool
    var cameraStatus: () -> AVAuthorizationStatus
    var requestScreen: () -> Bool
    var requestCamera: () async -> Bool
    var openSettings: (String) -> Void

    static var system: Self {
        Self(screenAllowed: { CGPreflightScreenCaptureAccess() },
             cameraStatus: { AVCaptureDevice.authorizationStatus(for: .video) },
             requestScreen: { CGRequestScreenCaptureAccess() },
             requestCamera: { await AVCaptureDevice.requestAccess(for: .video) },
             openSettings: { page in
                 if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(page)") {
                     NSWorkspace.shared.open(url)
                 }
             })
    }
}

/// Serializes preview startup, configuration changes and teardown. Recording
/// awaits suspend() before acquiring devices or taking over presentation feeds.
@MainActor
final class LivePreviewController: ObservableObject {
    typealias EngineFactory = (@escaping @Sendable (PreviewVideoFrame) -> Void,
                              @escaping @Sendable (Error) -> Void) -> any PreviewCapturing

    @Published private(set) var state: LivePreviewState = .idle
    @Published private(set) var message: String?
    @Published private(set) var permissionPage: String?
    private let presentation: CapturePresentation
    private let makeEngine: EngineFactory
    private let permissions: PreviewPermissionAccess
    private var desiredOptions: PreviewOptions?
    private var activeOptions: PreviewOptions?
    private var activeEngine: (any PreviewCapturing)?
    private var activeSession: UUID?
    private var pendingFailure: Error?
    private var ownsPresentation = false
    private var worker: Task<Void, Never>?
    private var requestRevision: UInt64 = 0
    private var failedRevision: UInt64?
    private var suspensionCount = 0
    private var requestingAccess = false

    init(presentation: CapturePresentation,
         permissions: PreviewPermissionAccess? = nil,
         makeEngine: EngineFactory? = nil) {
        self.presentation = presentation
        self.permissions = permissions ?? .system
        self.makeEngine = makeEngine ?? { onFrame, onFailure in
            PreviewEngine(onFrame: onFrame, onFailure: onFailure)
        }
    }

    var actionTitle: String {
        state == .failed ? "Reintentar vista previa" : "Activar vista previa"
    }

    func update(options: PreviewOptions?) {
        desiredOptions = suspensionCount == 0 ? options : nil
        requestRevision &+= 1
        scheduleWorker()
    }

    func suspend() async {
        suspensionCount += 1
        desiredOptions = nil
        requestRevision &+= 1
        scheduleWorker()
        while let pending = worker { await pending.value }
        suspensionCount -= 1
    }

    func activate() async {
        guard !requestingAccess, suspensionCount == 0, let options = desiredOptions else { return }
        requestingAccess = true
        defer { requestingAccess = false }
        if options.screenEnabled, !permissions.screenAllowed(), !permissions.requestScreen() {
            permissions.openSettings("Privacy_ScreenCapture")
            update(options: desiredOptions)
            return
        }
        if options.cameraEnabled, permissions.cameraStatus() != .authorized {
            let status = permissions.cameraStatus()
            let granted = status == .notDetermined ? await permissions.requestCamera() : false
            if !granted {
                permissions.openSettings("Privacy_Camera")
                update(options: desiredOptions)
                return
            }
        }
        update(options: desiredOptions)
    }

    private func scheduleWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while true {
                let revision = self.requestRevision
                await self.reconcile()
                // An update can arrive as reconcile's async return is resumed.
                // Keep the same worker until no unprocessed request remains.
                if revision == self.requestRevision {
                    self.worker = nil
                    return
                }
            }
        }
    }

    private func reconcile() async {
        while true {
            if let failure = pendingFailure {
                pendingFailure = nil
                let failedOptions = activeOptions
                await stopActivePreview()
                if desiredOptions == failedOptions, desiredOptions != nil {
                    failedRevision = requestRevision
                    setState(.failed, message: failure.localizedDescription)
                    return
                }
                continue
            }

            if activeEngine != nil, activeOptions != desiredOptions {
                if let current = activeOptions, let desired = desiredOptions,
                   current.displayID == desired.displayID, current.cameraEnabled == desired.cameraEnabled,
                   current.geometry == desired.geometry, current.screenEnabled == desired.screenEnabled {
                    activeEngine?.setCameraPlacement(desired.cameraPlacement ?? .from(corner: desired.cameraCorner))
                    activeOptions = desired
                    continue
                }
                await stopActivePreview()
                continue
            }
            guard let options = desiredOptions else {
                setState(.idle)
                return
            }
            if activeEngine != nil { return }
            if failedRevision == requestRevision { return }
            guard !options.screenEnabled || permissions.screenAllowed() else {
                setState(.needsPermission,
                         message: "Permite el acceso a la pantalla para activar la vista previa.",
                         permissionPage: "Privacy_ScreenCapture")
                return
            }
            guard !options.cameraEnabled || permissions.cameraStatus() == .authorized else {
                setState(.needsPermission,
                         message: "Permite el acceso a la cámara o desactívala para previsualizar la pantalla.",
                         permissionPage: "Privacy_Camera")
                return
            }

            setState(.starting)
            let session = UUID()
            let feed = presentation.begin()
            let firstFrame = PreviewFirstFrame()
            ownsPresentation = true
            activeSession = session
            activeOptions = options
            let engine = makeEngine({ [weak self] image in
                feed.previews.yield(image)
                guard firstFrame.take() else { return }
                Task { @MainActor in
                    guard let self, self.activeSession == session, self.state == .starting else { return }
                    self.setState(.live)
                }
            }, { [weak self] error in
                Task { @MainActor in
                    guard let self, self.activeSession == session else { return }
                    self.pendingFailure = error
                    self.requestRevision &+= 1
                    self.scheduleWorker()
                }
            })
            activeEngine = engine
            do {
                try await engine.start(options: options)
            } catch {
                await stopActivePreview()
                if desiredOptions == options {
                    failedRevision = requestRevision
                    setState(.failed, message: error.localizedDescription)
                    return
                }
                continue
            }
            // Requests made while start() awaited win. Finish releasing those
            // devices before opening a replacement or beginning a recording.
            if desiredOptions != options || pendingFailure != nil { continue }
            return
        }
    }

    private func stopActivePreview() async {
        let engine = activeEngine
        activeEngine = nil
        activeOptions = nil
        activeSession = nil
        pendingFailure = nil
        if ownsPresentation {
            ownsPresentation = false
            presentation.end()
            presentation.clearPreview()
        }
        await engine?.stop()
    }

    private func setState(_ value: LivePreviewState, message: String? = nil, permissionPage: String? = nil) {
        if state != value { state = value }
        if self.message != message { self.message = message }
        if self.permissionPage != permissionPage { self.permissionPage = permissionPage }
    }
}

/// Only the first image needs a separate state transition on the main actor.
/// Subsequent images use the bounded presentation stream directly.
private final class PreviewFirstFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var received = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !received else { return false }
        received = true
        return true
    }
}
