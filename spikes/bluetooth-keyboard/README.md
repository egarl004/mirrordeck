# Spike: the Mac as a Bluetooth keyboard

A working proof that a Mac can present itself to an iPhone as a Bluetooth HID
keyboard using **only public APIs** — no Xcode on the phone, no Apple Developer
account, no WebDriverAgent.

If this replaces WDA for input, control stops being a developer-only feature:
pairing becomes a one-time Bluetooth pair like any keyboard, and latency drops
from WDA's ~500 ms floor to ordinary Bluetooth HID timings.

## Status

Verified end to end against an iPhone 15 Pro on iOS 26.5:

- HID service record publishes
- Class of Device set to keyboard
- iPhone pairs, then **accepts** L2CAP connections on both HID channels
- Keystrokes write successfully over HIDP
- The phone answers on its own initiative — an LED-state report (`a2 00`) and
  `HID_CONTROL` suspend/resume (`13`, `14`) on the control channel, which is a
  host managing a keyboard it has accepted

## The four things that were hard to find

Each of these produced a silent failure — a `nil` return or a generic error
with nothing in any log — so they are worth writing down.

**1. SDP dictionary encoding.** UUIDs are raw `Data`, *not* `DataElementType` /
`DataElementValue` dictionaries:

```swift
"0001 - ServiceClassIDList": [Data([0x11, 0x24])]     // right
"0001 - ServiceClassIDList": [["DataElementType": 3, ...]]   // publishes nil
```

The format is discoverable by reading Apple's own records, e.g.
`/System/Library/CoreServices/OBEXAgent.app/Contents/Resources/OBEXOPPSDPRecord.plist`.

**2. The report map is a text-string element.** `0206 - HIDDescriptorList` is
the one attribute that rejects raw `Data`; it needs `DataElementType: 4`.
Isolated by adding attributes one at a time until publishing broke.

**3. Class of Device must be set, and its getter lies.**
`IOBluetoothHostController.setClassOfDevice(0x002540, forTimeInterval:)` —
Peripheral major class, Keyboard minor class. Without it the Mac announces
itself as a *Computer*, iOS accepts the socket and then drops it, and every
write fails with `kIOReturnError`. `classOfDevice()` returns `0x0` regardless,
before and after, so it cannot be used to check whether the call worked.

**4. The phone will not initiate; the Mac must.** iOS pairs with the Mac as a
computer and never opens the HID channels itself. The Mac opens them outbound
with `openL2CAPChannelAsync` on PSM `0x11` (control) and `0x13` (interrupt).
This is the `HIDReconnectInitiate` path.

## Running it

Needs a Mac↔iPhone Bluetooth pairing already in place, and the phone's
Bluetooth address in the source. Build as a signed `.app` bundle with
`NSBluetoothAlwaysUsageDescription` — a bare binary is killed by TCC, and
running the executable directly out of a bundle does not pick up its
Info.plist, so launch it with `open`.

## Not done yet

- **Mouse.** A keyboard cannot tap coordinates. The same transport carries a
  mouse report descriptor, which iOS accepts as a pointer via AssistiveTouch —
  that is what would actually replace WDA. Descriptor change, proven transport.
- Reconnect handling, key mapping beyond a few test keys, modifiers.
- Integration into MirrorDeck: this is a standalone spike.
