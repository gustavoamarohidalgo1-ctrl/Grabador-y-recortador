import CoreVideo
import Combine
import Foundation

/// The compositor publishes immutable, IOSurface-backed buffers. Retaining the
/// reference lets the display layer use that surface without a CGImage readback.
struct PreviewVideoFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

struct AudioMeterLevels: Equatable, Sendable {
    let microphone: Int
    let system: Int
    static let silent = AudioMeterLevels(microphone: 0, system: 0)

    init(microphone: Double, system: Double) {
        func bars(_ level: Double) -> Int {
            guard level.isFinite else { return 0 }
            return Int(ceil(min(1, max(0, level)) * 4))
        }
        self.microphone = bars(microphone)
        self.system = bars(system)
    }
}

/// High-frequency presentation updates never invalidate the application model.
/// Each stream keeps only its newest value if the main thread is occupied.
@MainActor
final class CapturePresentation: ObservableObject {
    struct Feed: Sendable {
        let previews: AsyncStream<PreviewVideoFrame>.Continuation
        let levels: AsyncStream<AudioMeterLevels>.Continuation
    }

    @Published private(set) var hasPreview = false
    private(set) var preview: PreviewVideoFrame?
    let frames = PassthroughSubject<PreviewVideoFrame?, Never>()
    @Published private(set) var levels = AudioMeterLevels.silent
    private var feed: Feed?
    private var previewTask: Task<Void, Never>?
    private var levelsTask: Task<Void, Never>?

    func begin() -> Feed {
        end()
        clearPreview()
        let images = AsyncStream<PreviewVideoFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let meters = AsyncStream<AudioMeterLevels>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let feed = Feed(previews: images.continuation, levels: meters.continuation)
        self.feed = feed
        previewTask = Task { [weak self] in
            for await image in images.stream {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                // Native presentation owns high-frequency updates. SwiftUI only
                // observes availability, never a replacement image every frame.
                if self.preview?.buffer !== image.buffer {
                    self.preview = image
                    if !self.hasPreview { self.hasPreview = true }
                    self.frames.send(image)
                }
            }
        }
        levelsTask = Task { [weak self] in
            for await level in meters.stream {
                guard !Task.isCancelled else { return }
                if self?.levels != level { self?.levels = level }
            }
        }
        return feed
    }

    func end() {
        feed?.previews.finish()
        feed?.levels.finish()
        feed = nil
        previewTask?.cancel(); previewTask = nil
        levelsTask?.cancel(); levelsTask = nil
        if levels != .silent { levels = .silent }
    }

    func clearPreview() {
        preview = nil
        if hasPreview { hasPreview = false }
        frames.send(nil)
    }

    deinit {
        feed?.previews.finish()
        feed?.levels.finish()
        previewTask?.cancel()
        levelsTask?.cancel()
    }
}
