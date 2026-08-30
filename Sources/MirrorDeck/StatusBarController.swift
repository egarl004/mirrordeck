import AppKit

/// The app's idle presence: a single menu bar item, no Dock icon.
final class StatusBarController {
    private let statusItem: NSStatusItem
    private let stateItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let clientItem = NSMenuItem(title: "No device connected", action: nil, keyEquivalent: "")
    private let showItem: NSMenuItem

    var onShowWindow: (() -> Void)?
    var onQuit: (() -> Void)?

    private static let autosaveName = "MirrorDeckStatusItem"

    init() {
        // Given no stored preference, macOS picks a slot for a new item that on
        // a full menu bar can land behind the camera notch, where it renders as
        // nothing and cannot be clicked. Seeding a position once puts it in the
        // ordinary run of menu bar icons instead. Only seeded when absent, so a
        // position the user ⌘-drags to (saved under autosaveName) always wins.
        let positionKey = "NSStatusItem Preferred Position \(Self.autosaveName)"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(50.0, forKey: positionKey)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = Self.autosaveName
        statusItem.button?.image = NSImage(
            systemSymbolName: "iphone.gen3",
            accessibilityDescription: "MirrorDeck")
        statusItem.button?.toolTip = "MirrorDeck"

        showItem = NSMenuItem(title: "Show Mirror Window", action: #selector(showWindow), keyEquivalent: "m")

        let menu = NSMenu()
        stateItem.isEnabled = false
        clientItem.isEnabled = false
        showItem.target = self
        showItem.isEnabled = false
        let quitItem = NSMenuItem(title: "Quit MirrorDeck", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self

        menu.addItem(stateItem)
        menu.addItem(clientItem)
        menu.addItem(.separator())
        menu.addItem(showItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    func setReceiverState(_ text: String) {
        stateItem.title = text
    }

    /// True when macOS placed the icon behind the display notch. That happens
    /// when the menu bar is full: the item reports itself visible and has a
    /// valid frame, but nothing renders there and it cannot be clicked.
    var isHiddenBehindNotch: Bool {
        guard let window = statusItem.button?.window else { return false }
        guard let screen = window.screen ?? NSScreen.main,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return false }
        let frame = window.frame
        return frame.minX < right.minX && frame.maxX > left.maxX
    }

    /// Logs where the icon ended up; both are invisible when something is wrong.
    func logPlacement() {
        guard let window = statusItem.button?.window else {
            NSLog("[MirrorDeck] status item has no window — it was not placed")
            return
        }
        let frame = window.frame
        NSLog("[MirrorDeck] status item at x=%.0f-%.0f y=%.0f visible=%@",
              frame.minX, frame.maxX, frame.minY,
              statusItem.isVisible ? "yes" : "no")
        guard let screen = window.screen ?? NSScreen.main,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else {
            NSLog("[MirrorDeck] display has no notch")
            return
        }
        NSLog("[MirrorDeck] notch spans x=%.0f-%.0f -> icon %@",
              left.maxX, right.minX,
              isHiddenBehindNotch ? "IS BEHIND THE NOTCH (free menu bar space)"
                                  : "is clear of the notch")
    }

    func setClient(_ name: String?) {
        clientItem.title = name.map { "Mirroring: \($0)" } ?? "No device connected"
        showItem.isEnabled = name != nil
        statusItem.button?.image = NSImage(
            systemSymbolName: name != nil ? "iphone.gen3.radiowaves.left.and.right" : "iphone.gen3",
            accessibilityDescription: "MirrorDeck")
    }

    @objc private func showWindow() { onShowWindow?() }
    @objc private func quit() { onQuit?() }
}
