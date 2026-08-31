import Foundation
import IOBluetooth
import ObjectiveC.runtime

/// Drives a paired iPhone as a Bluetooth keyboard and mouse.
///
/// This replaces WebDriverAgent for input: no Xcode, no developer account, no
/// test runner, and latency in milliseconds rather than XCUITest's ~500ms.
///
/// The order of operations is load-bearing and was expensive to find — see
/// spikes/bluetooth-keyboard/README.md. In short: an ordinary Mac↔iPhone bond
/// must already exist (pairing *as* a keyboard is impossible, because iOS asks
/// for a passkey typed on the keyboard); the class of device is set only after
/// that; the Mac opens the channels because the phone never will; and a report
/// must go out the instant the interrupt channel opens, since iOS drops an idle
/// HID link within about a second.

/// IOBluetooth's synchronous calls pump the caller's run loop, and its delegate
/// callbacks are delivered to one. A dispatch queue has no run loop: there
/// `openConnection()` burns the full page timeout and returns success with no
/// link, and inside NSApplication's own loop it returns instantly with the same
/// result. All Bluetooth work therefore runs on this thread.
private final class RunLoopThread {
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    init(name: String) {
        let thread = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            // A port keeps the loop alive with no other input sources attached.
            CFRunLoopAddSource(runLoop, CFMessagePortCreateRunLoopSource(
                nil, CFMessagePortCreateLocal(nil, "\(name).keepalive" as CFString, { _, _, _, _ in nil }, nil, nil), 0),
                .defaultMode)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = name
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    func async(_ block: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }
}


final class BluetoothHID: NSObject {
    enum State: Equatable {
        case idle
        case connecting
        case connected(deviceName: String)
        case failed(reason: String)
    }

    private(set) var state: State = .idle {
        didSet {
            if case .failed = state {
                classOfDeviceTimer?.cancel(); classOfDeviceTimer = nil
                restoreClassOfDevice()
            }
            let s = state
            DispatchQueue.main.async { [weak self] in self?.onStateChange?(s) }
        }
    }
    var onStateChange: ((State) -> Void)?

    private var serviceRecord: IOBluetoothSDPServiceRecord?
    private var incomingControl: IOBluetoothUserNotification?
    private var incomingInterrupt: IOBluetoothUserNotification?
    private var device: IOBluetoothDevice?
    private var controlChannel: IOBluetoothL2CAPChannel?
    private var interruptChannel: IOBluetoothL2CAPChannel?
    private var keepAliveTimer: DispatchSourceTimer?
    private var classOfDeviceTimer: DispatchSourceTimer?
    /// Every Bluetooth call runs here. They block, and the main thread cannot.
    private let queue = DispatchQueue(label: "mirrordeck.hid", qos: .userInteractive)
    private let btThread = RunLoopThread(name: "mirrordeck.bluetooth")
    /// Set as soon as the phone reaches us, so nudging stops immediately.
    private var phoneHasReachedUs = false
    private var linkTuned = false
    private var heldChannels: [IOBluetoothL2CAPChannel?] = []
    private var connectNote: IOBluetoothUserNotification?
    /// One outbound dial at a time. Each refused channel takes about eight
    /// seconds to time out and pins the main thread inside IOBluetooth's
    /// waitforChanneOpen while it does, so a backlog of them freezes the app
    /// long after the phone has actually connected.
    private var dialInFlight = false

    /// HID L2CAP PSMs.
    private let controlPSM: BluetoothL2CAPPSM = 0x0011
    private let interruptPSM: BluetoothL2CAPPSM = 0x0013

    // MARK: - Discovery

    /// Paired iPhones, for the user to choose from. The Bluetooth address is
    /// unrelated to the identifier AirPlay reports, so it has to come from here.
    static func pairedPhones() -> [(name: String, address: String)] {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return [] }
        var seen = Set<String>()
        return devices.compactMap { d -> (name: String, address: String)? in
            // Major class 0x02 is Phone.
            guard (d.deviceClassMajor == 0x02) || (d.name?.localizedCaseInsensitiveContains("iphone") ?? false),
                  let addr = d.addressString, seen.insert(addr).inserted else { return nil }
            // Show the address: stale bonds from earlier pairings look identical otherwise.
            return ("\(d.name ?? "iPhone")  (\(addr))", addr)
        }
    }

