import AppKit
import SwiftUI

/// Rendering a preview is useful only while the capture window can be seen.
struct PreviewVisibilityObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.onChange = onChange
        view.attachOrRefresh()
    }
    static func dismantleNSView(_ view: VisibilityView, coordinator: ()) { view.detach() }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private weak var observedWindow: NSWindow?
        private var lastVisibility: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachOrRefresh()
        }

        func attachOrRefresh() {
            guard let window else {
                removeObservers()
                scheduleRefresh()
                return
            }
            guard observedWindow !== window || observers.isEmpty else {
                scheduleRefresh()
                return
            }
            removeObservers()
            observedWindow = window
            lastVisibility = nil
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                         NSWindow.didBecomeMainNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] notification in
                    MainActor.assumeIsolated {
                        if notification.name == NSWindow.willCloseNotification { self?.report(false) }
                        else { self?.refresh() }
                    }
                })
            }
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                         NSApplication.didBecomeActiveNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
            }
            // Avoid publishing state synchronously during SwiftUI's view update.
            scheduleRefresh()
        }

        func scheduleRefresh() {
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }

        private func refresh() {
            guard let window else { report(false); return }
            // A restored window can become key before AppKit sends the first
            // occlusion update. Focus is also evidence that its preview is visible.
            report(!NSApp.isHidden && window.isVisible && !window.isMiniaturized &&
                   (window.isKeyWindow || window.occlusionState.contains(.visible)))
        }

        private func report(_ visible: Bool) {
            guard let onChange, lastVisibility != visible else { return }
            lastVisibility = visible
            onChange(visible)
        }

        private func removeObservers() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            observedWindow = nil
        }

        func detach() { removeObservers(); report(false); onChange = nil; lastVisibility = nil }
    }
}
