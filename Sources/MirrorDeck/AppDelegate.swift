import AppKit
import IOBluetooth

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let receiver = AirPlayReceiver.shared
    private let pipeline = VideoPipeline()
    private let wda = WDAClient()
    private let hid = BluetoothHID()
    private lazy var inputController = InputController(wda: wda)
    // Lazy on purpose: AppDelegate is constructed before NSApplication.run(),
    // and an NSStatusItem created that early never appears in the menu bar.
    // First access is from wireUI(), during applicationDidFinishLaunching.
    private lazy var statusBar = StatusBarController()
    private let windowController = MirrorWindowController()
    private var controlPopover: NSPopover?

    private var clientDeviceID: String?
    private var clientName: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        wireVideo()
        wireControl()
        // Bluetooth stays untouched until the user selects a phone from the
        // menu — no advertising, no dialling, nothing automatic at launch.
        wireUI()
        startReceiver()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Synchronous: an async teardown does not finish before the process
        // exits, and the HID service record survives inside bluetoothd to break
        // the next pairing. Also restores the Mac's own device class, without
        // which phones report it as unsupported and refuse to pair.
        hid.shutdownSynchronously()
        receiver.stop()
    }

    // MARK: - Wiring

    private func wireVideo() {
        pipeline.displayLayer = windowController.videoView.displayLayer
        receiver.onVideo = { [pipeline] data, length, isH265 in
            guard !isH265 else { return } // H.265 not advertised; ignore defensively
            pipeline.handleAccessUnit(data, length)
        }
        pipeline.onDimensions = { [weak self] width, height in
            guard let self else { return }
            self.windowController.setVideoDimensions(width: width, height: height)
            self.windowController.present()
        }
        receiver.onEvent = { [weak self] event in
            self?.handleReceiverEvent(event)
        }
        receiver.onLog = { level, message in
            if level <= 6 { // NOTICE and above
                NSLog("[receiver] %@", message)
            }
        }
    }

    /// Measures the phone's pointer scaling by moving a known amount and
    /// watching the mirror to see how far it actually went.
    private func calibratePointer() {
        DebugLog.write("calibration: invoked")
        guard let window = windowController.window else {
            reportCalibration("no mirror window — start mirroring first")
            return
        }
        DebugLog.write("calibration: window #\(window.windowNumber) visible=\(window.isVisible)")
        // Send a fixed number of identical steps and see how far they went.
        // Because every step is the same magnitude, distance is linear in the
        // number of steps, so one measurement gives steps-per-screen.
        let probeSteps = 30
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            self.hid.anchorNow()
            Thread.sleep(forTimeInterval: 1.0)
            guard let before = PointerCalibration.capture(window: window) else {
                self.reportCalibration("capture failed — grant Screen Recording in System Settings > Privacy")
                return
            }
            DebugLog.write("calibration: captured \(before.width)x\(before.height)")
            for _ in 0..<probeSteps {
                self.hid.nudgeUnits(dx: BluetoothHID.stepMagnitude, dy: 0)
            }
            Thread.sleep(forTimeInterval: 1.2)
            guard let after = PointerCalibration.capture(window: window),
                  let moved = PointerCalibration.movement(from: before, to: after) else {
                self.reportCalibration("could not see the pointer move")
                return
            }
            let travelled = Double(moved.x)
            let width = Double(before.width)
            guard travelled > width * 0.02 else {
                self.reportCalibration("pointer barely moved — is it connected?")
                return
            }
            let perScreen = Double(probeSteps) * (width / travelled)
            UserDefaults.standard.set(perScreen, forKey: "stepsPerScreen")
            self.hid.reanchor()
            self.reportCalibration(String(format: "%.0f steps per screen (%.0f of %.0f px in %d steps)",
                                          perScreen, travelled, width, probeSteps))
        }
    }

    private func reportCalibration(_ text: String) {
        DebugLog.write("calibration: \(text)")
        DispatchQueue.main.async { [weak self] in
            self?.statusBar.setBluetoothStatus("calibration — \(text)")
        }
    }

    private func applyPointerPreset(_ name: String) {
        guard let preset = StatusBarController.pointerPresets.first(where: { $0.name == name })
        else { return }
        let d = UserDefaults.standard
        d.set(name, forKey: "pointerPreset")
        d.set(preset.threshold, forKey: "pointerThreshold")
        d.set(preset.transit, forKey: "pointerTransitMs")
        d.set(preset.gap, forKey: "pointerMinGapMs")
        NSLog("[MirrorDeck] pointer preset: %@", name)
    }

    private func wireControl() {
        statusBar.onCalibratePointer = { [weak self] in self?.calibratePointer() }
        statusBar.onTestMouseKeys = { [weak self] in self?.hid.testMouseKeysMovement() }
        statusBar.onSelectPointerPreset = { [weak self] name in
            self?.applyPointerPreset(name)
        }
        windowController.videoView.inputController = inputController
        inputController.hid = hid
        hid.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .connected(let name):
                self.windowController.usingBluetooth = true
                self.windowController.setControlState(.connected(screenSize: .zero))
                self.statusBar.setBluetoothState(true, name: name)
                self.statusBar.setBluetoothStatus("connected to \(name)")
                NSLog("[MirrorDeck] Bluetooth input connected to %@", name)
            case .failed(let reason):
                self.windowController.usingBluetooth = false
                self.statusBar.setBluetoothState(false, name: nil)
                self.statusBar.setBluetoothStatus(reason)
                NSLog("[MirrorDeck] Bluetooth input unavailable: %@", reason)
            case .connecting:
                self.statusBar.setBluetoothStatus("connecting…")
            case .idle:
                self.statusBar.setBluetoothStatus("off")
            }
        }
        inputController.viewToDevice = { [weak self] viewPoint in
            self?.windowController.videoView.devicePoint(for: viewPoint)
        }
        wda.onStateChange = { [weak self] state in
            guard let self else { return }
            self.windowController.setControlState(state)
            if case .connected(let screenSize) = state {
                self.windowController.videoView.deviceScreenSize = screenSize
            } else {
                self.windowController.videoView.deviceScreenSize = nil
            }
        }
    }

    private func wireUI() {
        statusBar.onShowWindow = { [weak self] in
            self?.windowController.present()
        }
        statusBar.onQuit = {
            NSApp.terminate(nil)
        }
        statusBar.onSelectBluetoothPhone = { [weak self] address in
            guard let self else { return }
            if let address {
                DebugLog.write("menu: selected phone \(address)")
                Settings.bluetoothPhoneAddress = address
                self.hid.connect(toAddress: address)
            } else {
                Settings.bluetoothPhoneAddress = nil
                self.hid.disconnect()
                self.statusBar.setBluetoothState(false, name: nil)
            }
        }
        statusBar.onToggleAlwaysOnTop = { [weak self] on in
            Settings.alwaysOnTop = on
            self?.windowController.isAlwaysOnTop = on
        }
        // Restore the stored preference before the window is ever shown.
        windowController.isAlwaysOnTop = Settings.alwaysOnTop
        statusBar.setAlwaysOnTop(Settings.alwaysOnTop)
        windowController.onClose = { [weak self] in
            self?.windowController.dismiss()
        }
        windowController.onControlToggle = { [weak self] in
            self?.toggleControl()
        }
    }

    /// Set MIRRORDECK_DEBUG=1 to log the AirPlay handshake and where the menu
    /// bar icon was placed. Both are otherwise invisible when something is wrong.
    static let debugEnabled = ProcessInfo.processInfo.environment["MIRRORDECK_DEBUG"] == "1"

    private func startReceiver() {
        let name = Settings.receiverName
        if receiver.start(name: name, debug: AppDelegate.debugEnabled) {
            statusBar.setReceiverState("Visible as “\(name)”")
            NSLog("[MirrorDeck] receiver started, advertising as “%@”", name)
        } else {
            statusBar.setReceiverState("Receiver failed to start")
            NSLog("[MirrorDeck] RECEIVER FAILED TO START")
        }
        // Placement is only decided once the menu bar has laid out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            if AppDelegate.debugEnabled { self.statusBar.logPlacement() }
            if self.statusBar.isHiddenBehindNotch { self.warnIconHidden() }
        }

        // MIRRORDECK_PREVIEW=1 opens the mirror window with an iPhone-shaped
        // placeholder. The window otherwise only exists while a phone is
        // connected, which leaves no way to check its layout while working on it.
        if ProcessInfo.processInfo.environment["MIRRORDECK_PREVIEW"] == "1" {
            windowController.setDeviceName("Preview")
            windowController.setVideoDimensions(width: 1179, height: 2556)
            windowController.present()
            // MIRRORDECK_PREVIEW_HOST exercises the control states without a
            // phone — point it at an unreachable address to see the failure UI.
            if let host = ProcessInfo.processInfo.environment["MIRRORDECK_PREVIEW_HOST"] {
                wda.connect(host: host)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, let window = self.windowController.window else { return }
                let video = self.windowController.videoView.frame
                let content = window.contentView!.bounds
                NSLog("[MirrorDeck] window %.0fx%.0f  video %.0fx%.0f at y=%.0f  topBar=%.0fpt  level=%ld",
                      content.width, content.height, video.width, video.height,
                      video.minY, content.height - video.maxY, window.level.rawValue)
            }
        }
    }

    /// Without this the app looks simply broken: no icon, no window, no reason.
    /// Shown once, since the remedy is a change to the user's menu bar.
    private func warnIconHidden() {
        let key = "didWarnIconBehindNotch"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        let alert = NSAlert()
        alert.messageText = "MirrorDeck's menu bar icon is hidden behind the notch"
        alert.informativeText = """
            MirrorDeck is running, but your menu bar is full, so macOS placed \
            its icon behind the camera notch where it cannot be seen or clicked.

            Quit or hide one or two other menu bar apps and it will appear. You \
            can then ⌘-drag it anywhere, and it will stay there.

            Mirroring works either way — pick this Mac from Screen Mirroring on \
            your iPhone and the window will open on its own.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Receiver events

    private func handleReceiverEvent(_ event: ReceiverEvent) {
        switch event {
        case .clientInfo(let deviceID, _, let name):
            clientDeviceID = deviceID
            clientName = name
            let displayName = name.isEmpty ? "iPhone" : name
            statusBar.setClient(displayName)
            windowController.setDeviceName(displayName)
            // WebDriverAgent is no longer connected automatically: Bluetooth
            // input replaced it, needs no setup on the phone, and does not die
            // hourly. It stays available from the toolbar for absolute
            // coordinates, which Bluetooth pointing cannot express.
            _ = deviceID
        case .disconnected:
            statusBar.setClient(nil)
            windowController.dismiss()
            wda.disconnect()
            pipeline.reset()
            clientDeviceID = nil
            clientName = nil
        case .videoFlush:
            pipeline.flush()
        case .connReset:
            pipeline.reset()
        default:
            break
        }
    }

    // MARK: - Control setup

    private func toggleControl() {
        switch wda.state {
        case .connected, .connecting:
            wda.disconnect()
        case .disconnected, .failed:
            // Reopen the setup popover so the host can be corrected after a
            // failure, rather than leaving the button inert.
            showControlSetup()
        }
    }

    private func showControlSetup() {
        let popover = NSPopover()
        popover.behavior = .transient

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 116))
        let title = NSTextField(labelWithString: "Connect to WebDriverAgent")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let hint = NSTextField(wrappingLabelWithString: "Phone's Wi-Fi IP (WDA on port 8100)")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        let knownHost = clientDeviceID.flatMap { Settings.wdaHost(forDevice: $0) } ?? Settings.lastWDAHost
        let field = NSTextField(string: knownHost ?? "")
        field.placeholderString = "192.168.1.23"
        let connectButton = NSButton(title: "Connect", target: self, action: #selector(connectControl(_:)))
        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"

        let stack = NSStackView(views: [title, hint, field, connectButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.frame = contentView.bounds
        stack.autoresizingMask = [.width, .height]
        field.widthAnchor.constraint(equalToConstant: 200).isActive = true
        contentView.addSubview(stack)

        let controller = NSViewController()
        controller.view = contentView
        popover.contentViewController = controller
        field.tag = 1
        controlPopover = popover
        popover.show(relativeTo: windowController.controlButtonAnchor.bounds,
                     of: windowController.controlButtonAnchor, preferredEdge: .minY)
        field.becomeFirstResponder()
    }

    @objc private func connectControl(_ sender: NSButton) {
        guard let contentView = controlPopover?.contentViewController?.view,
              let field = firstTextField(in: contentView) else { return }
        let host = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        if let deviceID = clientDeviceID {
            Settings.setWDAHost(host, forDevice: deviceID)
        }
        wda.connect(host: host)
        controlPopover?.close()
        controlPopover = nil
        windowController.window?.makeFirstResponder(windowController.videoView)
    }

    private func firstTextField(in view: NSView) -> NSTextField? {
        for subview in view.subviews {
            if let field = subview as? NSTextField, field.isEditable { return field }
            if let found = firstTextField(in: subview) { return found }
        }
        return nil
    }
}
