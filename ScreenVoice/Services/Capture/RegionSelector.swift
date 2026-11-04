import AppKit

/// Shows a dimmed full-screen layer on every display and lets the user drag a rectangle.
/// Returns the rectangle in display-local coordinates, or nil if the user pressed Esc.
@MainActor
final class RegionSelector {
    private var windows: [NSWindow] = []
    private var continuation: CheckedContinuation<RegionSelection?, Never>?

    func selectRegion() async -> RegionSelection? {
        finish(nil)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            for screen in NSScreen.screens {
                guard let displayID = screen.displayID else { continue }
                let window = makeWindow(for: screen, displayID: displayID)
                windows.append(window)
                window.orderFrontRegardless()
            }
            NSApp.activate()
            if let first = windows.first {
                first.makeKey()
                first.makeFirstResponder(first.contentView)
            }
            if windows.isEmpty { finish(nil) }
        }
    }

    private func makeWindow(for screen: NSScreen, displayID: CGDirectDisplayID) -> NSWindow {
        let window = SelectionWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.setFrame(screen.frame, display: false)

        let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
        let screenHeight = screen.frame.height
        let scale = screen.backingScaleFactor
        view.onComplete = { [weak self] rect in
            guard let rect else {
                self?.finish(nil)
                return
            }
            let local = RegionSelection.displayLocalRect(fromViewRect: rect, screenHeight: screenHeight)
            self?.finish(RegionSelection(displayID: displayID, rect: local, scale: scale))
        }
        window.contentView = view
        return window
    }

    private func finish(_ result: RegionSelection?) {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    var onComplete: ((CGRect?) -> Void)?

    private var startPoint: CGPoint?
    private var currentRect: CGRect?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        currentRect = CGRect(
            x: min(startPoint.x, point.x),
            y: min(startPoint.y, point.y),
            width: abs(point.x - startPoint.x),
            height: abs(point.y - startPoint.y)
        ).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { startPoint = nil }
        guard let rect = currentRect, rect.width >= 24, rect.height >= 12 else {
            currentRect = nil
            needsDisplay = true
            return
        }
        onComplete?(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onComplete?(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        if let rect = currentRect {
            NSColor.clear.setFill()
            rect.fill(using: .copy)
            NSColor.systemBlue.setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
            path.lineWidth = 2
            path.stroke()

            let size = "\(Int(rect.width)) × \(Int(rect.height))" as NSString
            size.draw(at: CGPoint(x: rect.minX + 4, y: rect.maxY + 6), withAttributes: Self.labelAttributes)
        }

        let hint = String(localized: "Drag to select the subtitle area. Press Esc to cancel.") as NSString
        let hintSize = hint.size(withAttributes: Self.hintAttributes)
        hint.draw(
            at: CGPoint(x: bounds.midX - hintSize.width / 2, y: bounds.maxY - hintSize.height - 80),
            withAttributes: Self.hintAttributes
        )
    }

    private static let hintAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
        .foregroundColor: NSColor.white,
    ]

    private static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.white,
    ]
}
