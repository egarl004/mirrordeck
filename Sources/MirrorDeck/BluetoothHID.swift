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
    private var device: IOBluetoothDevice?
    private var controlChannel: IOBluetoothL2CAPChannel?
    private var interruptChannel: IOBluetoothL2CAPChannel?
    private var keepAliveTimer: DispatchSourceTimer?
    private var classOfDeviceTimer: DispatchSourceTimer?
    /// Every Bluetooth call runs here. They block, and the main thread cannot.
    private let queue = DispatchQueue(label: "mirrordeck.hid", qos: .userInteractive)

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

    // MARK: - Connection

    func connect(toAddress address: String) {
        if case .connecting = state { return }   // one attempt at a time
        DebugLog.write("connect requested: \(address)")
        state = .connecting
        queue.async { [weak self] in self?.performConnect(address) }
        // Bluetooth calls can stall for a long time when the phone is asleep;
        // give up rather than leaving the UI reporting a connection forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, case .connecting = self.state else { return }
            DebugLog.write("connect timed out")
            self.state = .failed(reason: "The iPhone did not accept the connection. Is it unlocked?")
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

        publishServiceRecord()
        DebugLog.write("service record: \(serviceRecord != nil ? "published" : "FAILED")")
        assertClassOfDevice()
        // The class of device setting is time-limited, so keep renewing it.
        let cod = DispatchSource.makeTimerSource(queue: queue)
        cod.schedule(deadline: .now() + 100, repeating: 100)
        cod.setEventHandler { [weak self] in self?.assertClassOfDevice() }
        cod.resume()
        classOfDeviceTimer = cod

        // openConnection blocks, so it stays off the main thread.
        let opened = dev.openConnection()
        DebugLog.write("openConnection -> \(opened)")
        guard opened == kIOReturnSuccess else {
            state = .failed(reason: "Could not reach \(dev.name ?? "the iPhone"). Is it awake and in range?")
            return
        }
        // Channel opening must happen on the main thread: IOBluetooth delivers
        // its delegate callbacks on a run loop, and a dispatch queue has none —
        // the calls succeed and l2capChannelOpenComplete is simply never sent.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Stagger the two channels. Opening both at once does not work;
            // HID expects control to come up first, then interrupt.
            var control: IOBluetoothL2CAPChannel?
            let rc = dev.openL2CAPChannelAsync(&control, withPSM: self.controlPSM, delegate: self)
            self.controlChannel = control
            DebugLog.write("openL2CAP control -> \(rc)")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                var interrupt: IOBluetoothL2CAPChannel?
                let ri = dev.openL2CAPChannelAsync(&interrupt, withPSM: self.interruptPSM, delegate: self)
                self.interruptChannel = interrupt
                DebugLog.write("openL2CAP interrupt -> \(ri)")
            }
        }
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
    func movePointer(dx: Int, dy: Int) {
        var remainingX = dx, remainingY = dy
        while remainingX != 0 || remainingY != 0 {
            let stepX = max(-127, min(127, remainingX))
            let stepY = max(-127, min(127, remainingY))
            sendMouse(buttons: currentButtons, dx: Int8(stepX), dy: Int8(stepY), wheel: 0)
            remainingX -= stepX; remainingY -= stepY
        }
    }

    func setMouseButton(_ down: Bool, button: Int = 0) {
        let mask = UInt8(1 << button)
        currentButtons = down ? (currentButtons | mask) : (currentButtons & ~mask)
        sendMouse(buttons: currentButtons, dx: 0, dy: 0, wheel: 0)
    }

    func scroll(_ amount: Int) {
        var remaining = amount
        while remaining != 0 {
            let step = max(-127, min(127, remaining))
            sendMouse(buttons: currentButtons, dx: 0, dy: 0, wheel: Int8(step))
            remaining -= step
        }
    }

    /// One keypress. `usage` is a USB HID keyboard usage ID.
    func pressKey(_ usage: UInt8, modifiers: UInt8 = 0) {
        sendKeyboard(modifiers: modifiers, usage: usage)
        sendKeyboard(modifiers: 0, usage: 0)
    }

    private var currentButtons: UInt8 = 0

    private func sendMouse(buttons: UInt8, dx: Int8, dy: Int8, wheel: Int8) {
        write([0xA1, 0x02, buttons,
               UInt8(bitPattern: dx), UInt8(bitPattern: dy), UInt8(bitPattern: wheel)])
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

    /// Put the Mac back to a laptop. While it claims to be a keyboard, phones
    /// refuse to pair with it at all — iOS reports it as unsupported — so this
    /// must run on every path out, or the feature leaves the Mac unusable for
    /// ordinary Bluetooth pairing.
    private func restoreClassOfDevice() {
        _ = IOBluetoothHostController.default()?.setClassOfDevice(0x38010C, forTimeInterval: 1)
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

        serviceRecord = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: [
            // UUIDs are raw Data here, not element dictionaries.
            "0001 - ServiceClassIDList": [uuid(0x1124)],
            "0004 - ProtocolDescriptorList": [[uuid(0x0100), int(0x0011, 2)], [uuid(0x0011)]],
            "0005 - BrowseGroupList*": [uuid(0x1002)],
            "0006 - LanguageBaseAttributeIDList*": [int(0x656E, 2), int(0x006A, 2), int(0x0100, 2)],
            "0009 - BluetoothProfileDescriptorList*": [[uuid(0x1124), int(0x0100, 2)]],
            "000D - AdditionalProtocolDescriptorList*": [[[uuid(0x0100), int(0x0013, 2)], [uuid(0x0011)]]],
            "0100 - ServiceName*": "MirrorDeck Input",
            "0200 - HIDDeviceReleaseNumber": int(0x0100, 2),
            "0201 - HIDParserVersion": int(0x0111, 2),
            "0202 - HIDDeviceSubclass": int(0xC0, 1),      // keyboard + pointing
            "0203 - HIDCountryCode": int(0x21, 1),
            "0204 - HIDVirtualCable": flag(true),
            "0205 - HIDReconnectInitiate": flag(true),
            "0206 - HIDDescriptorList": [[int(0x22, 1), string(BluetoothHID.reportMap)]],
            "0207 - HIDLANGIDBaseList": [[int(0x0409, 2), int(0x0100, 2)]],
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
            state = .failed(reason: "The iPhone refused the input connection")
            return
        }
        if channel.psm == controlPSM { controlChannel = channel }
        if channel.psm == interruptPSM {
            interruptChannel = channel
            // Send immediately: iOS closes a HID link that stays idle, and every
            // write afterwards fails with an unhelpful generic error.
            sendMouse(buttons: 0, dx: 0, dy: 0, wheel: 0)
            let keep = DispatchSource.makeTimerSource(queue: queue)
            keep.schedule(deadline: .now() + 0.3, repeating: 0.3)
            keep.setEventHandler { [weak self] in
                guard let self, self.currentButtons == 0 else { return }
                self.sendMouse(buttons: 0, dx: 0, dy: 0, wheel: 0)
            }
            keep.resume()
            keepAliveTimer = keep
            DebugLog.write("HID interrupt channel open — input is live")
            state = .connected(deviceName: device?.name ?? "iPhone")
        }
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
