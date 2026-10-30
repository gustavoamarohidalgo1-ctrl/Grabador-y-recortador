import AppKit
@preconcurrency import AVFoundation
import Combine
import UniformTypeIdentifiers

@MainActor
final class VideoEditorModel: ObservableObject {
    let sourceURL: URL
    let player: AVPlayer
    @Published private(set) var isLoading = true
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double = 0
    @Published private(set) var startTime: Double = 0
    @Published private(set) var endTime: Double = 0
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var frameRate: Double = 60
    @Published private(set) var qualityLabel = ""
    @Published private(set) var thumbnails: [CGImage] = []
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress: Double = 0
    @Published private(set) var exportedURL: URL?
    @Published var errorMessage: String?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var thumbnailTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var generator: AVAssetImageGenerator?
    private var seekToken = 0
    private var seekInProgress = false
    private var pendingSeek: (time: Double, playWhenReady: Bool)?
    private var isClosed = false
    private var didLoad = false
    private var sourceDuration = CMTime.zero

    init(url: URL, player: AVPlayer = AVPlayer()) {
        sourceURL = url
        self.player = player
        player.actionAtItemEnd = .pause
    }

    var frameDuration: Double { 1 / max(1, frameRate) }
    var selectedDuration: Double { max(0, endTime - startTime) }
    var canExport: Bool { !isLoading && !isExporting && duration > 0 && selectedDuration > 0 && !isClosed }