    /// Starts the keyboard advertisement and stays on for the app's lifetime.
    /// Pairing against the Mac while it presents as a plain computer produces a
    /// bond with no input service that fails forever after — advertising from
    /// launch makes step ordering impossible to get wrong.
    func beginAdvertising() {
        assertClassOfDevice()
        if classOfDeviceTimer == nil {
            let cod = DispatchSource.makeTimerSource(queue: queue)
            cod.schedule(deadline: .now() + 100, repeating: 100)
            cod.setEventHandler { [weak self] in self?.assertClassOfDevice() }
            cod.resume()
            classOfDeviceTimer = cod
        }
        publishServiceRecord()
        DebugLog.write("advertising from launch: record=\(serviceRecord != nil ? "published" : "FAILED")")
        listenForIncomingChannels()
        if connectNote == nil {
            connectNote = IOBluetoothDevice.register(forConnectNotifications: self,
                                                     selector: #selector(deviceConnected(_:device:)))
            DebugLog.write("registered for connect notifications")
        }
    }

    /// Fires the moment any device brings a link up. Polling isConnected() in
    /// this process never sees the phone's brief connection window — the state
    /// simply does not update in-process — so this notification is the only
    /// reliable trigger for our half of HIDReconnectInitiate: opening the
    /// channels while the phone is waiting for us.
    @objc private func deviceConnected(_ note: IOBluetoothUserNotification,
                                       device dev: IOBluetoothDevice) {
        // Deliberately does not dial. The phone opens both L2CAP channels
        // itself; dialling from here pins the main thread inside IOBluetooth's
        // waitforChanneOpen for ~8s per refusal, and because each SDP nudge
        // produces another connect notification it becomes a self-sustaining
        // freeze loop. Incoming channels are the only path that works.
        DebugLog.write("connect notification: \(dev.addressString?.lowercased() ?? "?")")
    }

    // MARK: - Connection

    func connect(toAddress address: String) {
        if case .connecting = state { return }   // one attempt at a time
        DebugLog.write("connect requested: \(address)")
        UserDefaults.standard.set(address, forKey: "lastPhoneAddress")
        state = .connecting
        btThread.async { [weak self] in self?.performConnect(address) }
        // Bluetooth calls can stall for a long time when the phone is asleep;
        // give up rather than leaving the UI reporting a connection forever.
        // Long: we are advertising and waiting for the phone to reach us, which
        // can take a while. Giving up early would drop the advertisement.
        // Ten minutes: pairing involves the user forgetting/re-adding on the
        // phone, and the keyboard disguise expiring mid-attempt makes iOS say
        // "pairing not supported" with no hint why. Turn Off in the menu is the
        // way to stop advertising deliberately.
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [weak self] in
            guard let self, case .connecting = self.state else { return }
            DebugLog.write("no incoming connection from the phone within 600s")
            self.state = .failed(reason: "The iPhone never connected. Tap the Mac in the phone's Bluetooth list.")
        }
    }

    private func performConnect(_ address: String) {
        guard let dev = IOBluetoothDevice(addressString: address) else {
            DebugLog.write("no IOBluetoothDevice for \(address)")
            state = .failed(reason: "No Bluetooth device at \(address)")
            return
        }
        DebugLog.write("device \(dev.name ?? "?") paired=\(dev.isPaired()) connected=\(dev.isConnected())")
        guard dev.isPaired() else {
            DebugLog.write("refusing: not paired")
            state = .failed(reason: "\(dev.name ?? "That iPhone") is not paired with this Mac")
            return
        }
        device = dev

        // Class of device first, then the service record. Publishing the HID
        // record while the Mac still claims to be a computer gets the control
        // channel refused; the phone judges us by the class it saw first.
        assertClassOfDevice()
        publishServiceRecord()
        DebugLog.write("service record: \(serviceRecord != nil ? "published" : "FAILED")")
        // The class of device setting is time-limited, so keep renewing it.
        let cod = DispatchSource.makeTimerSource(queue: queue)
        cod.schedule(deadline: .now() + 100, repeating: 100)
        cod.setEventHandler { [weak self] in self?.assertClassOfDevice() }
        cod.resume()
        classOfDeviceTimer = cod

        // openConnection blocks, so it stays off the main thread.
        // The synchronous openConnection() needs a run loop it can pump. On a
        // dispatch queue there is none, so it blocks for the full page timeout
        // and reports success without ever bringing the link up; inside
        // NSApplication's running loop it returns instantly with the same
        // result. The async form posts connectionComplete() to a run loop
        // instead, which is the only variant that works from inside an app.
        // Pure HID device role: advertise and wait. The phone is the host and
        // opens both L2CAP channels itself. Dialling out never worked —
        // openConnection() returns success without forming a link — and worse,
        // the resulting channel refusal set .failed, which restored the class of
        // device and tore down the very advertisement the phone was answering.
        phoneHasReachedUs = false
        beginAdvertising()
        btThread.async { [weak self] in self?.nudgeLink(dev, attempt: 0) }


        // Channel opening must happen on the main thread: IOBluetooth delivers
        // its delegate callbacks on a run loop, and a dispatch queue has none —
        // the calls succeed and l2capChannelOpenComplete is simply never sent.
        // Control first, and the interrupt channel only once control reports
        // OPEN. On a fixed timer the interrupt races ahead of control and the
        // phone refuses it with a bare kIOReturnError.

    }

    /// Repeatedly pokes the phone until it opens its channels to us. Stops the
    /// moment input goes live.
    private func nudgeLink(_ dev: IOBluetoothDevice, attempt: Int) {
        guard !phoneHasReachedUs, case .connecting = state else { return }
        guard attempt < 200 else { return }
        dev.performSDPQuery(nil)
        btThread.async { [weak self] in
            Thread.sleep(forTimeInterval: 3.0)
            self?.nudgeLink(dev, attempt: attempt + 1)
        }
    }

