import Foundation
import IOBluetooth
let out = "/private/tmp/claude-502/-Users-emerson-garland-ios-screenshare/c16f0678-ffb9-48c9-9eab-b9eff2f8d155/scratchpad/mouse.txt"
func say(_ s: String) {
    let l = s + "\n"
    if let fh = FileHandle(forWritingAtPath: out) { fh.seekToEndOfFile(); fh.write(l.data(using: .utf8)!); fh.closeFile() }
    else { try? l.write(toFile: out, atomically: true, encoding: .utf8) }
}
func uuid16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xff)]) }
func uint(_ v: Int, _ s: Int) -> [String: Any] { ["DataElementType": 1, "DataElementSize": s, "DataElementValue": v] }
func bool(_ v: Bool) -> [String: Any] { ["DataElementType": 5, "DataElementSize": 1, "DataElementValue": v ? 1 : 0] }
func text(_ d: Data) -> [String: Any] { ["DataElementType": 4, "DataElementSize": d.count, "DataElementValue": d] }

// Composite: keyboard on report ID 1, mouse on report ID 2.
let reportMap = Data([
  // ---- Keyboard, Report ID 1 ----
  0x05,0x01, 0x09,0x06, 0xA1,0x01, 0x85,0x01,
  0x05,0x07, 0x19,0xE0, 0x29,0xE7, 0x15,0x00, 0x25,0x01, 0x75,0x01, 0x95,0x08, 0x81,0x02,
  0x95,0x01, 0x75,0x08, 0x81,0x03,
  0x95,0x06, 0x75,0x08, 0x15,0x00, 0x25,0x65, 0x05,0x07, 0x19,0x00, 0x29,0x65, 0x81,0x00,
  0xC0,
  // ---- Mouse, Report ID 2 ----
  0x05,0x01, 0x09,0x02, 0xA1,0x01, 0x85,0x02,
  0x09,0x01, 0xA1,0x00,
  0x05,0x09, 0x19,0x01, 0x29,0x03, 0x15,0x00, 0x25,0x01, 0x95,0x03, 0x75,0x01, 0x81,0x02,
  0x95,0x01, 0x75,0x05, 0x81,0x03,
  0x05,0x01, 0x09,0x30, 0x09,0x31, 0x15,0x81, 0x25,0x7F, 0x75,0x08, 0x95,0x02, 0x81,0x06,
  0x09,0x38, 0x15,0x81, 0x25,0x7F, 0x75,0x08, 0x95,0x01, 0x81,0x06,
  0xC0, 0xC0,
])

if let h = IOBluetoothHostController.default() {
    say("setClassOfDevice(0x0025C0 combo) -> \(h.setClassOfDevice(0x0025C0, forTimeInterval: 300))")
}
let rec = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: [
    "0001 - ServiceClassIDList": [uuid16(0x1124)],
    "0004 - ProtocolDescriptorList": [[uuid16(0x0100), uint(0x0011,2)], [uuid16(0x0011)]],
    "0005 - BrowseGroupList*": [uuid16(0x1002)],
    "0006 - LanguageBaseAttributeIDList*": [uint(0x656E,2), uint(0x006A,2), uint(0x0100,2)],
    "0009 - BluetoothProfileDescriptorList*": [[uuid16(0x1124), uint(0x0100,2)]],
    "000D - AdditionalProtocolDescriptorList*": [[[uuid16(0x0100), uint(0x0013,2)], [uuid16(0x0011)]]],
    "0100 - ServiceName*": "MirrorDeck Input",
    "0200 - HIDDeviceReleaseNumber": uint(0x0100,2), "0201 - HIDParserVersion": uint(0x0111,2),
    "0202 - HIDDeviceSubclass": uint(0xC0,1),          // 0xC0 = keyboard + pointing
    "0203 - HIDCountryCode": uint(0x21,1),
    "0204 - HIDVirtualCable": bool(true), "0205 - HIDReconnectInitiate": bool(true),
    "0206 - HIDDescriptorList": [[uint(0x22,1), text(reportMap)]],
    "0207 - HIDLANGIDBaseList": [[uint(0x0409,2), uint(0x0100,2)]], "020D - HIDBootDevice": bool(false),
])
say("SDP: \(rec != nil ? "published" : "FAILED")")

final class HID: NSObject, IOBluetoothL2CAPChannelDelegate {
    var interrupt: IOBluetoothL2CAPChannel?
    func l2capChannelOpenComplete(_ c: IOBluetoothL2CAPChannel!, status e: IOReturn) {
        say("PSM 0x\(String(c.psm, radix: 16)) \(e == kIOReturnSuccess ? "OPEN" : "err \(e)")")
        if c.psm == 0x13 { interrupt = c
            self.demo() }
    }
    func l2capChannelClosed(_ c: IOBluetoothL2CAPChannel!) { say("PSM 0x\(String(c.psm, radix: 16)) CLOSED") }
    func l2capChannelData(_ c: IOBluetoothL2CAPChannel!, data: UnsafeMutableRawPointer!, length: Int) {
        let b = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: length)
        say("<<< \(b.map { String(format: "%02x", $0) }.joined(separator: " "))")
    }
    @discardableResult func raw(_ bytes: [UInt8]) -> IOReturn {
        guard let ch = interrupt else { return -1 }
        var p = bytes
        return p.withUnsafeMutableBytes { ch.writeSync($0.baseAddress!, length: UInt16($0.count)) }
    }
    /// 0xA1 = DATA|INPUT, then report ID 2, buttons, dx, dy, wheel
    func move(_ dx: Int8, _ dy: Int8) { raw([0xA1, 0x02, 0x00, UInt8(bitPattern: dx), UInt8(bitPattern: dy), 0]) }
    func click() {
        raw([0xA1, 0x02, 0x01, 0, 0, 0]); Thread.sleep(forTimeInterval: 0.05)
        raw([0xA1, 0x02, 0x00, 0, 0, 0])
    }
    func demo() {
        say(">>> moving pointer in a square")
        for _ in 0..<25 { move(8, 0); Thread.sleep(forTimeInterval: 0.02) }
        for _ in 0..<25 { move(0, 8); Thread.sleep(forTimeInterval: 0.02) }
        for _ in 0..<25 { move(-8, 0); Thread.sleep(forTimeInterval: 0.02) }
        for _ in 0..<25 { move(0, -8); Thread.sleep(forTimeInterval: 0.02) }
        say(">>> square done; clicking")
        click()
        say(">>> done — holding link with idle reports")
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            self.raw([0xA1, 0x02, 0x00, 0, 0, 0])
        }
    }
}
let hid = HID()
guard let dev = IOBluetoothDevice(addressString: "F4:E8:C7:41:04:FA") else { say("no device"); exit(1) }
say("openConnection -> \(dev.openConnection())")
var c1: IOBluetoothL2CAPChannel?, c2: IOBluetoothL2CAPChannel?
say("control -> \(dev.openL2CAPChannelAsync(&c1, withPSM: 0x0011, delegate: hid))")
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    say("interrupt -> \(dev.openL2CAPChannelAsync(&c2, withPSM: 0x0013, delegate: hid))")
}
DispatchQueue.main.asyncAfter(deadline: .now() + 40) { say("exit"); exit(0) }
RunLoop.main.run()
