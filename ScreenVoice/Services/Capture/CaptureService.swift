import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// A captured frame. CVPixelBuffer is immutable once ScreenCaptureKit hands it over, so sharing it is safe.
struct CapturedFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let sequence: UInt64
    let timestamp: TimeInterval
}

enum CaptureError: LocalizedError {
    case permissionDenied
    case windowNotFound
    case displayNotFound
    case emptyRegion

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Нет разрешения на запись экрана. Включите ScreenVoice в «Системные настройки → Конфиденциальность и безопасность → Запись экрана и системного звука»."
        case .windowNotFound:
            "Выбранное окно больше недоступно. Выберите источник заново."
        case .displayNotFound:
            "Дисплей с выбранной областью не найден. Выделите область заново."
        case .emptyRegion:
            "Выбранная область слишком мала."
        }
    }
}

/// Wraps ScreenCaptureKit. Frames are not pushed through the pipeline; instead the newest frame is kept
/// in a slot that the recognition loop polls at its own pace. Old frames are simply overwritten, so a slow
/// OCR pass never builds up a backlog or blocks capture.
final class CaptureService: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    // All mutable state is guarded by `lock`.
    private let lock = NSLock()
    private var stream: SCStream?
    private var configuration: SCStreamConfiguration?
    private var latest: CapturedFrame?
    private var sequence: UInt64 = 0
    private var onStop: (@Sendable (Error?) -> Void)?

    private let sampleQueue = DispatchQueue(label: "ScreenVoice.Capture", qos: .userInitiated)

    // MARK: Permission

    static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Shows the system prompt the first time; afterwards macOS only lists the app in System Settings.
    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: Sources

    func availableWindows() async throws -> [WindowInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.windows
            .compactMap { window -> WindowInfo? in
                guard window.windowLayer == 0,
                      window.frame.width >= 160, window.frame.height >= 100,
                      let app = window.owningApplication,
                      app.processID != ownPID else { return nil }
                return WindowInfo(
                    id: window.windowID,
                    title: window.title ?? "",
                    appName: app.applicationName,
                    frame: window.frame
                )
            }
            .sorted { ($0.appName, $0.title) < ($1.appName, $1.title) }
    }

    // MARK: Lifecycle

    func start(
        source: CaptureSource,
        framesPerSecond: Double,
        onStop: @escaping @Sendable (Error?) -> Void
    ) async throws {
        await stop()

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            if !Self.hasPermission() { throw CaptureError.permissionDenied }
            throw error
        }

        let configuration = SCStreamConfiguration()
        let filter: SCContentFilter
        var pixelSize: CGSize

        switch source {
        case .window(let info):
            guard let window = content.windows.first(where: { $0.windowID == info.id }) else {
                throw CaptureError.windowNotFound
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            pixelSize = CGSize(width: filter.contentRect.width * scale, height: filter.contentRect.height * scale)

        case .region(let region):
            guard region.rect.width >= 8, region.rect.height >= 8 else { throw CaptureError.emptyRegion }
            guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
                throw CaptureError.displayNotFound
            }
            // Exclude our own windows (overlay, main window) so we never read back our own translation.
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let ownApps = content.applications.filter { $0.processID == ownPID }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            configuration.sourceRect = region.rect
            pixelSize = CGSize(width: region.rect.width * region.scale, height: region.rect.height * region.scale)
        }

        // Keep text crisp but bound the cost of very large captures.
        let maxDimension: CGFloat = 3840
        let largest = max(pixelSize.width, pixelSize.height)
        if largest > maxDimension {
            let factor = maxDimension / largest
            pixelSize = CGSize(width: pixelSize.width * factor, height: pixelSize.height * factor)
        }
        configuration.width = max(16, Int(pixelSize.width.rounded()))
        configuration.height = max(16, Int(pixelSize.height.rounded()))
        configuration.minimumFrameInterval = Self.frameInterval(for: framesPerSecond)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)

        lock.withLock {
            self.stream = stream
            self.configuration = configuration
            self.onStop = onStop
            self.latest = nil
        }

        do {
            try await stream.startCapture()
        } catch {
            lock.withLock {
                self.stream = nil
                self.configuration = nil
                self.onStop = nil
            }
            if !Self.hasPermission() { throw CaptureError.permissionDenied }
            throw error
        }
    }

    func stop() async {
        let stream: SCStream? = lock.withLock {
            let current = self.stream
            self.stream = nil
            self.configuration = nil
            self.onStop = nil
            self.latest = nil
            return current
        }
        guard let stream else { return }
        try? await stream.stopCapture()
    }

    func updateFrameRate(_ framesPerSecond: Double) async {
        let pair: (SCStream, SCStreamConfiguration)? = lock.withLock {
            guard let stream, let configuration else { return nil }
            configuration.minimumFrameInterval = Self.frameInterval(for: framesPerSecond)
            return (stream, configuration)
        }
        guard let (stream, configuration) = pair else { return }
        try? await stream.updateConfiguration(configuration)
    }

    /// The newest complete frame, or nil if none has arrived yet.
    func latestFrame() -> CapturedFrame? {
        lock.withLock { latest }
    }

    private static func frameInterval(for framesPerSecond: Double) -> CMTime {
        let fps = min(max(framesPerSecond, AppSettings.framesPerSecondRange.lowerBound), AppSettings.framesPerSecondRange.upperBound)
        return CMTime(seconds: 1.0 / fps, preferredTimescale: 600)
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // Only complete frames carry new pixels; idle frames mean "nothing changed".
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let timestamp = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            guard self.stream === stream else { return }
            sequence &+= 1
            latest = CapturedFrame(pixelBuffer: pixelBuffer, sequence: sequence, timestamp: timestamp)
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let handler: (@Sendable (Error?) -> Void)? = lock.withLock {
            guard self.stream === stream else { return nil }
            let handler = onStop
            self.stream = nil
            self.configuration = nil
            self.onStop = nil
            self.latest = nil
            return handler
        }
        handler?(error)
    }
}
