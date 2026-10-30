import AppKit
import SwiftUI
import Combine
@preconcurrency import AVFoundation

/// The screen is already composed on the GPU. Hand the existing surface to the
/// native video renderer rather than reading it back into a CGImage at 60 Hz.
struct NativePreviewView: NSViewRepresentable {
    let presentation: CapturePresentation

    func makeNSView(context: Context) -> PreviewSurfaceView {
        let view = PreviewSurfaceView()
        view.attach(presentation)
        return view
    }

    func updateNSView(_ view: PreviewSurfaceView, context: Context) {
        view.attach(presentation)
    }

    static func dismantleNSView(_ view: PreviewSurfaceView, coordinator: ()) { view.detach() }
}

/// Caches only format metadata, never another image or CPU-sized pixel copy.
final class PreviewSampleFactory {
    private var format: CMVideoFormatDescription?

    func sample(for frame: PreviewVideoFrame) -> CMSampleBuffer? {
        if format.map({ CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: frame.buffer) }) != true {
            var created: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                    imageBuffer: frame.buffer, formatDescriptionOut: &created) == noErr else { return nil }
            format = created
        }
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                       presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                       decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                imageBuffer: frame.buffer, formatDescription: format, sampleTiming: &timing,
                sampleBufferOut: &sample) == noErr, let sample else { return nil }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return nil }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        return sample
    }

    func reset() { format = nil }
}

/// UI and renderer state is confined to the main actor. No operation here is
/// awaited by capture or file writing; backpressure retains only the newest frame.
@MainActor
final class PreviewSurfaceView: NSView {
    private let videoLayer: AVSampleBufferDisplayLayer
    private let renderer: AVSampleBufferVideoRenderer
    private let samples = PreviewSampleFactory()
    private weak var presentation: CapturePresentation?
    private var observation: AnyCancellable?
    private var windowObservers: [NSObjectProtocol] = []
    private weak var observedWindow: NSWindow?
    private var pendingFrame: PreviewVideoFrame?
    private var requestingData = false
    private var isFlushing = false
    private var generation: UInt64 = 0
    private var previewVisible = false
    private var recoveryAttempts = 0

    override init(frame frameRect: NSRect) {
        let videoLayer = AVSampleBufferDisplayLayer()
        self.videoLayer = videoLayer
        renderer = videoLayer.sampleBufferRenderer
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.videoGravity = .resizeAspect
        videoLayer.isHidden = true
        layer?.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        renderer.stopRequestingMediaData()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func attach(_ presentation: CapturePresentation) {
        if self.presentation !== presentation || observation == nil {
            observation?.cancel()
            self.presentation = presentation
            observation = presentation.frames.sink { [weak self] frame in
                self?.receive(frame)
            }
            receive(presentation.preview)
        }
        observeWindow()
        updateBackingGeometry()
        // SwiftUI may call update before orderFront has made the window visible.
        DispatchQueue.main.async { [weak self] in self?.refreshVisibility() }
    }

    func detach() {
        observation?.cancel(); observation = nil
        presentation = nil
        removeWindowObservers()
        previewVisible = false
        resetDisplay()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindow()
        updateBackingGeometry()
        DispatchQueue.main.async { [weak self] in self?.refreshVisibility() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateBackingGeometry()
    }

    override func layout() {
        super.layout()
        updateBackingGeometry()
        refreshVisibility()
    }

    /// AppKit updates its backing layer's scale, but this video sublayer is
    /// owned here. Keep it in physical Retina pixels, including screen moves.
    private func updateBackingGeometry() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        guard videoLayer.frame != bounds || videoLayer.contentsScale != scale else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        videoLayer.contentsScale = scale
        CATransaction.commit()
    }

    private func observeWindow() {
        guard let window else { removeWindowObservers(); return }
        guard observedWindow !== window || windowObservers.isEmpty else { return }
        removeWindowObservers()
        observedWindow = window
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didBecomeMainNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    if note.name == NSWindow.willCloseNotification {
                        self?.previewVisible = false
                        self?.resetDisplay()
                    } else { self?.refreshVisibility() }
                }
            })
        }
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                     NSApplication.didBecomeActiveNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVisibility() }
            })
        }
    }

    private func removeWindowObservers() {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        observedWindow = nil
    }

    private func refreshVisibility() {
        let visible = window.map {
            !NSApp.isHidden && $0.isVisible && !$0.isMiniaturized && !isHiddenOrHasHiddenAncestor &&
                ($0.isKeyWindow || $0.occlusionState.contains(.visible)) && bounds.width > 0 && bounds.height > 0
        } ?? false
        guard previewVisible != visible else { return }
        previewVisible = visible
        if visible { receive(presentation?.preview) }
        else { resetDisplay() }
    }

    private func receive(_ frame: PreviewVideoFrame?) {
        guard let frame else { resetDisplay(); return }
        guard previewVisible else { return }
        pendingFrame = frame
        displayPendingFrame()
    }

    private func displayPendingFrame() {
        guard previewVisible, !isFlushing, let frame = pendingFrame else { return }
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            // Recovery must not loop if the renderer remains failed after a
            // flush. Reconnecting the view or a new capture resets the budget.
            guard recoveryAttempts < 2 else { pendingFrame = nil; return }
            recoveryAttempts += 1
            flushRenderer()
            return
        }
        guard renderer.isReadyForMoreMediaData else {
            requestWhenReady()
            return
        }
        stopRequesting()
        pendingFrame = nil
        guard let sample = samples.sample(for: frame) else { return }
        renderer.enqueue(sample)
        videoLayer.isHidden = false
    }

    private func requestWhenReady() {
        guard !requestingData else { return }
        requestingData = true
        let generation = generation
        renderer.requestMediaDataWhenReady(on: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                self.stopRequesting()
                self.displayPendingFrame()
            }
        }
    }

    private func stopRequesting() {
        guard requestingData else { return }
        requestingData = false
        renderer.stopRequestingMediaData()
    }

    private func resetDisplay() {
        generation &+= 1
        pendingFrame = nil
        recoveryAttempts = 0
        samples.reset()
        videoLayer.isHidden = true
        flushRenderer()
    }

    private func flushRenderer() {
        stopRequesting()
        guard !isFlushing else { return }
        isFlushing = true
        renderer.flush(removingDisplayedImage: true) { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isFlushing = false
                self.displayPendingFrame()
            }
        }
    }
}
