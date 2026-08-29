import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let receiver = AirPlayReceiver.shared
    private let pipeline = VideoPipeline()
    private let wda = WDAClient()
    private lazy var inputController = InputController(wda: wda)
    private let statusBar = StatusBarController()
    private let windowController = MirrorWindowController()
    private var controlPopover: NSPopover?

    private var clientDeviceID: String?
    private var clientName: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        wireVideo()
        wireControl()
        wireUI()
        startReceiver()
    }

    func applicationWillTerminate(_ notification: Notification) {
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

    private func wireControl() {
        windowController.videoView.inputController = inputController
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
        windowController.onClose = { [weak self] in
            self?.windowController.dismiss()
        }
        windowController.onControlToggle = { [weak self] in
            self?.toggleControl()
        }
    }

    private func startReceiver() {
        let name = Settings.receiverName
        if receiver.start(name: name) {
            statusBar.setReceiverState("Visible as “\(name)”")
        } else {
            statusBar.setReceiverState("Receiver failed to start")
        }
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
            // Reconnect control automatically for known devices.
            if let host = Settings.wdaHost(forDevice: deviceID) {
                wda.connect(host: host)
            }
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
        case .disconnected:
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
