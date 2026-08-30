import AppKit
import AVFoundation

/// The live mirror surface: backed directly by an AVSampleBufferDisplayLayer,
/// forwards mouse/keyboard to the InputController, and draws tap ripples.
final class MirrorVideoView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    var inputController: InputController?
    /// Coded video size in pixels (drives aspect-fit math).
    var videoSize: CGSize = .zero
    /// Device screen size in points (from WDA); nil until control connects.
    var deviceScreenSize: CGSize?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.cornerRadius = 20
        displayLayer.cornerCurve = .continuous
        displayLayer.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // mouseMoved only arrives with a tracking area; needed so the phone's
        // pointer follows the mouse without a button held down.
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func makeBackingLayer() -> CALayer { displayLayer }
    override var isFlipped: Bool { true } // top-left origin, matches device coords
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Coordinate mapping

    /// Rect the aspect-fit video actually occupies inside the view.
    private var videoRect: CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return bounds }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2,
                      y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    func devicePoint(for viewPoint: CGPoint) -> CGPoint? {
        guard let screen = deviceScreenSize else { return nil }
        let rect = videoRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        let nx = (viewPoint.x - rect.minX) / rect.width
        let ny = (viewPoint.y - rect.minY) / rect.height
        guard nx >= 0, nx <= 1, ny >= 0, ny <= 1 else { return nil }
        return CGPoint(x: nx * screen.width, y: ny * screen.height)
    }

    // MARK: - Events

    /// True while a ⌘-drag is moving the window rather than touching the phone.
    private var isMovingWindow = false

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // The video fills the window, leaving only a few points of bezel to grab,
        // so ⌘-drag moves the window from anywhere. Command is never forwarded to
        // the phone, so this cannot be mistaken for a touch.
        if event.modifierFlags.contains(.command) {
            isMovingWindow = true
            window?.performDrag(with: event)
            return
        }
        isMovingWindow = false
        inputController?.mouseDown(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isMovingWindow else { return }
        inputController?.mouseMoved(dx: event.deltaX, dy: event.deltaY)
        inputController?.mouseDragged(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        inputController?.mouseMoved(dx: event.deltaX, dy: event.deltaY)
    }

    override func mouseUp(with event: NSEvent) {
        if isMovingWindow {
            isMovingWindow = false
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if inputController?.isActive == true {
            showRipple(at: point)
        }
        inputController?.mouseUp(at: point)
    }

    override func resetCursorRects() {
        // Hint that the surface is grabbable while Command is held.
        discardCursorRects()
        addCursorRect(bounds, cursor: NSEvent.modifierFlags.contains(.command)
                      ? .openHand : .arrow)
    }

    override func flagsChanged(with event: NSEvent) {
        window?.invalidateCursorRects(for: self)
        super.flagsChanged(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        inputController?.scroll(event, at: convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        if inputController?.keyDown(event) != true {
            super.keyDown(with: event)
        }
    }

    // MARK: - Tap ripple

    private func showRipple(at point: CGPoint) {
        let diameter: CGFloat = 14
        let ripple = CAShapeLayer()
        ripple.path = CGPath(ellipseIn: CGRect(x: -diameter / 2, y: -diameter / 2,
                                               width: diameter, height: diameter), transform: nil)
        ripple.position = point
        ripple.fillColor = NSColor.white.withAlphaComponent(0.35).cgColor
        ripple.strokeColor = NSColor.white.withAlphaComponent(0.6).cgColor
        ripple.lineWidth = 1
        displayLayer.addSublayer(ripple)

        CATransaction.begin()
        CATransaction.setCompletionBlock { ripple.removeFromSuperlayer() }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.6
        scale.toValue = 2.2
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.35
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        ripple.add(group, forKey: "ripple")
        CATransaction.commit()
    }
}
