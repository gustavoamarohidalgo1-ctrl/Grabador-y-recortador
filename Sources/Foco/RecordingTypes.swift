import Foundation
import CoreGraphics
import CoreMedia
import AVFoundation
import VideoToolbox

enum CameraCorner: String, CaseIterable, Identifiable, Sendable {
    case bottomRight, bottomLeft, topRight, topLeft
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bottomRight: return "Abajo a la derecha"
        case .bottomLeft: return "Abajo a la izquierda"
        case .topRight: return "Arriba a la derecha"
        case .topLeft: return "Arriba a la izquierda"
        }
    }
}

/// Normalized position within the available camera travel, with a top-left
/// origin. The same geometry drives mouse hit testing and the encoded video.
struct CameraPlacement: Equatable, Sendable {
    let x: Double
    let y: Double

    init(x: Double, y: Double) {
        self.x = x.isFinite ? min(1, max(0, x)) : 0.5
        self.y = y.isFinite ? min(1, max(0, y)) : 0.5
    }

    static func from(corner: CameraCorner) -> CameraPlacement {
        CameraPlacement(x: corner == .bottomRight || corner == .topRight ? 1 : 0,
                        y: corner == .bottomRight || corner == .bottomLeft ? 1 : 0)
    }

    func rect(in geometry: RecordingGeometry) -> CGRect {
        let dimensions = Self.dimensions(in: geometry)
        let travelX = max(0, Double(geometry.width) - dimensions.width - dimensions.margin * 2)
        let travelY = max(0, Double(geometry.height) - dimensions.height - dimensions.margin * 2)
        return CGRect(x: dimensions.margin + x * travelX, y: dimensions.margin + y * travelY,
                      width: dimensions.width, height: dimensions.height)
    }

    func previewRect(in viewport: CGSize, geometry: RecordingGeometry) -> CGRect {
        let video = geometry.fittedRect(in: viewport)
        guard !video.isEmpty else { return .zero }
        let scale = video.width / CGFloat(geometry.width)
        let source = rect(in: geometry)
        return CGRect(x: video.minX + source.minX * scale, y: video.minY + source.minY * scale,
                      width: source.width * scale, height: source.height * scale)
    }

    /// Apply a drag's total translation to the placement at mouse-down. The
    /// letterbox bars do not contribute to the usable movement range.
    func translated(by translation: CGSize, in viewport: CGSize, geometry: RecordingGeometry) -> CameraPlacement {
        guard translation.width.isFinite, translation.height.isFinite else { return self }
        let video = geometry.fittedRect(in: viewport)
        guard !video.isEmpty else { return self }
        let dimensions = Self.dimensions(in: geometry)
        let scale = Double(video.width) / Double(geometry.width)
        let travelX = max(0, Double(geometry.width) - dimensions.width - dimensions.margin * 2) * scale
        let travelY = max(0, Double(geometry.height) - dimensions.height - dimensions.margin * 2) * scale
        return CameraPlacement(x: travelX > 0 ? x + Double(translation.width) / travelX : x,
                               y: travelY > 0 ? y + Double(translation.height) / travelY : y)
    }

    private static func dimensions(in geometry: RecordingGeometry) -> (width: Double, height: Double, margin: Double) {
        let w = Double(max(2, geometry.width)), h = Double(max(2, geometry.height))
        // The final term keeps unusually small/wide sources valid too.
        let unit = geometry.overlayScale
        let margin = min(24.0 * unit, w * 0.035, min(w, h) * 0.035)
        let width = min(max(200.0 * unit, w * 0.22), 420.0 * unit, w - margin * 2, (h - margin * 2) * 4 / 3)
        return (width, width * 0.75, margin)
    }
}

struct RecordingOptions: Sendable {
    var displayID: CGDirectDisplayID
    var cameraEnabled: Bool
    var microphoneEnabled: Bool
    var systemAudioEnabled: Bool
    var cameraCorner: CameraCorner
    var outputDirectory: URL
    var cameraPlacement: CameraPlacement? = nil
    var screenEnabled: Bool = true
}

enum RecordingQuality {
    static let framesPerSecond: Int32 = 60
    static var frameDuration: CMTime { CMTime(value: 1, timescale: framesPerSecond) }
    static var frameIntervalNanoseconds: Int { Int((1_000_000_000.0 / Double(framesPerSecond)).rounded()) }
}

struct RecordingGeometry: Equatable, Sendable {
    let width: Int
    let height: Int
    var size: CGSize { CGSize(width: width, height: height) }
    // Preserve the camera's apparent size when the video gains Retina pixels.
    var overlayScale: Double { max(1, Double(width) / 1920, Double(height) / 1080) }
    var bitRate: Int { max(3_000_000, Int(8_000_000 * Double(width) * Double(height) / (1920 * 1080))) }

    /// Shared by production and the native-size encode/decode verification.
    /// Pixel density determines the bitrate; native dimensions are never reduced.
    var videoSettings: [String: Any] {
        [AVVideoCodecKey: AVVideoCodecType.h264,
         AVVideoWidthKey: width, AVVideoHeightKey: height,
         AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true],
         AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: bitRate,
            AVVideoExpectedSourceFrameRateKey: Int(RecordingQuality.framesPerSecond),
            AVVideoMaxKeyFrameIntervalKey: Int(RecordingQuality.framesPerSecond) * 2,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoAllowFrameReorderingKey: false
         ],
         AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
         ]]
    }
    func fittedRect(in viewport: CGSize) -> CGRect {
        guard viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0, width > 0, height > 0 else { return .zero }
        let scale = min(viewport.width / CGFloat(width), viewport.height / CGFloat(height))
        let fitted = CGSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
        return CGRect(x: (viewport.width - fitted.width) / 2, y: (viewport.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }
    static func native(width: Int, height: Int) -> RecordingGeometry {
        // H.264 4:2:0 needs even dimensions. Ordinary display modes already are
        // even; unusual odd modes lose at most the final row/column, never scale.
        RecordingGeometry(width: max(2, width / 2 * 2), height: max(2, height / 2 * 2))
    }
}

struct RecordingResult: Sendable {
    let url: URL
    let duration: TimeInterval
    let geometry: RecordingGeometry
    let bytes: Int64
    let warning: String?
}

enum RecorderError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}