    func load() async {
        guard !didLoad, !isClosed else { return }
        didLoad = true
        do {
            let asset = AVURLAsset(url: sourceURL)
            let time = try await asset.load(.duration)
            let playable = try await asset.load(.isPlayable)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard playable, let video = tracks.first, time.isNumeric, time.seconds > 0 else {
                throw RecorderError.message("No se pudo abrir este video para editarlo. Tu archivo original está guardado.")
            }
            let size = try await video.load(.naturalSize)
            let transform = try await video.load(.preferredTransform)
            let fps = try await video.load(.nominalFrameRate)
            guard !isClosed else { return }
            duration = time.seconds
            sourceDuration = time
            endTime = duration
            frameRate = fps > 0 ? Double(fps) : Double(RecordingQuality.framesPerSecond)
            let transformed = CGSize(width: abs(size.width * transform.a + size.height * transform.c),
                                     height: abs(size.width * transform.b + size.height * transform.d))
            qualityLabel = "\(Int(transformed.width.rounded())) × \(Int(transformed.height.rounded())) · \(Int(frameRate.rounded())) fps"
            let item = AVPlayerItem(asset: asset)
            item.forwardPlaybackEndTime = mediaTime(endTime)
            item.reversePlaybackEndTime = .zero
            player.replaceCurrentItem(with: item)
            installObservers(item: item)
            isLoading = false
            seek(to: 0)
            loadThumbnails(asset: asset)
        } catch {
            guard !isClosed else { return }
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    func setStart(_ value: Double) {
        guard canChangeRange, value.isFinite else { return }
        let next = min(max(0, snapped(value)), max(0, endTime - minimumRange))
        guard next != startTime else {
            if isPlaying { seek(to: startTime) }
            return
        }
        startTime = next
        updatePlaybackRange()
        seek(to: startTime)
    }

    func setEnd(_ value: Double) {
        guard canChangeRange, value.isFinite else { return }
        let next = max(min(duration, snapped(value)), min(duration, startTime + minimumRange))
        guard next != endTime else {
            if isPlaying { seek(to: max(startTime, endTime - frameDuration)) }
            return
        }
        endTime = next
        updatePlaybackRange()
        seek(to: max(startTime, endTime - frameDuration))
    }

    func seek(to requestedTime: Double, playWhenReady: Bool = false) {
        guard !isLoading, !isExporting, !isClosed, duration > 0, requestedTime.isFinite else { return }
        player.pause()
        if isPlaying { isPlaying = false }
        let target = min(max(startTime, requestedTime), max(startTime, endTime - frameDuration))
        if currentTime != target { currentTime = target }
        // Keep the most recent drag position while AVPlayer decodes one exact
        // frame. Cancelling on every pointer event starves frame presentation.
        pendingSeek = (target, playWhenReady)
        performPendingSeek()
    }

    private func performPendingSeek() {
        guard !seekInProgress, !isClosed, let request = pendingSeek else { return }
        pendingSeek = nil
        seekInProgress = true
        seekToken += 1
        let token = seekToken
        player.seek(to: mediaTime(request.time), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, !self.isClosed, token == self.seekToken else { return }
                self.seekInProgress = false
                if self.pendingSeek != nil {
                    self.performPendingSeek()
                } else if finished && request.playWhenReady && !self.isExporting {
                    self.player.play()
                    self.isPlaying = true
                }
            }
        }
    }

    func togglePlayback() {
        guard canChangeRange else { return }
        if isPlaying { pausePlayback() }
        else {
            let position = player.currentTime().seconds
            let target = !position.isFinite || position < startTime || position >= endTime - frameDuration / 2 ? startTime : position
            seek(to: target, playWhenReady: true)
        }
    }

    func pausePlayback() {
        player.pause()
        seekToken += 1
        pendingSeek = nil
        seekInProgress = false
        player.currentItem?.cancelPendingSeeks()
        if isPlaying { isPlaying = false }
    }

    func chooseExport() {
        guard canExport else { return }
        pausePlayback()
        let panel = NSSavePanel()
        panel.title = "Exportar recorte"
        panel.prompt = "Exportar"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.directoryURL = sourceURL.deletingLastPathComponent()
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + "-recortado.mp4"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard sourceURL.resolvingSymlinksInPath().standardizedFileURL != destination.resolvingSymlinksInPath().standardizedFileURL else {
            errorMessage = "Elige otro nombre para conservar tu grabación original."
            return
        }
        exportedURL = nil
        exportProgress = 0
        isExporting = true
        let start = CMTimeMinimum(mediaTime(startTime), sourceDuration)
        let end = CMTimeMinimum(mediaTime(endTime), sourceDuration)
        let range = CMTimeRange(start: start, end: end)
        exportTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await VideoTrimmer.export(source: self.sourceURL, destination: destination, range: range, overwrite: true) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.isExporting, !self.isClosed else { return }
                        self.exportProgress = min(1, max(0, progress))
                    }
                }
                guard !self.isClosed else { return }
                self.exportedURL = destination
                self.exportProgress = 1
            } catch is CancellationError {
                // Cancelling keeps the original and leaves the selected trim intact.
            } catch {
                if !Task.isCancelled && !self.isClosed { self.errorMessage = error.localizedDescription }
            }
            self.isExporting = false
            self.exportTask = nil
        }
    }

    func cancelExport() { exportTask?.cancel() }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        exportTask?.cancel()
        thumbnailTask?.cancel()
        generator?.cancelAllCGImageGeneration()
        generator = nil
        thumbnailTask = nil
        thumbnails.removeAll()
        pausePlayback()
        if let token = timeObserver { player.removeTimeObserver(token); timeObserver = nil }
        if let token = endObserver { NotificationCenter.default.removeObserver(token); endObserver = nil }
        if let token = failureObserver { NotificationCenter.default.removeObserver(token); failureObserver = nil }
        player.replaceCurrentItem(with: nil)
    }

    static func timeLabel(_ seconds: Double) -> String {
        let millis = max(0, Int((seconds.isFinite ? seconds : 0) * 1000))
        let hours = millis / 3_600_000
        let minutes = millis / 60_000 % 60
        let sec = millis / 1000 % 60
        let fraction = millis % 1000
        return hours > 0 ? String(format: "%d:%02d:%02d.%03d", hours, minutes, sec, fraction)
                        : String(format: "%02d:%02d.%03d", minutes, sec, fraction)
    }

    private var canChangeRange: Bool { !isLoading && !isExporting && !isClosed && duration > 0 }
    private var minimumRange: Double { min(frameDuration, duration) }
    private func mediaTime(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 60_000) }
    private func snapped(_ value: Double) -> Double { (value * frameRate).rounded() / frameRate }

    private func updatePlaybackRange() {
        player.currentItem?.reversePlaybackEndTime = mediaTime(startTime)
        player.currentItem?.forwardPlaybackEndTime = mediaTime(endTime)
    }

    private func installObservers(item: AVPlayerItem) {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, !self.isClosed, time.isNumeric, self.isPlaying else { return }
                self.currentTime = min(self.endTime, max(self.startTime, time.seconds))
                if time.seconds >= self.endTime { self.pausePlayback() }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isClosed else { return }
                self.isPlaying = false
                self.currentTime = self.endTime
            }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] notification in
            let message = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            Task { @MainActor in
                guard let self, !self.isClosed else { return }
                self.pausePlayback()
                self.errorMessage = message ?? "No se pudo reproducir el video. El archivo original se conserva."
            }
        }
    }

    private func loadThumbnails(asset: AVAsset) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 180, height: 100)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        self.generator = generator
        let duration = self.duration
        thumbnailTask = Task { [weak self] in
            // The small images are retained for the timeline; release the
            // generator's decoder/cache after the final thumbnail.
            defer {
                self?.generator = nil
                self?.thumbnailTask = nil
            }
            var images: [CGImage] = []
            images.reserveCapacity(12)
            for index in 0..<12 {
                guard !Task.isCancelled else { return }
                let second = max(0, min(duration - 0.001, duration * (Double(index) + 0.5) / 12))
                do {
                    let result = try await generator.image(at: CMTime(seconds: second, preferredTimescale: 60_000))
                    guard let self, !self.isClosed, !Task.isCancelled else { return }
                    images.append(result.image)
                    if images.count.isMultiple(of: 3) { self.thumbnails = images }
                } catch {
                    if Task.isCancelled { return }
                }
            }
            guard let self, !self.isClosed, !Task.isCancelled else { return }
            if self.thumbnails.count != images.count { self.thumbnails = images }
        }
    }
}
