import AppKit
import AVFoundation

/// Borderless window that can still become key (needed for typing).
final class MirrorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Draggable black bezel that frames the mirror — the window *is* the phone.
final class BezelView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 26
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

final class MirrorWindowController: NSWindowController {
    let videoView = MirrorVideoView()
    private let bezelView = BezelView()
    private let toolbar = NSVisualEffectView()
    private let deviceNameLabel = NSTextField(labelWithString: "iPhone")
    private let controlDot = NSView()
    private let controlButton = NSButton()
    private var toolbarVisible = false
    private var hideToolbarTimer: Timer?

    private let bezelInset: CGFloat = 6

    var onControlToggle: (() -> Void)?
    var onClose: (() -> Void)?

    init() {
        let window = MirrorWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 700),
            styleMask: [.borderless, .resizable],
            backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenNone]
        window.minSize = NSSize(width: 180, height: 320)
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildContent() {
        guard let window, let content = window.contentView else { return }
        bezelView.frame = content.bounds
        bezelView.autoresizingMask = [.width, .height]
        content.addSubview(bezelView)

        videoView.frame = bezelView.bounds.insetBy(dx: bezelInset, dy: bezelInset)
        videoView.autoresizingMask = [.width, .height]
        bezelView.addSubview(videoView)

        buildToolbar()

        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        content.addTrackingArea(tracking)
    }

    private func buildToolbar() {
        toolbar.material = .hudWindow
        toolbar.state = .active
        toolbar.blendingMode = .withinWindow
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 15
        toolbar.layer?.cornerCurve = .continuous
        toolbar.alphaValue = 0

        deviceNameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        deviceNameLabel.textColor = .white

        controlDot.wantsLayer = true
        controlDot.layer?.backgroundColor = NSColor.systemGray.cgColor
        controlDot.layer?.cornerRadius = 3.5

        controlButton.bezelStyle = .accessoryBarAction
        controlButton.title = "Enable Control"
        controlButton.font = .systemFont(ofSize: 11, weight: .medium)
        controlButton.target = self
        controlButton.action = #selector(controlTapped)

        let closeButton = NSButton()
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Disconnect")
        closeButton.target = self
        closeButton.action = #selector(closeTapped)

        let stack = NSStackView(views: [controlDot, deviceNameLabel, controlButton, closeButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 8)
        controlDot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        controlDot.heightAnchor.constraint(equalToConstant: 7).isActive = true

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(stack)
        bezelView.addSubview(toolbar)
        guard let content = window?.contentView else { return }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: toolbar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            toolbar.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
        ])
    }

    // MARK: - Public state

    func setDeviceName(_ name: String) {
        deviceNameLabel.stringValue = name
    }

    func setControlState(_ state: WDAClient.State) {
        switch state {
        case .disconnected:
            controlDot.layer?.backgroundColor = NSColor.systemGray.cgColor
            controlButton.title = "Enable Control"
        case .connecting:
            controlDot.layer?.backgroundColor = NSColor.systemYellow.cgColor
            controlButton.title = "Connecting…"
        case .connected:
            controlDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            controlButton.title = "Control On"
        }
    }

    /// Resize the window to match new coded video dimensions, keeping aspect.
    func setVideoDimensions(width: Int, height: Int) {
        guard let window, width > 0, height > 0 else { return }
        videoView.videoSize = CGSize(width: width, height: height)
        let aspect = CGFloat(width) / CGFloat(height)
        let screenFrame = window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let targetHeight = min(screenFrame.height * 0.8, 780)
        let targetWidth = targetHeight * aspect
        window.contentAspectRatio = NSSize(width: aspect, height: 1)

        var frame = window.frame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        frame.size = NSSize(width: targetWidth, height: targetHeight)
        if window.isVisible {
            frame.origin = CGPoint(x: center.x - targetWidth / 2, y: center.y - targetHeight / 2)
            window.setFrame(frame, display: true, animate: true)
        } else {
            frame.origin = CGPoint(
                x: screenFrame.maxX - targetWidth - 48,
                y: screenFrame.midY - targetHeight / 2)
            window.setFrame(frame, display: true)
        }
    }

    func present() {
        guard let window, !window.isVisible else { return }
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
        window.makeFirstResponder(videoView)
    }

    func dismiss() {
        guard let window, window.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            window.animator().alphaValue = 0
        }, completionHandler: {
            window.orderOut(nil)
            window.alphaValue = 1
        })
    }

    // MARK: - Toolbar visibility

    override func mouseMoved(with event: NSEvent) {
        revealToolbar()
    }

    override func mouseExited(with event: NSEvent) {
        hideToolbar()
    }

    private func revealToolbar() {
        hideToolbarTimer?.invalidate()
        hideToolbarTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in
            self?.hideToolbar()
        }
        guard !toolbarVisible else { return }
        toolbarVisible = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            toolbar.animator().alphaValue = 1
        }
    }

    private func hideToolbar() {
        guard toolbarVisible else { return }
        toolbarVisible = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            toolbar.animator().alphaValue = 0
        }
    }

    // MARK: - Actions

    @objc private func controlTapped() {
        onControlToggle?()
    }

    @objc private func closeTapped() {
        onClose?()
    }

    /// Anchor view for popovers (e.g. the control-setup panel).
    var controlButtonAnchor: NSView { controlButton }
}
