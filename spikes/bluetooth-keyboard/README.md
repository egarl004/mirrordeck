# Spike: the Mac as a Bluetooth keyboard and mouse

**Working.** A Mac can drive an iPhone's keyboard *and pointer* over Bluetooth
HID using only public APIs — no Xcode on the phone, no Apple Developer account,
no WebDriverAgent. Verified against an iPhone 15 Pro on iOS 26.5: text typed
into Notes, and the AssistiveTouch pointer traced a square and clicked.

This is a replacement for WebDriverAgent as MirrorDeck's input path:

| | WebDriverAgent | Bluetooth HID |
|---|---|---|
| Setup for the user | Xcode, Apple Developer account, build and launch a test runner | Pair once, like any keyboard |
| Latency | ~500 ms per gesture (XCUITest floor) | milliseconds |
| Stability | runner dies roughly hourly | ordinary Bluetooth link |
| Reaches ordinary users | no | yes |

## The working sequence

Order matters more than anything else here. Getting it wrong fails silently or
with misleading errors.

1. **A normal Mac↔iPhone Bluetooth bond must already exist.** Pair the way two
   Apple devices normally pair. Do *not* try to pair the Mac as a HID accessory
   from the phone — see the catch-22 below.
2. **Publish the HID SDP record** with the composite report map.
3. **Set the Class of Device** to `0x0025C0` (peripheral, keyboard + pointing),
   *after* the bond exists.
4. **Open L2CAP outbound** to PSM `0x11` (control) and `0x13` (interrupt). The
   phone never initiates; the Mac must.
5. **Send a report immediately** when the interrupt channel opens, and keep
   sending. iOS closes an idle HID link within a second or two.
6. For the pointer, **AssistiveTouch must be enabled** on the phone
   (Settings → Accessibility → Touch → AssistiveTouch).

## Things that cost hours

Each produced a silent failure, a `nil`, or a misleading error.

**SDP dictionary encoding.** UUIDs are raw `Data`, not `DataElementType` /
`DataElementValue` dictionaries. Compare against Apple's own records, e.g.
`/System/Library/CoreServices/OBEXAgent.app/Contents/Resources/OBEXOPPSDPRecord.plist`.

```swift
"0001 - ServiceClassIDList": [Data([0x11, 0x24])]            // right
"0001 - ServiceClassIDList": [["DataElementType": 3, ...]]   // returns nil
```

**The report map is a text-string element.** `0206 - HIDDescriptorList` is the
one attribute that rejects raw `Data`; it needs `DataElementType: 4`. Found by
adding attributes one at a time until publishing broke.

**`setClassOfDevice` works, but its getter lies.** `classOfDevice()` returns
`0x0` before and after a successful call, so it cannot confirm anything. Judge
by behaviour instead.

**Never advertise as a keyboard while pairing.** iOS pairs keyboards with
passkey entry — it displays a code and waits for you to *type it on the
keyboard*. A Mac cannot, so pairing always fails. Pair as an ordinary Mac, then
switch the class afterwards.

**Idle links close instantly.** Any delay between the channel opening and the
first report loses the link, and subsequent writes fail with a generic
`kIOReturnError` that says nothing about why.

**Pairing must be confirmed on both devices.** Numeric comparison shows the
same code on the phone and in a dialog on the Mac. Answering only the phone
times out and reports "Pairing Unsuccessful", which reads like a protocol
failure and is not one.

**Clear stale bonds from both sides.** Forgetting on one side only leaves
mismatched link keys, and the phone then reports "iPhone can no longer connect
to… Forget this device and pair it again."

## The one real constraint

iOS reads a HID report map at *accessory-pairing* time. Because we pair as an
ordinary Mac rather than as an accessory, it is not obvious when the phone
reads our descriptor — yet the pointer works, so it evidently does. If a future
iOS stops doing this, the fallback would require pairing as a HID device, which
runs into the passkey catch-22 above: iOS wants a code typed on the keyboard
before the keyboard exists.

## Not done

- Modifier keys, full key mapping, scroll wheel
- Reconnect handling when the phone sleeps or leaves range
- Choosing where input goes — see `SWITCHING.md`
- Integration into MirrorDeck; this is still a standalone spike
