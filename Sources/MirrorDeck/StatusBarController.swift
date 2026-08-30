import AppKit

/// The app's idle presence: a single menu bar item, no Dock icon.
final class StatusBarController {
    private let statusItem: NSStatusItem
    private let stateItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let clientItem = NSMenuItem(title: "No device connected", action: nil, keyEquivalent: "")
    private let showItem: NSMenuItem

    var onShowWindow: (() -> Void)?
    var onQuit: (() -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Remembers where the user ⌘-drags the icon. Matters on notched Macs:
        // when the menu bar is full macOS parks new items behind the notch,
        // and without this the icon would return there on every launch.
        statusItem.autosaveName = "MirrorDeckStatusItem"
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