    /// Classic Bluetooth links drop into sniff mode to save power, waking only
    /// at the negotiated interval — which shows up as pointer lag no amount of
    /// report pacing can fix. A BLE mouse never suffers this, which is why one
    /// paired straight to the phone feels instant while our classic HID link
    /// does not. These are private IOBluetooth entry points, so each is probed
    /// before use and the app works fine without them.
    private func requestLowLatencyLink(_ dev: IOBluetoothDevice) {
        let highPower = Selector(("enableHighPower:"))
        if let m = class_getInstanceMethod(type(of: dev), highPower) {
            typealias Fn = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
            let imp = unsafeBitCast(method_getImplementation(m), to: Fn.self)
            imp(dev, highPower, true)
            DebugLog.write("link: enableHighPower(true)")
        } else {
            DebugLog.write("link: enableHighPower unavailable")
        }

        // Find the ACL connection handle: both HCI commands are addressed by it.
        var handle: UInt16 = 0
        for name in ["getConnectionHandle", "connectionHandle"] {
            let sel = Selector((name))
            guard let m = class_getInstanceMethod(type(of: dev), sel) else { continue }
            typealias HFn = @convention(c) (AnyObject, Selector) -> UInt16
            handle = unsafeBitCast(method_getImplementation(m), to: HFn.self)(dev, sel)
            DebugLog.write("link: \(name) -> 0x\(String(handle, radix: 16))")
            break
        }
        guard handle != 0, handle != 0xFFFF, let host = IOBluetoothHostController.default() else {
            DebugLog.write("link: no usable connection handle yet")
            return
        }
        linkTuned = true

        // Link policy 0x0000 forbids sniff, hold and park, so the controller
        // cannot park the link between reports. This is the setting that keeps
        // a classic HID link responsive; BLE mice avoid the problem entirely.
        let writePolicy = Selector(("BluetoothHCIWriteLinkPolicySettings:inLinkPolicySettings:"))
        if let m = class_getInstanceMethod(type(of: host), writePolicy) {
            typealias PFn = @convention(c) (AnyObject, Selector, UInt16, UInt16) -> Int32
            let rc = unsafeBitCast(method_getImplementation(m), to: PFn.self)(host, writePolicy, handle, 0)
            DebugLog.write("link: writeLinkPolicySettings(0) -> \(rc)")
        }

        // And leave sniff now, in case the link is already parked.
        let exitSniff = Selector(("BluetoothHCIExitSniffMode:outModeChangeResults:"))
        if let m = class_getInstanceMethod(type(of: host), exitSniff) {
            var results = [UInt8](repeating: 0, count: 128)
            typealias EFn = @convention(c) (AnyObject, Selector, UInt16, UnsafeMutableRawPointer) -> Int32
            let fn = unsafeBitCast(method_getImplementation(m), to: EFn.self)
            let rc = results.withUnsafeMutableBytes { fn(host, exitSniff, handle, $0.baseAddress!) }
            DebugLog.write("link: exitSniffMode -> \(rc)")
        }

        // HIDQoSLatency, HIDSSRHostMaxLatency and connectionModeInterval return
        // scalars, not objects. Reading them through perform() makes the
        // runtime treat an integer as an object pointer and crashes, so they
        // are left alone — they are informational anyway.
    }

    /// Called when the phone opens the interrupt channel to us.
    private func activateInterrupt(_ channel: IOBluetoothL2CAPChannel) {
        guard interruptChannel !== channel else { return }
        interruptChannel = channel
        dialInFlight = false
        // Drop dials still in flight: their refusals would otherwise keep
        // stalling the main thread for tens of seconds after input is live.
        for pending in heldChannels {
            guard let pending, pending !== channel, pending !== controlChannel else { continue }
            pending.close()
        }
        heldChannels.removeAll()
        // Send immediately: iOS closes a HID link that stays idle, and every
        // write afterwards fails with an unhelpful generic error.
        sendPointer(buttons: 0, wheel: 0)
        // Tunable while we chase pointer latency:
        //   defaults write com.emersongarland.MirrorDeck pointerIntervalMs -float 25
        // Absolute positions mean a slower rate loses nothing: each report
        // carries the current cursor position, so skipped ones are redundant.
        var intervalMs = UserDefaults.standard.double(forKey: "pointerIntervalMs")
        if intervalMs <= 0 { intervalMs = 8 }
        reportIntervalMs = intervalMs
        DebugLog.write(String(format: "pointer interval: %.1fms (%.0f/s)",
                              intervalMs, 1000 / intervalMs))
        let keep = DispatchSource.makeTimerSource(queue: queue)
        keep.schedule(deadline: .now() + intervalMs / 1000,
                      repeating: intervalMs / 1000, leeway: .milliseconds(1))
        var idleTicks = 0
        keep.setEventHandler { [weak self] in
            guard let self else { return }
            self.ticksSinceInput += 1
            self.ticksSinceSend += 1
            if self.pointerDirty {
                idleTicks = 0
                self.flushPointer()
                return
            }
            idleTicks += 1
            // While a button is held, keep restating it. A single down report
            // followed by silence reads as a momentary blip — the pointer
            // flinches and nothing else happens — because a real mouse reports
            // its button state continuously for as long as it is held.
            // iOS drops a HID link that goes quiet, so still report when idle —
            // but never while a button is held.
            if Double(idleTicks) * intervalMs >= 300, self.currentButtons == 0 {
                idleTicks = 0
                if self.useRelative { self.sendRelative(buttons: 0, dx: 0, dy: 0, wheel: 0) }
                else { self.sendPointer(buttons: 0, wheel: 0) }
            }
        }
        keep.resume()
        keepAliveTimer = keep
        // The connection handle is not populated the instant the channel opens,
        // so retry briefly. channel.device is the object bound to the live
        // connection; ours, built from an address, may never carry a handle.
        let candidates = [channel.device, device].compactMap { $0 }
        DebugLog.write("link: channel.device=\(channel.device != nil) candidates=\(candidates.count)")
        for delay in [0.0, 1.0, 3.0] {
            btThread.async { [weak self] in
                Thread.sleep(forTimeInterval: delay)
                guard let self, !self.linkTuned else { return }
                for dev in candidates { self.requestLowLatencyLink(dev) }
            }
        }
        DebugLog.write("HID interrupt channel open — input is live")
        state = .connected(deviceName: device?.name ?? "iPhone")
    }

