import CoreMedia

/// Maps the capture host clock onto a movie timeline with all paused spans removed.
/// The history is retained so delayed media samples can be classified correctly.
struct RecordingTimeline {
    private struct Pause {
        let start: CMTime
        let end: CMTime
    }

    let origin: CMTime
    private var pauses: [Pause] = []
    private var pauseStart: CMTime?
    private var latestTransition: CMTime

    init(origin: CMTime) {
        self.origin = origin
        latestTransition = origin
    }

    var isPaused: Bool { pauseStart != nil }

    mutating func pause(at hostTime: CMTime) {
        guard !isPaused, hostTime.isNumeric, CMTimeCompare(hostTime, latestTransition) >= 0 else { return }
        pauseStart = hostTime
        latestTransition = hostTime
    }

    mutating func resume(at hostTime: CMTime) {
        guard let start = pauseStart, hostTime.isNumeric, CMTimeCompare(hostTime, start) >= 0 else { return }
        pauses.append(Pause(start: start, end: hostTime))
        pauseStart = nil
        latestTransition = hostTime
    }

    /// Unlike presentationTime, elapsed freezes at the beginning of a pause.
    func elapsed(at hostTime: CMTime) -> CMTime {
        guard hostTime.isNumeric, CMTimeCompare(hostTime, origin) >= 0 else { return .zero }
        var elapsed = CMTimeSubtract(hostTime, origin)
        for pause in pauses {
            guard CMTimeCompare(hostTime, pause.start) >= 0 else { break }
            let end = CMTimeCompare(hostTime, pause.end) < 0 ? hostTime : pause.end
            elapsed = CMTimeSubtract(elapsed, CMTimeSubtract(end, pause.start))
        }
        if let start = pauseStart, CMTimeCompare(hostTime, start) >= 0 {
            elapsed = CMTimeSubtract(elapsed, CMTimeSubtract(hostTime, start))
        }
        return CMTimeCompare(elapsed, .zero) < 0 ? .zero : elapsed
    }

    /// The start of a pause is excluded; the instant of resumption is included.
    func presentationTime(for hostTime: CMTime) -> CMTime? {
        guard hostTime.isNumeric, CMTimeCompare(hostTime, origin) >= 0 else { return nil }
        if let start = pauseStart, CMTimeCompare(hostTime, start) >= 0 { return nil }
        for pause in pauses {
            if CMTimeCompare(hostTime, pause.start) >= 0 && CMTimeCompare(hostTime, pause.end) < 0 { return nil }
        }
        return elapsed(at: hostTime)
    }
}
