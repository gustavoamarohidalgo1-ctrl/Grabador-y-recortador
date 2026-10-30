import Foundation
import CoreVideo
import CoreGraphics

@main
enum CameraPlacementTest {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw RecorderError.message("TEST: \(message)") }
    }

    static func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000001 }

    static func main() throws {
        let geometry = RecordingGeometry(width: 1920, height: 1080)
        try require(CameraPlacement(x: -4, y: 8) == CameraPlacement(x: 0, y: 1), "Drag escaped the image")
        let invalid = CameraPlacement(x: .nan, y: .infinity)
        try require(invalid.x.isFinite && invalid.y.isFinite, "Invalid coordinates reached compositor")
        for corner in CameraCorner.allCases {
            let rect = CameraPlacement.from(corner: corner).rect(in: geometry)
            let isRight = corner == .topRight || corner == .bottomRight
            let isTop = corner == .topRight || corner == .topLeft
            try require(rect == CGRect(x: isRight ? 1476 : 24, y: isTop ? 24 : 741, width: 420, height: 315),
                        "Corner preset moved from the established layout")
        }
        // A Retina output gains pixels, not a smaller-looking camera overlay.
        let retina = RecordingGeometry.native(width: 3840, height: 2160)
        for corner in CameraCorner.allCases {
            let original = CameraPlacement.from(corner: corner).rect(in: geometry)
            let scaled = CameraPlacement.from(corner: corner).rect(in: retina)
            try require(close(scaled.minX / 2, original.minX) && close(scaled.minY / 2, original.minY) &&
                        close(scaled.width / 2, original.width) && close(scaled.height / 2, original.height),
                        "Native resolution changed the camera's apparent proportions")
        }
        let viewport = CGSize(width: 1000, height: 1000)
        let fit = geometry.fittedRect(in: viewport)
        try require(close(fit.minX, 0) && close(fit.minY, 218.75) && close(fit.width, 1000) && close(fit.height, 562.5),
                    "Letterbox geometry differs from preview")
        let start = CameraPlacement.from(corner: .bottomRight)
        let cameraRect = start.previewRect(in: viewport, geometry: geometry)
        let endRect = CameraPlacement.from(corner: .topLeft).previewRect(in: viewport, geometry: geometry)
        let translation = CGSize(width: endRect.minX - cameraRect.minX, height: endRect.minY - cameraRect.minY)
        let topLeft = start.translated(by: translation, in: viewport, geometry: geometry)
        try require(close(topLeft.x, 0) && close(topLeft.y, 0),
                    "Dragging through letterbox space used the wrong scale")
        let custom = CameraPlacement(x: 0.31, y: 0.62)
        let move = CGSize(width: (cameraRect.minX - endRect.minX) * 0.1,
                          height: (cameraRect.minY - endRect.minY) * -0.12)
        let moved = custom.translated(by: move, in: viewport, geometry: geometry)
        try require(close(moved.x, 0.41) && close(moved.y, 0.5), "Arbitrary placement lost drag offset")
        try require(custom.translated(by: move, in: .zero, geometry: geometry) == custom, "Empty viewport changed placement")
        let wideViewport = CGSize(width: 1200, height: 600)
        let wideFit = geometry.fittedRect(in: wideViewport)
        try require(close(wideFit.minX, 66.6666666667) && close(wideFit.minY, 0), "Horizontal letterbox was not centered")
        let wideStart = start.previewRect(in: wideViewport, geometry: geometry)
        let wideEnd = CameraPlacement.from(corner: .topLeft).previewRect(in: wideViewport, geometry: geometry)
        let wideMoved = start.translated(by: CGSize(width: wideEnd.minX - wideStart.minX,
                                                   height: wideEnd.minY - wideStart.minY),
                                         in: wideViewport, geometry: geometry)
        try require(close(wideMoved.x, 0) && close(wideMoved.y, 0), "Dragging included horizontal letterbox bars")
        for size in [(2, 2), (1920, 2), (2, 1080), (606, 1080), (1660, 1080)] {
            let bounds = RecordingGeometry(width: size.0, height: size.1)
            for placement in [CameraPlacement(x: 0, y: 0), CameraPlacement(x: 0.5, y: 0.5), CameraPlacement(x: 1, y: 1)] {
                let rect = placement.rect(in: bounds)
                try require(rect.width > 0 && rect.height > 0 && rect.minX >= 0 && rect.minY >= 0 &&
                            rect.maxX <= Double(size.0) + 0.000001 && rect.maxY <= Double(size.1) + 0.000001,
                            "Camera escaped a narrow or small source")
            }
        }

        var pool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ] as CFDictionary, &pool)
        guard poolStatus == kCVReturnSuccess, let pool else { throw RecorderError.message("Pool unavailable") }
        let screen = try pixelBuffer(width: 1920, height: 1080, red: 20, green: 35, blue: 120)
        let camera = try pixelBuffer(width: 320, height: 240, red: 220, green: 30, blue: 20)
        let compositor = FrameCompositor(geometry: geometry, corner: .topLeft)
        guard let first = compositor.frame(screen: screen, camera: camera, pool: pool) else {
            throw RecorderError.message("First frame unavailable")
        }
        let previousCenter = CameraPlacement.from(corner: .topLeft).rect(in: geometry)
        try require(rgb(first, x: Int(previousCenter.midX), y: Int(previousCenter.midY)).0 > 170, "Initial camera position incorrect")
        compositor.setCameraPlacement(CameraPlacement(x: 0.5, y: 0.5))
        guard let second = compositor.frame(screen: screen, camera: camera, pool: pool) else {
            throw RecorderError.message("Moved frame unavailable")
        }
        try require(first !== second, "Camera movement mutated a frame retained by the writer")
        try require(rgb(second, x: 960, y: 540).0 > 170, "Camera failed to move to arbitrary center")
        try require(rgb(second, x: Int(previousCenter.midX), y: Int(previousCenter.midY)).2 > 100,
                    "Old camera location was not cleared")
        try require(rgb(first, x: Int(previousCenter.midX), y: Int(previousCenter.midY)).0 > 170 &&
                    rgb(first, x: 960, y: 540).2 > 100, "Previously encoded frame changed after movement")
        compositor.setCameraPlacement(CameraPlacement(x: 0.5, y: 0.5))
        try require(compositor.frame(screen: screen, camera: camera, pool: pool) === second,
                    "An unchanged placement recomposed the frame")
        print("PASS: posiciones arbitrarias y esquinas, límites, arrastre con bandas, centro real de cámara y buffers grabados inmutables.")
    }

    static func pixelBuffer(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                  [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw RecorderError.message("Buffer unavailable") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height { for x in 0..<width {
            let i = y * row + x * 4
            bytes[i] = blue; bytes[i + 1] = green; bytes[i + 2] = red; bytes[i + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    static func rgb(_ buffer: CVPixelBuffer, x: Int, y: Int) -> (Int, Int, Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let i = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return (Int(bytes[i + 2]), Int(bytes[i + 1]), Int(bytes[i]))
    }
}