    /// This is the connection path. The Mac advertises as a keyboard and the
    /// phone, acting as HID host, opens both L2CAP channels to us. Dialling out
    /// from the Mac not only never works, it races these channels and can
    /// replace a live one with a dead channel, silently swallowing all input.
    private func listenForIncomingChannels() {
        guard incomingControl == nil else { return }
        incomingControl = IOBluetoothL2CAPChannel.register(
            forChannelOpenNotifications: self,
            selector: #selector(incomingChannel(_:channel:)),
            withPSM: controlPSM,
            direction: kIOBluetoothUserNotificationChannelDirectionIncoming)
        incomingInterrupt = IOBluetoothL2CAPChannel.register(
            forChannelOpenNotifications: self,
            selector: #selector(incomingChannel(_:channel:)),
            withPSM: interruptPSM,
            direction: kIOBluetoothUserNotificationChannelDirectionIncoming)
        DebugLog.write("listening for incoming HID channels from the phone")
    }

    @objc private func incomingChannel(_ note: IOBluetoothUserNotification,
                                       channel: IOBluetoothL2CAPChannel) {
        DebugLog.write("INCOMING channel from phone PSM 0x\(String(channel.psm, radix: 16))")
        phoneHasReachedUs = true
        channel.setDelegate(self)
        if channel.psm == controlPSM { controlChannel = channel }
        if channel.psm == interruptPSM { activateInterrupt(channel) }
    }

    func disconnect() {
        queue.async { [weak self] in self?.performDisconnect() }
    }

