import AppKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

struct ForegroundContext: Equatable {
    var pid: pid_t
    var bundleID: String
    var name: String
    static func current() -> ForegroundContext? {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier else { return nil }
        return ForegroundContext(pid: app.processIdentifier, bundleID: bundle, name: app.localizedName ?? "应用")
    }
}

struct MemoryScreenCapture {
    struct Frame { var jpeg: Data; var fingerprint: Data; var contextKey: String; var capturedAt: Date }
    static var allowed: Bool { CGPreflightScreenCaptureAccess() }
    static var sessionAvailable: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool != true
    }

    static func connectedDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    /// CGWindowList is ordered front to back across every display, in Quartz coordinates.
    /// No dependence on the primary display, pointer location, or an Accessibility permission.
    static func frontWindowID(in windows: [[String: Any]], pid: pid_t, displayBounds: [CGRect]) -> CGWindowID? {
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? Int) == Int(pid),
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= 100, rect.height >= 80,
                  displayBounds.contains(where: { $0.intersects(rect) }),
                  let number = window[kCGWindowNumber as String] as? UInt32 else { continue }
            return number
        }
        return nil
    }

    static func encode(_ image: CGImage) throws -> Data {
        for quality in [0.68, 0.5, 0.32] {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw AutomaticError.imageTooLarge }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination) && output.length <= 1_100_000 { return output as Data }
        }
        throw AutomaticError.imageTooLarge
    }

    static func capture(_ app: ForegroundContext) async throws -> Frame {
        guard allowed, sessionAvailable else { throw AutomaticError.permission }
        guard app.bundleID != Bundle.main.bundleIdentifier else { throw AutomaticError.noWindow }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let number = frontWindowID(in: windows, pid: app.pid, displayBounds: connectedDisplayBounds()) else { throw AutomaticError.noWindow }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == number && $0.owningApplication?.processID == app.pid }), window.frame.width >= 100, window.frame.height >= 80 else { throw AutomaticError.noWindow }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let settings = SCStreamConfiguration()
        let pixelWidth = window.frame.width * CGFloat(filter.pointPixelScale)
        let pixelHeight = window.frame.height * CGFloat(filter.pointPixelScale)
        let scale = min(1, 1600 / max(pixelWidth, pixelHeight))
        settings.width = max(1, Int(pixelWidth * scale)); settings.height = max(1, Int(pixelHeight * scale))
        settings.showsCursor = false; settings.capturesAudio = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: settings)
        try Task.checkCancellation()
        let latest = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard allowed, sessionAvailable, ForegroundContext.current() == app,
              frontWindowID(in: latest, pid: app.pid, displayBounds: connectedDisplayBounds()) == number else { throw AutomaticError.noWindow }
        return try autoreleasepool {
            let jpeg = try encode(image)
            var pixels = [UInt8](repeating: 0, count: 32 * 32)
            pixels.withUnsafeMutableBytes { buffer in
                if let context = CGContext(data: buffer.baseAddress, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) {
                    context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
                }
            }
            let key = "\(app.pid):\(number):\(window.title ?? "")"
            let contextKey = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            return Frame(jpeg: jpeg, fingerprint: Data(pixels), contextKey: contextKey, capturedAt: Date())
        }
    }
}
