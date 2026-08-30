import AppKit

/// Translates mouse and keyboard events on the mirror view into input on the
/// phone, using Simulator conventions: click = tap, click-drag = pan/swipe,
/// hold = long press, scroll = scroll, typing goes to the phone.
///
/// Two transports. Bluetooth HID is preferred when connected — it needs no
/// setup on the phone beyond pairing, and lands in milliseconds rather than
/// WebDriverAgent's ~500ms. WDA remains as a fallback, and is still the only
/// one that can address absolute screen coordinates.
final class InputController {
    let wda: WDAClient
    var hid: BluetoothHID?
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

    var isActive: Bool { usingBluetooth || wdaConnected }

    /// Bluetooth wins when both are available: it is far faster.
    private var usingBluetooth: Bool { hid?.isConnected ?? false }
    private var wdaConnected: Bool {
        if case .connected = wda.state { return true }
        return false
    }

    // MARK: - Mouse

    /// Relative pointer movement, for the Bluetooth transport.
    func mouseMoved(dx: CGFloat, dy: CGFloat) {
        guard usingBluetooth else { return }
        let ix = Int(dx.rounded()), iy = Int(dy.rounded())
        guard ix != 0 || iy != 0 else { return }
        if InputController.debug {
            NSLog("[MirrorDeck] pointer dx=%d dy=%d", ix, iy)
        }
        hid?.movePointer(dx: ix, dy: iy)
    }

    static let debug = ProcessInfo.processInfo.environment["MIRRORDECK_DEBUG"] == "1"

    func mouseDown(at viewPoint: CGPoint) {
        if usingBluetooth { hid?.setMouseButton(true); return }
        guard let devicePoint = viewToDevice?(viewPoint) else { return }
        dragPoints = [devicePoint]
        dragTimes = [0]
        dragStartTime = ProcessInfo.processInfo.systemUptime
    }

    func mouseDragged(to viewPoint: CGPoint) {
        if usingBluetooth { return }   // movement arrives via mouseMoved(dx:dy:)
        guard !dragPoints.isEmpty, let devicePoint = viewToDevice?(viewPoint) else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - dragStartTime
        // Throttle samples so the W3C action list stays small.
        if elapsed - (dragTimes.last ?? 0) >= 0.03 {
            dragPoints.append(devicePoint)
            dragTimes.append(elapsed)
        }
    }

    func mouseUp(at viewPoint: CGPoint) {
        if usingBluetooth { hid?.setMouseButton(false); return }
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
        if usingBluetooth {
            // A wheel notch per few points of scroll, sign matched to macOS.
            let notches = Int((event.scrollingDeltaY / 8).rounded())
            if notches != 0 { hid?.scroll(notches) }
            return
        }
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

    /// USB HID keyboard usage for a macOS virtual key code, where one exists.
    private static let hidUsage: [UInt16: UInt8] = [
        0:0x04, 11:0x05, 8:0x06, 2:0x07, 14:0x08, 3:0x09, 5:0x0A, 4:0x0B,       // a b c d e f g h
        34:0x0C, 38:0x0D, 40:0x0E, 37:0x0F, 46:0x10, 45:0x11, 31:0x12, 35:0x13, // i j k l m n o p
        12:0x14, 15:0x15, 1:0x16, 17:0x17, 32:0x18, 9:0x19, 13:0x1A, 7:0x1B,    // q r s t u v w x
        16:0x1C, 6:0x1D,                                                         // y z
        18:0x1E, 19:0x1F, 20:0x20, 21:0x21, 23:0x22,                             // 1-5
        22:0x23, 26:0x24, 28:0x25, 25:0x26, 29:0x27,                             // 6-0
        36:0x28, 53:0x29, 51:0x2A, 48:0x2B, 49:0x2C,                             // return esc delete tab space
        27:0x2D, 24:0x2E, 33:0x2F, 30:0x30, 42:0x31,                             // - = [ ] \
        41:0x33, 39:0x34, 50:0x35, 43:0x36, 47:0x37, 44:0x38,                    // ; ' ` , . /
        126:0x52, 125:0x51, 123:0x50, 124:0x4F,                                  // arrows
    ]

    private static func modifierBits(_ flags: NSEvent.ModifierFlags) -> UInt8 {
        var m: UInt8 = 0
        if flags.contains(.shift)   { m |= 0x02 }
        if flags.contains(.control) { m |= 0x01 }
        if flags.contains(.option)  { m |= 0x04 }
        if flags.contains(.command) { m |= 0x08 }
        return m
    }

    /// Returns true when the event was consumed.
    func keyDown(_ event: NSEvent) -> Bool {
        guard isActive else { return false }

        // Bluetooth carries real key events, so the phone applies its own
        // repeat, modifiers and layout — no need to synthesise gestures.
        if usingBluetooth {
            // ⌘ combinations still belong to the Mac, except Home.
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "h",
               event.modifierFlags.contains(.shift) {
                hid?.pressKey(0x4A)          // Home
                return true
            }
            guard let usage = Self.hidUsage[event.keyCode] else { return false }
            hid?.pressKey(usage, modifiers: Self.modifierBits(event.modifierFlags))
            return true
        }
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
