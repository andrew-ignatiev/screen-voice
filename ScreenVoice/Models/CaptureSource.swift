import CoreGraphics
import Foundation

struct WindowInfo: Identifiable, Equatable, Sendable {
    let id: CGWindowID
    let title: String
    let appName: String
    let frame: CGRect

    var displayName: String {
        title.isEmpty ? appName : "\(appName) — \(title)"
    }
}

/// A rectangle on one display, in that display's point coordinates with a top-left origin.
/// This is the coordinate space ScreenCaptureKit expects for `SCStreamConfiguration.sourceRect`.
struct RegionSelection: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let rect: CGRect
    let scale: CGFloat

    /// Converts a rectangle in an AppKit view that covers the whole screen (bottom-left origin)
    /// into display-local coordinates with a top-left origin.
    static func displayLocalRect(fromViewRect viewRect: CGRect, screenHeight: CGFloat) -> CGRect {
        CGRect(
            x: viewRect.minX,
            y: screenHeight - viewRect.maxY,
            width: viewRect.width,
            height: viewRect.height
        ).integral
    }
}

enum CaptureSource: Equatable, Sendable {
    case window(WindowInfo)
    case region(RegionSelection)

    var description: String {
        switch self {
        case .window(let window):
            String(localized: "Window: \(window.displayName)")
        case .region(let region):
            String(localized: "Region \(Int(region.rect.width))×\(Int(region.rect.height)) on display \(region.displayID)")
        }
    }
}