    /// Synchronous teardown, for application termination. `disconnect()` is
    /// asynchronous and never completes when the process is exiting, which
    /// leaves the HID service record published inside bluetoothd. A stale
    /// record breaks the *next* pairing attempt — the phone sees leftover
    /// services from a process that no longer exists — and only a bluetoothd
    /// restart clears it, which needs an admin password.
    func shutdownSynchronously() {
        // Unregister first: these fire on the run loop and would otherwise
        // deliver callbacks into a half-torn-down object.
        incomingControl?.unregister(); incomingControl = nil
        incomingInterrupt?.unregister(); incomingInterrupt = nil
        connectNote?.unregister(); connectNote = nil

        let done = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            self?.performDisconnect()
            done.signal()
        }
        // Bounded: a stalled Bluetooth call must not hold up quitting.
        if done.wait(timeout: .now() + 2) == .timedOut {
            DebugLog.write("shutdown timed out — record may be left published")
        } else {
            DebugLog.write("clean shutdown: channels closed, record removed")
        }
    }

    private func performDisconnect() {
        keepAliveTimer?.cancel(); keepAliveTimer = nil
        classOfDeviceTimer?.cancel(); classOfDeviceTimer = nil
        restoreClassOfDevice()
        interruptChannel?.close(); controlChannel?.close()
        interruptChannel = nil; controlChannel = nil
        // Channels opened but never completed still hold the PSMs.
        for pending in heldChannels { pending?.close() }
        heldChannels.removeAll()
        dialInFlight = false
        phoneHasReachedUs = false
        serviceRecord?.remove(); serviceRecord = nil
        device?.closeConnection()
        device = nil
        state = .idle
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    // MARK: - Input

    /// Relative pointer movement, as a physical mouse reports it. Clamped to the
    /// single signed byte the report allows; larger moves are split by the caller.
    /// Flushed once per frame by the report timer. Sending a report per mouse
    /// event floods the serial write queue — every writeSync waits for the phone
    /// to acknowledge — and the backlog reads as lag.

    /// `x` and `y` are normalised 0...1 within the mirrored image.
    /// Deltas for relative mode, accumulated so sub-pixel movement is not lost.
    func movePointer(dx: Double, dy: Double) {
        queue.async { [weak self] in
            guard let self, self.interruptChannel != nil else { return }
            self.pendingDx += dx
            self.pendingDy += dy
            var sx = self.pendingDx.rounded(.towardZero)
            var sy = self.pendingDy.rounded(.towardZero)
            guard sx != 0 || sy != 0 else { return }
            self.pendingDx -= sx
            self.pendingDy -= sy
            // Split anything beyond one report's range; sub-pixel remainder is
            // carried so slow movement is not lost to rounding.
            while sx != 0 || sy != 0 {
                let stepX = max(-127, min(127, sx))
                let stepY = max(-127, min(127, sy))
                self.sendRelative(buttons: self.currentButtons,
                                  dx: Int8(stepX), dy: Int8(stepY), wheel: 0)
                sx -= stepX
                sy -= stepY
            }
        }
    }

    private func sendRelative(buttons: UInt8, dx: Int8, dy: Int8, wheel: Int8) {
        write([0xA1, 0x03, buttons,
               UInt8(bitPattern: dx), UInt8(bitPattern: dy), UInt8(bitPattern: wheel)])
    }

    /// Drives the pointer to an absolute position using relative reports,
    /// which is the only mode iOS actually supports.
    func moveToNormalized(x: Double, y: Double) {
        queue.async { [weak self] in
            guard let self, self.interruptChannel != nil else { return }
            if !self.anchored { self.performAnchor() }

            // Every report carries an identical delta. iOS applies pointer
            // acceleration as a function of delta magnitude, so holding the
            // magnitude constant makes each report travel the same distance
            // whatever the speed — the mapping becomes linear and depends only
            // on how many reports are sent, not how fast the mouse moved.
            let step = Self.stepMagnitude
            // Reports needed to cross the screen. The one calibrated constant:
            //   defaults write com.emersongarland.MirrorDeck stepsPerScreen -float 80
            var perScreen = UserDefaults.standard.double(forKey: "stepsPerScreen")
            if perScreen <= 0 { perScreen = 80 }

            // Work in whole steps so position is always an exact multiple.
            let wantX = (x * perScreen).rounded()
            let wantY = (y * perScreen).rounded()
            var haveX = (self.believedX * perScreen).rounded()
            var haveY = (self.believedY * perScreen).rounded()

            while haveX != wantX || haveY != wantY {
                let dx = haveX < wantX ? step : (haveX > wantX ? -step : 0)
                let dy = haveY < wantY ? step : (haveY > wantY ? -step : 0)
                self.sendRelative(buttons: self.currentButtons,
                                  dx: Int8(dx), dy: Int8(dy), wheel: 0)
                if dx > 0 { haveX += 1 } else if dx < 0 { haveX -= 1 }
                if dy > 0 { haveY += 1 } else if dy < 0 { haveY -= 1 }
            }
            self.believedX = wantX / perScreen
            self.believedY = wantY / perScreen
        }
    }

    /// Fixed for every report, so acceleration contributes a constant factor.
    static let stepMagnitude = 12

    /// Pins the pointer into the top-left corner so its position is known.
    private func performAnchor() {
        // Anchor with the same step magnitude, enough of them to cross the
        // screen several times over so the pointer is certainly pinned.
        for _ in 0..<400 {
            sendRelative(buttons: currentButtons,
                         dx: Int8(-Self.stepMagnitude), dy: Int8(-Self.stepMagnitude), wheel: 0)
        }
        believedX = 0
        believedY = 0
        anchored = true
        DebugLog.write("pointer anchored to (0,0)")
    }

    /// Emit a raw relative delta, for calibration probes.
    func nudgeUnits(dx: Int, dy: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            var rx = dx, ry = dy
            while rx != 0 || ry != 0 {
                let sx = max(-100, min(100, rx))
                let sy = max(-100, min(100, ry))
                self.sendRelative(buttons: 0, dx: Int8(sx), dy: Int8(sy), wheel: 0)
                rx -= sx; ry -= sy
                Thread.sleep(forTimeInterval: 0.008)
            }
        }
    }

    /// Anchor synchronously, for calibration.
    func anchorNow() {
        queue.sync { self.performAnchor() }
    }

    /// Called when the cursor re-enters the mirror, so error cannot accumulate.
    func reanchor() {
        queue.async { [weak self] in self?.anchored = false }
    }

    func setPointer(x: Double, y: Double) {
        let cx = UInt16(max(0, min(32767, (x * 32767).rounded())))
        let cy = UInt16(max(0, min(32767, (y * 32767).rounded())))
        queue.async { [weak self] in
            guard let self else { return }
            guard cx != self.pointerX || cy != self.pointerY else { return }
            self.pointerX = cx
            self.pointerY = cy
            self.pointerDirty = true
            self.ticksSinceInput = 0
        }
    }

    /// Called on `queue` by the report timer.
    private func flushPointer() {
        guard pointerDirty else { return }
        if !useRelative {
            // Distance travelled since the last report, in report units.
            let moved = max(abs(Int(pointerX) - Int(lastSentX)),
                            abs(Int(pointerY) - Int(lastSentY)))
            // Settled: the cursor has stopped, so send the exact final position
            // even if it is a tiny move — otherwise the pointer parks slightly
            // off from where the cursor actually is.
            // Time-based, and deliberately not tiny: during slow movement the
            // quantised position can hold still for a couple of ticks while the
            // cursor is plainly still moving, and a short window reads that as
            // a stop — which is why snap mode still published in transit.
            var settleMs = UserDefaults.standard.double(forKey: "pointerSettleMs")
            if settleMs <= 0 { settleMs = 50 }
            let settled = Double(ticksSinceInput) * reportIntervalMs >= settleMs
            var threshold = UserDefaults.standard.integer(forKey: "pointerThreshold")
            if threshold <= 0 { threshold = 250 }        // ~0.8% of the screen

            // Transit heartbeat: while the cursor is still moving, force the
            // current position out at a slow fixed rate. Enough to show where
            // the pointer is heading, slow enough that the phone never builds
            // the backlog that makes it replay the path after you stop.
            var transitMs = UserDefaults.standard.double(forKey: "pointerTransitMs")
            if transitMs <= 0 { transitMs = 120 }
            let transitDue = Double(ticksSinceSend) * reportIntervalMs >= transitMs

            // Distance alone is not enough: the same path swept quickly
            // produces the same number of reports in a fraction of the time,
            // which is what refills the queue. So a distance-triggered report
            // must also respect a minimum gap, capping the burst rate while
            // still letting slow movement update as it accumulates distance.
            var minGapMs = UserDefaults.standard.double(forKey: "pointerMinGapMs")
            if minGapMs <= 0 { minGapMs = 30 }
            let gapOK = Double(ticksSinceSend) * reportIntervalMs >= minGapMs

            guard settled || transitDue || (moved >= threshold && gapOK) else { return }
            ticksSinceSend = 0
            lastSentX = pointerX
            lastSentY = pointerY
        }
        pointerDirty = false
        guard useRelative else {
            sendPointer(buttons: currentButtons, wheel: 0)
            return
        }
        let stepX = max(-127, min(127, Int(pendingDx)))
        let stepY = max(-127, min(127, Int(pendingDy)))
        pendingDx -= Double(stepX)
        pendingDy -= Double(stepY)
        sendRelative(buttons: currentButtons, dx: Int8(stepX), dy: Int8(stepY), wheel: 0)
    }

    /// iOS ignores the button bits on an absolute pointer report — proven
    /// across several descriptors, both button indices and every plausible
    /// timing. But AssistiveTouch's **Mouse Keys** performs a click wherever
    /// the pointer currently is, and it is driven from the *keyboard*, which
    /// this device already does correctly. So movement stays on the absolute
    /// pointer report and the click travels as a keystroke.
    ///
    /// Requires on the phone: Settings → Accessibility → Touch →
    /// AssistiveTouch → Mouse Keys (on). If a "Use Primary Keyboard" sub-toggle
    /// is present, turn it off so Mouse Keys does not swallow the letter keys
    /// and ordinary typing keeps working alongside it.
    func setMouseButton(_ down: Bool, button: Int = 0) {
        let mask = UInt8(1 << button)
        currentButtons = down ? (currentButtons | mask) : (currentButtons & ~mask)

        if useMouseKeys {
            // Keypad 0 holds the button, Keypad . releases it — so this covers
            // press-and-hold and drag, not just a tap.
            // Two key sets exist. With AssistiveTouch's "Use Primary Keyboard"
            // OFF, Mouse Keys listens on the keypad; with it ON, it listens on
            // the letter keys instead. Which one is live is a phone setting, so
            // it is selectable here rather than guessed:
            //   defaults write com.emersongarland.MirrorDeck mouseKeysLetters -bool true
            // A discrete click on release, rather than a hold/release pair.
            // Keypad 5 is Mouse Keys' plain "click"; the hold/release codes are
            // for dragging and are the more exotic path.
            guard !down else { return }
            let letters = UserDefaults.standard.bool(forKey: "mouseKeysLetters")
            let usage: UInt8 = letters ? 0x0C : 0x5D    // I, or Keypad 5
            sendKeyboard(modifiers: 0, usage: usage)
            sendKeyboard(modifiers: 0, usage: 0)
            DebugLog.write("mouse-keys click usage=0x\(String(usage, radix: 16)) at (\(pointerX),\(pointerY))")
            return
        }

        sendRelative(buttons: currentButtons, dx: 0, dy: 0, wheel: 0)
        DebugLog.write(down ? "DOWN buttons=\(currentButtons)" : "UP buttons=\(currentButtons)")
    }

    private lazy var useMouseKeys = UserDefaults.standard.bool(forKey: "useMouseKeys")

    /// Single click via Mouse Keys (Keypad 5), for cases where a discrete tap
    /// is wanted rather than a hold/release pair.
    /// Diagnostic: hold Mouse Keys' "move up" key (Keypad 8) for a second.
    /// If Mouse Keys is actually attached to this device the pointer drifts
    /// upward; if an "8" is typed, or nothing happens, no accessibility
    /// keyboard filter is attached and Mouse Keys can never work here.
    func testMouseKeysMovement() {
        queue.async { [weak self] in
            guard let self else { return }
            DebugLog.write("mouse-keys test: holding Keypad 8 for 1s")
            for _ in 0..<50 {
                self.sendKeyboard(modifiers: 0, usage: 0x60)   // Keypad 8 = up
                Thread.sleep(forTimeInterval: 0.02)
            }
            self.sendKeyboard(modifiers: 0, usage: 0)
            DebugLog.write("mouse-keys test: released")
        }
    }

    func mouseKeysClick() {
        let letters = UserDefaults.standard.bool(forKey: "mouseKeysLetters")
        pressKey(letters ? 0x0C : 0x5D)     // I, or Keypad 5
        DebugLog.write("mouse-keys click (kp5) at (\(pointerX),\(pointerY))")
    }

    func scroll(_ amount: Int) {
        var remaining = amount
        while remaining != 0 {
            let step = max(-127, min(127, remaining))
            sendPointer(buttons: currentButtons, wheel: Int8(step))
            remaining -= step
        }
    }

    /// One keypress. `usage` is a USB HID keyboard usage ID.
    func pressKey(_ usage: UInt8, modifiers: UInt8 = 0) {
        sendKeyboard(modifiers: modifiers, usage: usage)
        sendKeyboard(modifiers: 0, usage: 0)
    }

    private var currentButtons: UInt8 = 0

    /// Absolute position, 0...32767 on each axis. Starts centred so the first
    /// report cannot fling the pointer into a corner.
    private var pointerX: UInt16 = 16384
    private var pointerY: UInt16 = 16384
    private var pointerDirty = false
    /// Last position actually sent, and how many timer ticks since the cursor
    /// last moved. Absolute reports make every intermediate position
    /// redundant: only a move large enough to see, or the final position once
    /// the cursor comes to rest, is worth a report. Sending the rest just
    /// fills a queue the phone then has to walk through.
    private var lastSentX: UInt16 = 0
    private var lastSentY: UInt16 = 0
    private var ticksSinceInput = 0
    /// Where we believe the phone's pointer is, in normalised 0...1 screen
    /// units. Relative reports carry no origin, so this is reconstructed by
    /// anchoring: the pointer pins at the screen edges, so a burst of large
    /// negative deltas puts it at a known (0,0).
    private var believedX = 0.0
    private var believedY = 0.0
    private var anchored = false
    /// Ticks since a report actually went out, and the timer period, so the
    /// transit heartbeat can be expressed in milliseconds.
    private var ticksSinceSend = 0
    private var buttonDownAt: Date?
    private var heldReports = 0
    private var reportIntervalMs = 8.0
    /// Relative mode sends deltas (report 3) instead of positions (report 2):
    ///   defaults write com.emersongarland.MirrorDeck pointerRelative -bool true
    private lazy var useRelative =
        UserDefaults.standard.bool(forKey: "pointerRelative")
    private var pendingDx = 0.0
    private var pendingDy = 0.0

    /// Touch report: tip down or up at an absolute position.
    private func sendTouch(down: Bool) {
        write([0xA1, 0x04, down ? 1 : 0,
               UInt8(pointerX & 0xFF), UInt8(pointerX >> 8),
               UInt8(pointerY & 0xFF), UInt8(pointerY >> 8)])
    }

    private lazy var useDigitizer =
        UserDefaults.standard.bool(forKey: "useDigitizer")

    private func sendPointer(buttons: UInt8, wheel: Int8) {
        // Movement always goes out as an absolute mouse report so the pointer
        // stays visible. The digitizer is used only for taps.
        if useDigitizer, currentButtons != 0 {
            // Keep the touch down and tracking while a drag is in progress.
            sendTouch(down: true)
        }
        write([0xA1, 0x02, buttons,
               UInt8(pointerX & 0xFF), UInt8(pointerX >> 8),
               UInt8(pointerY & 0xFF), UInt8(pointerY >> 8)])
        // Scrolling moved to the relative report, which still has a wheel.
        if wheel != 0 {
            sendRelative(buttons: buttons, dx: 0, dy: 0, wheel: wheel)
        }
    }

    private func sendKeyboard(modifiers: UInt8, usage: UInt8) {
        write([0xA1, 0x01, modifiers, 0x00, usage, 0, 0, 0, 0])
    }

    /// 0xA1 is the HIDP header: DATA | INPUT.
    private func write(_ bytes: [UInt8]) {
        queue.async { [weak self] in
            guard let channel = self?.interruptChannel else {
                DebugLog.write("write dropped — no interrupt channel")
                return
            }
            var packet = bytes
            _ = packet.withUnsafeMutableBytes {
                channel.writeSync($0.baseAddress!, length: UInt16($0.count))
            }
        }
    }

    // MARK: - Advertising

    private func assertClassOfDevice() {
        // 0x0025C0: peripheral major class, keyboard + pointing minor class.
        // The getter always reads 0x0, so this cannot be verified directly.
        _ = IOBluetoothHostController.default()?.setClassOfDevice(0x002540, forTimeInterval: 120)
    }

    /// Hand the Mac's real identity back. While it claims to be a keyboard,
    /// iOS reports it as unsupported and refuses to pair, so this must run on
    /// every path out or the Mac is left unusable for ordinary pairing.
    ///
    /// There is no API to clear an override, and writing a literal laptop class
    /// here means guessing a value — an earlier guess left the Mac advertising a
    /// class that was not its own. Instead re-assert the keyboard class for one
    /// second: when a timed override expires the controller reverts to the value
    /// macOS actually owns, so nothing has to be guessed.
    private func restoreClassOfDevice() {
        _ = IOBluetoothHostController.default()?.setClassOfDevice(0x002540, forTimeInterval: 1)
    }

    private func publishServiceRecord() {
        guard serviceRecord == nil else { return }
        func uuid(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xff)]) }
        func int(_ v: Int, _ size: Int) -> [String: Any] {
            ["DataElementType": 1, "DataElementSize": size, "DataElementValue": v]
        }
        func flag(_ v: Bool) -> [String: Any] {
            ["DataElementType": 5, "DataElementSize": 1, "DataElementValue": v ? 1 : 0]
        }
        // The report map must be a text-string element; raw Data is rejected.
        func string(_ d: Data) -> [String: Any] {
            ["DataElementType": 4, "DataElementSize": d.count, "DataElementValue": d]
        }

        // Kept deliberately minimal. A record carrying the optional attributes
        // (0006, 0200, 0201, 0207) publishes without complaint, but the phone
        // then refuses the control channel with a bare kIOReturnError. These are
        // exactly the attributes the working spike omits.
        serviceRecord = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: [
            // UUIDs are raw Data here, not element dictionaries.
            "0001 - ServiceClassIDList": [uuid(0x1124)],
            "0004 - ProtocolDescriptorList": [[uuid(0x0100), int(0x0011, 2)], [uuid(0x0011)]],
            "0005 - BrowseGroupList*": [uuid(0x1002)],
            "0009 - BluetoothProfileDescriptorList*": [[uuid(0x1124), int(0x0100, 2)]],
            "000D - AdditionalProtocolDescriptorList*": [[[uuid(0x0100), int(0x0013, 2)], [uuid(0x0011)]]],
            "0100 - ServiceName*": "MirrorDeck Input",
            "0202 - HIDDeviceSubclass": int(0x40, 1),      // keyboard + pointing
            "0203 - HIDCountryCode": int(0x21, 1),
            "0204 - HIDVirtualCable": flag(true),
            "0205 - HIDReconnectInitiate": flag(true),
            "0206 - HIDDescriptorList": [[int(0x22, 1), string(BluetoothHID.reportMap)]],
            "020D - HIDNormallyConnectable": flag(true),
            "020E - HIDBootDevice": flag(false),
        ])
    }

    /// Keyboard on report ID 1, mouse on report ID 2.
    static let reportMap = Data([
        0x05,0x01, 0x09,0x06, 0xA1,0x01, 0x85,0x01,
        0x05,0x07, 0x19,0xE0, 0x29,0xE7, 0x15,0x00, 0x25,0x01, 0x75,0x01, 0x95,0x08, 0x81,0x02,
        0x95,0x01, 0x75,0x08, 0x81,0x03,
        0x95,0x06, 0x75,0x08, 0x15,0x00, 0x25,0x65, 0x05,0x07, 0x19,0x00, 0x29,0x65, 0x81,0x00,
        // LED output report (Num/Caps/Scroll/Compose/Kana) + padding.
        0x95,0x05, 0x75,0x01, 0x05,0x08, 0x19,0x01, 0x29,0x05, 0x91,0x02,
        0x95,0x01, 0x75,0x03, 0x91,0x03,
        0xC0,
        // Absolute pointer, report ID 2. Structure copied from a descriptor
        // reported working on iPad: buttons are declared at the *application*
        // level and the Physical collection wraps only X/Y. Our previous
        // version opened the Physical collection first and nested the buttons
        // inside it, which iOS parsed for coordinates but not for buttons.
        // Two buttons and no wheel, matching that descriptor exactly; scrolling
        // uses the relative mouse report instead.
        0x05,0x01, 0x09,0x02, 0xA1,0x01, 0x85,0x02,
        0x05,0x09, 0x19,0x01, 0x29,0x02, 0x15,0x00, 0x25,0x01,
        0x95,0x02, 0x75,0x01, 0x81,0x02,
        0x95,0x01, 0x75,0x06, 0x81,0x03,
        0x05,0x01, 0x09,0x01, 0xA1,0x00,
        0x15,0x00, 0x26,0xFF,0x7F, 0x09,0x30, 0x09,0x31,
        0x75,0x10, 0x95,0x02, 0x81,0x02,
        0xC0,
        0xC0,
        // Relative mouse, report ID 3.
        0x05,0x01, 0x09,0x02, 0xA1,0x01, 0x85,0x03,
        0x09,0x01, 0xA1,0x00,
        0x05,0x09, 0x19,0x01, 0x29,0x03, 0x15,0x00, 0x25,0x01, 0x95,0x03, 0x75,0x01, 0x81,0x02,
        0x95,0x01, 0x75,0x05, 0x81,0x03,
        0x05,0x01, 0x09,0x30, 0x09,0x31, 0x15,0x81, 0x25,0x7F, 0x75,0x08, 0x95,0x02, 0x81,0x06,
        0x09,0x38, 0x15,0x81, 0x25,0x7F, 0x75,0x08, 0x95,0x01, 0x81,0x06,
        0xC0, 0xC0,
        ])
}

