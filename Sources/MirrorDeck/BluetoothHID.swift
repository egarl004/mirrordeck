import Foundation
import IOBluetooth

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
        let keep = DispatchSource.makeTimerSource(queue: queue)
        keep.schedule(deadline: .now() + 0.016, repeating: 0.016)
        var idleTicks = 0
        keep.setEventHandler { [weak self] in
            guard let self else { return }
            if self.pointerDirty {
                idleTicks = 0
                self.flushPointer()
                return
            }
            idleTicks += 1
            // iOS drops a HID link that goes quiet, so still report when idle.
            if idleTicks >= 19, self.currentButtons == 0 {
                idleTicks = 0
                self.sendPointer(buttons: 0, wheel: 0)
            }
        }
        keep.resume()
        keepAliveTimer = keep
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

    private func performDisconnect() {
        keepAliveTimer?.cancel(); keepAliveTimer = nil
        classOfDeviceTimer?.cancel(); classOfDeviceTimer = nil
        restoreClassOfDevice()
        interruptChannel?.close(); controlChannel?.close()
        interruptChannel = nil; controlChannel = nil
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
    func setPointer(x: Double, y: Double) {
        let cx = UInt16(max(0, min(32767, (x * 32767).rounded())))
        let cy = UInt16(max(0, min(32767, (y * 32767).rounded())))
        queue.async { [weak self] in
            guard let self else { return }
            guard cx != self.pointerX || cy != self.pointerY else { return }
            self.pointerX = cx
            self.pointerY = cy
            self.pointerDirty = true
        }
    }

    /// Called on `queue` by the report timer.
    private func flushPointer() {
        guard pointerDirty else { return }
        pointerDirty = false
        sendPointer(buttons: currentButtons, wheel: 0)
    }

    func setMouseButton(_ down: Bool, button: Int = 0) {
        let mask = UInt8(1 << button)
        currentButtons = down ? (currentButtons | mask) : (currentButtons & ~mask)
        sendPointer(buttons: currentButtons, wheel: 0)
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

    private func sendPointer(buttons: UInt8, wheel: Int8) {
        write([0xA1, 0x02, buttons,
               UInt8(pointerX & 0xFF), UInt8(pointerX >> 8),
               UInt8(pointerY & 0xFF), UInt8(pointerY >> 8),
               UInt8(bitPattern: wheel)])
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
        _ = IOBluetoothHostController.default()?.setClassOfDevice(0x0025C0, forTimeInterval: 120)
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
        _ = IOBluetoothHostController.default()?.setClassOfDevice(0x0025C0, forTimeInterval: 1)
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
            "0202 - HIDDeviceSubclass": int(0xC0, 1),      // keyboard + pointing
            "0203 - HIDCountryCode": int(0x21, 1),
            "0204 - HIDVirtualCable": flag(true),
            "0205 - HIDReconnectInitiate": flag(true),
            "0206 - HIDDescriptorList": [[int(0x22, 1), string(BluetoothHID.reportMap)]],
            "020D - HIDBootDevice": flag(false),
        ])
    }

    /// Keyboard on report ID 1, mouse on report ID 2.
    static let reportMap = Data([
        0x05,0x01, 0x09,0x06, 0xA1,0x01, 0x85,0x01,
        0x05,0x07, 0x19,0xE0, 0x29,0xE7, 0x15,0x00, 0x25,0x01, 0x75,0x01, 0x95,0x08, 0x81,0x02,
        0x95,0x01, 0x75,0x08, 0x81,0x03,
        0x95,0x06, 0x75,0x08, 0x15,0x00, 0x25,0x65, 0x05,0x07, 0x19,0x00, 0x29,0x65, 0x81,0x00,
        0xC0,
        0x05,0x01, 0x09,0x02, 0xA1,0x01, 0x85,0x02,
        0x09,0x01, 0xA1,0x00,
        0x05,0x09, 0x19,0x01, 0x29,0x03, 0x15,0x00, 0x25,0x01, 0x95,0x03, 0x75,0x01, 0x81,0x02,
        0x95,0x01, 0x75,0x05, 0x81,0x03,
        // Absolute pointer: 16-bit X/Y over 0...32767, Input(Data,Var,Abs).
        // iOS reads this descriptor when the device is paired and caches it, so
        // changing it requires forgetting the Mac on the phone and pairing again.
        0x05,0x01, 0x09,0x30, 0x09,0x31,
        0x16,0x00,0x00, 0x26,0xFF,0x7F, 0x75,0x10, 0x95,0x02, 0x81,0x02,
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
