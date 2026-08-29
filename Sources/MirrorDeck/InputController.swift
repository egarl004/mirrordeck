import AppKit

/// Translates mouse/keyboard events on the mirror view into WDA gestures,
/// using Simulator conventions: click = tap, click-drag = pan/swipe,
/// hold = long press, scroll = swipe, typing goes to the phone keyboard.
final class InputController {
    let wda: WDAClient
    /// Maps a point in the video view to device points; nil while size unknown.
    var viewToDevice: ((CGPoint) -> CGPoint?)?

    private var dragPoints: [CGPoint] = []
    private var dragTimes: [TimeInterval] = []
    private var dragStartTime: TimeInterval = 0
    private var scrollAccumulator = CGVector.zero
    private var scrollOrigin: CGPoint = .zero
    private var lastNavigationTime: TimeInterval = 0

    init(wda: WDAClient) {
        self.wda = wda
    }

    var isActive: Bool {
        if case .connected = wda.state { return true }
        return false
    }

    // MARK: - Mouse

    func mouseDown(at viewPoint: CGPoint) {
        guard let devicePoint = viewToDevice?(viewPoint) else { return }
        dragPoints = [devicePoint]
        dragTimes = [0]
        dragStartTime = ProcessInfo.processInfo.systemUptime
    }

    func mouseDragged(to viewPoint: CGPoint) {
        guard !dragPoints.isEmpty, let devicePoint = viewToDevice?(viewPoint) else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - dragStartTime
        // Throttle samples so the W3C action list stays small.
        if elapsed - (dragTimes.last ?? 0) >= 0.03 {
            dragPoints.append(devicePoint)
            dragTimes.append(elapsed)
        }
    }

    func mouseUp(at viewPoint: CGPoint) {
        guard isActive, let start = dragPoints.first else {
            dragPoints = []
            return
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - dragStartTime
        let end = viewToDevice?(viewPoint) ?? dragPoints.last ?? start
        let distance = hypot(end.x - start.x, end.y - start.y)

        if distance < 4 {
            if elapsed < 0.35 {
                wda.tap(at: start)
            } else {
                wda.longPress(at: start, duration: elapsed)
            }
        } else {
            if dragPoints.last != end {
                dragPoints.append(end)
                dragTimes.append(elapsed)
            }
            wda.drag(points: dragPoints, timestamps: dragTimes)
        }
        dragPoints = []
        dragTimes = []
    }

    // MARK: - Scrolling → swipe

    func scroll(_ event: NSEvent, at viewPoint: CGPoint) {
        guard isActive else { return }
        switch event.phase {
        case .began:
            scrollAccumulator = .zero
            scrollOrigin = viewPoint
        case .changed:
            scrollAccumulator.dx += event.scrollingDeltaX
            scrollAccumulator.dy += event.scrollingDeltaY
        case .ended:
            sendScrollSwipe()
        default:
            // Legacy wheel events have no phases; treat each as a small step.
            if event.phase == [] && event.momentumPhase == [] {
                scrollOrigin = viewPoint
                scrollAccumulator = CGVector(dx: event.scrollingDeltaX * 6,
                                             dy: event.scrollingDeltaY * 6)
                sendScrollSwipe()
            }
        }
    }

    private func sendScrollSwipe() {
        guard let origin = viewToDevice?(scrollOrigin) else { return }
        let dx = scrollAccumulator.dx
        let dy = scrollAccumulator.dy
        guard abs(dx) > 2 || abs(dy) > 2 else { return }
        // Natural scrolling: content follows the finger, same sign as deltas.
        let target = CGPoint(x: origin.x + dx, y: origin.y + dy)
        wda.drag(points: [origin, target], timestamps: [0, 0.18])
        scrollAccumulator = .zero
    }

    // MARK: - Keyboard

    /// macOS virtual key codes for the keys handled as navigation.
    private enum Key {
        static let returnKey: UInt16 = 36
        static let delete: UInt16 = 51
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
    }

    /// Returns true when the event was consumed.
    func keyDown(_ event: NSEvent) -> Bool {
        guard isActive else { return false }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "h" where event.modifierFlags.contains(.shift):
                wda.pressButton("home")
                return true
            default:
                return false // let ⌘W etc. reach the app
            }
        }
        switch event.keyCode {
        // Arrow keys must be intercepted before the typeText fallback: they
        // carry private-use function characters that would be sent as garbage.
        case Key.up:
            if allowNavigation() { wda.pressButton("home") }
        case Key.left:
            if allowNavigation() { swipePage(towardNext: false) }
        case Key.right:
            if allowNavigation() { swipePage(towardNext: true) }
        case Key.down:
            if allowNavigation() { scrollContentDown() }
        case Key.returnKey:
            wda.typeText("\n")
        case Key.delete:
            wda.typeText("\u{8}")           // XCUIKeyboardKeyDelete
        default:
            guard let characters = event.characters, !characters.isEmpty else { return false }
            wda.typeText(characters)
        }
        return true
    }

    /// Each gesture costs ~0.5s on-device, so key auto-repeat would otherwise
    /// queue up a flood of swipes. Rate-limit to roughly one page per press.
    private func allowNavigation() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastNavigationTime >= 0.35 else { return false }
        lastNavigationTime = now
        return true
    }

    /// Horizontal page swipe. Advancing to the next page means the finger
    /// travels right-to-left (verified against a physical device).
    private func swipePage(towardNext: Bool) {
        guard case .connected(let screen) = wda.state else { return }
        let y = screen.height / 2
        // Stay clear of the edges; those belong to system gestures (back, Today view).
        let near = screen.width * 0.12
        let far = screen.width * 0.88
        wda.drag(points: [CGPoint(x: towardNext ? far : near, y: y),
                          CGPoint(x: towardNext ? near : far, y: y)],
                 timestamps: [0, 0.12])
    }

    /// Scrolls content downward, mirroring a finger swipe up the middle.
    private func scrollContentDown() {
        guard case .connected(let screen) = wda.state else { return }
        let x = screen.width / 2
        wda.drag(points: [CGPoint(x: x, y: screen.height * 0.62),
                          CGPoint(x: x, y: screen.height * 0.28)],
                 timestamps: [0, 0.15])
    }
}