// MARK: - Channel delegate

extension BluetoothHID: IOBluetoothL2CAPChannelDelegate {
    @objc func l2capChannelOpenComplete(_ channel: IOBluetoothL2CAPChannel!, status error: IOReturn) {
        DebugLog.write("channel PSM 0x\(String(channel.psm, radix: 16)) status=\(error)")
        guard error == kIOReturnSuccess else {
            // Stay in .connecting: .failed restores the class of device and drops
            // the advertisement the phone is trying to reach.
            dialInFlight = false
            DebugLog.write("channel refused — still advertising")
            return
        }
        // Never dial the interrupt channel: the phone opens it itself, and any
        // outbound open blocks the main thread in waitforChanneOpen for seconds.
        if channel.psm == controlPSM { controlChannel = channel }
        if channel.psm == interruptPSM { activateInterrupt(channel) }
    }



    @objc func l2capChannelClosed(_ channel: IOBluetoothL2CAPChannel!) {
        if channel.psm == interruptPSM {
            keepAliveTimer?.cancel(); keepAliveTimer = nil
            interruptChannel = nil
            if isConnected {
                DebugLog.write("HID channel closed by the phone")
                state = .failed(reason: "The iPhone closed the input connection")
            }
        }
        if channel.psm == controlPSM { controlChannel = nil }
    }
}
