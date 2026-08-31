import AppKit

/// The app's idle presence: a single menu bar item, no Dock icon.
final class StatusBarController {
    private let statusItem: NSStatusItem
    private let stateItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let clientItem = NSMenuItem(title: "No device connected", action: nil, keyEquivalent: "")
    private let showItem: NSMenuItem
    private let onTopItem: NSMenuItem
    private let bluetoothItem: NSMenuItem
    /// Live Bluetooth input status, so a failure is visible without the log.
    private let bluetoothStatusItem = NSMenuItem(
        title: "Bluetooth input: off", action: nil, keyEquivalent: "")
    private let pointerItem = NSMenuItem(title: "Pointer Tracking", action: nil, keyEquivalent: "")

    /// Presets rather than raw numbers: these three knobs only make sense in
    /// combination, and the useful range is narrow.
    /// (threshold, transit heartbeat ms, minimum gap ms)
    static let pointerPresets: [(name: String, threshold: Int, transit: Double, gap: Double)] = [
        // Transit heartbeat effectively disabled: nothing at all is sent while
        // the cursor is moving, only the exact position once it stops.
        ("Snap only",     99_999, 600_000, 120),
        ("Snap on stop",  32767, 250, 120),
        ("Coarse",         1200, 160,  90),
        ("Balanced",        400, 120,  65),
        ("Smooth",          120,  90,  45),
    ]

    var onShowWindow: (() -> Void)?
    var onQuit: (() -> Void)?
    var onToggleAlwaysOnTop: ((Bool) -> Void)?
    /// Address of the paired iPhone to drive over Bluetooth, or nil to stop.
    var onSelectBluetoothPhone: ((String?) -> Void)?
    /// Applied live — the pointer logic re-reads these on every report.
    var onSelectPointerPreset: ((String) -> Void)?
    var onCalibratePointer: (() -> Void)?
    var onTestMouseKeys: (() -> Void)?

    @objc private func testMouseKeys() { onTestMouseKeys?() }

    @objc private func calibratePointer() { onCalibratePointer?() }

    @objc private func selectPointerPreset(_ sender: NSMenuItem) {
        sender.menu?.items.forEach { $0.state = $0 === sender ? .on : .off }
        onSelectPointerPreset?(sender.title)
    }

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
        onTopItem = NSMenuItem(title: "Keep Window on Top", action: #selector(toggleOnTop), keyEquivalent: "t")
        bluetoothItem = NSMenuItem(title: "Control over Bluetooth", action: nil, keyEquivalent: "")

        let menu = NSMenu()
        stateItem.isEnabled = false
        clientItem.isEnabled = false
        showItem.target = self
        showItem.isEnabled = false
        onTopItem.target = self
        let quitItem = NSMenuItem(title: "Quit MirrorDeck", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self

        menu.addItem(stateItem)
        menu.addItem(clientItem)
        menu.addItem(.separator())
        menu.addItem(showItem)
        menu.addItem(onTopItem)
        bluetoothItem.submenu = buildBluetoothMenu()
        menu.addItem(bluetoothItem)
        menu.addItem(bluetoothStatusItem)
        let pointerMenu = NSMenu()
        let current = UserDefaults.standard.string(forKey: "pointerPreset") ?? "Balanced"
        for preset in Self.pointerPresets {
            let item = NSMenuItem(title: preset.name,
                                  action: #selector(selectPointerPreset(_:)), keyEquivalent: "")
            item.target = self
            item.state = preset.name == current ? .on : .off
            pointerMenu.addItem(item)
        }
        pointerMenu.addItem(.separator())
        let calibrate = NSMenuItem(title: "Calibrate Automatically",
                                   action: #selector(calibratePointer), keyEquivalent: "")
        calibrate.target = self
        pointerMenu.addItem(calibrate)
        let mkTest = NSMenuItem(title: "Test Mouse Keys (hold Keypad 8)",
                                action: #selector(testMouseKeys), keyEquivalent: "")
        mkTest.target = self
        pointerMenu.addItem(mkTest)
        pointerItem.submenu = pointerMenu
        menu.addItem(pointerItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    /// Lists paired iPhones. Bluetooth needs no setup on the phone beyond
    /// pairing, so anything already paired can be driven immediately.
    private func buildBluetoothMenu() -> NSMenu {
        let menu = NSMenu()
        let phones = BluetoothHID.pairedPhones()
        if phones.isEmpty {
            let none = NSMenuItem(title: "No paired iPhone found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for phone in phones {
                let item = NSMenuItem(title: phone.name, action: #selector(selectPhone(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = phone.address
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let off = NSMenuItem(title: "Turn Off", action: #selector(stopBluetooth), keyEquivalent: "")
            off.target = self
            menu.addItem(off)
        }
        menu.autoenablesItems = false
        return menu
    }

    @objc private func selectPhone(_ sender: NSMenuItem) {
        onSelectBluetoothPhone?(sender.representedObject as? String)
    }

    @objc private func stopBluetooth() { onSelectBluetoothPhone?(nil) }

    /// Rebuilt on open so newly paired phones appear without a relaunch.
    func refreshBluetoothMenu() { bluetoothItem.submenu = buildBluetoothMenu() }

    func setBluetoothState(_ connected: Bool, name: String?) {
        bluetoothItem.title = connected
            ? "Control over Bluetooth — \(name ?? "on")"
            : "Control over Bluetooth"
    }

    /// Shown directly under the Bluetooth menu item. Failure reasons are
    /// surfaced here rather than only in the log.
    func setBluetoothStatus(_ text: String) {
        bluetoothStatusItem.title = "Bluetooth input: \(text)"
    }

    /// Reflects the current state in the menu's checkmark.
    func setAlwaysOnTop(_ on: Bool) {
        onTopItem.state = on ? .on : .off
    }

    @objc private func toggleOnTop() {
        let newValue = onTopItem.state != .on
        onTopItem.state = newValue ? .on : .off
        onToggleAlwaysOnTop?(newValue)
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
