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

1. **Advertise as a keyboard first.** Set the Class of Device to `0x0025C0`
   (peripheral, keyboard + pointing) *then* publish the HID SDP record, in that
   order, before any pairing attempt.
2. **Pair from the phone** while that advertisement is up. Settings → Bluetooth,
   tap the Mac. Confirm the numeric code on **both** devices within ~20s.
3. **Register for incoming L2CAP channels** on PSM `0x11` and `0x13`.
4. **Wait.** The phone is the HID *host* and opens both channels to the Mac.
   The Mac must not dial out — see below.
5. **Send a report the instant the interrupt channel opens**, and keep sending.
   iOS drops a HID link that goes quiet for a second or two.
6. For the pointer, **AssistiveTouch must be enabled** on the phone
   (Settings → Accessibility → Touch → AssistiveTouch).

## Things that cost hours

Each produced a silent failure, a `nil`, or a misleading error.

**The phone connects to us, not the other way round.** This is the single
biggest thing. `openConnection()` returns `kIOReturnSuccess` without forming a
link, and outbound `openL2CAPChannelAsync` calls are refused with a bare
`kIOReturnError`. Registering for *incoming* channel notifications and waiting
is what works — the phone opens both `0x11` and `0x13` itself. Worse, a late
outbound channel that does succeed will replace the live incoming one and
silently swallow every report.

**Only one advertiser may run at a time.** A second copy of the app (an older
build left running from a `dist/` bundle) publishes its own HID record and flips
the Class of Device against the first. Pairing then succeeds or fails seemingly
at random, and the logs of either process look perfectly healthy on their own.
Check with `ps -eo pid,args | grep MirrorDeck` before debugging anything else.

**Absolute pointer, not relative.** The report descriptor uses 16-bit X/Y over
`0...32767` with `Input(Data,Var,Abs)`, so the phone's pointer lands where the
cursor is instead of drifting like a trackpad. iOS caches the descriptor at
pairing time: changing it requires forgetting the Mac on the phone and pairing
again. Idle keep-alive reports must resend the current position — a zeroed
report flings the pointer to the corner.

**Never nudge with `openL2CAPChannelAsync`.** It is not async at the end: its
completion runs `openL2CAPChannelSync` → `waitforChanneOpen`, a nested run loop,
**on the main thread**. One call freezes the whole app for seconds. To prompt a
phone that has not connected yet, use `performSDPQuery(nil)`, which brings the
ACL link up without touching the main thread.

**`isConnected()` lies, like `classOfDevice()` does.** It reports `false` while
both the Mac's and the phone's Bluetooth settings show the device connected.
Never gate logic on it; attempt the operation and judge by the result.

**IOBluetooth needs a run loop.** Its synchronous calls pump the caller's run
loop and its callbacks are delivered to one. On a dispatch queue (no run loop)
`openConnection()` burns the full page timeout and connects nothing; inside
`NSApplication`'s already-running loop it returns instantly, also connecting
nothing. Run Bluetooth work on a dedicated `Thread` with `CFRunLoopRun()`.

**Coalesce pointer reports.** One `writeSync` per mouse event backs up the
serial write queue — each write waits for the phone to acknowledge — and the
backlog reads as several seconds of lag. Accumulate deltas and emit one report
per frame.

**Keep per-event logging out of the hot path.** A `DebugLog.write` on each mouse
move does synchronous file I/O on the main thread and freezes both the app and
the Mac's own keyboard.

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

**You must advertise as a keyboard while pairing.** This is the opposite of
what an earlier version of this document claimed, and that error cost a full
day. iOS will not bond with a Mac that presents as a computer: it offers no
profile iOS can use, and the phone reports *"…is not supported"*. With the
keyboard Class of Device and HID SDP record published, the same phone pairs
normally. The feared passkey catch-22 does not occur — iOS uses numeric
comparison, showing a matching code on both devices.

**There is no UI path to a plain Mac↔iPhone bond.** macOS filters iPhones out
of System Settings → Bluetooth entirely; an inquiry scan sees the phone at
strong RSSI while the pane refuses to list it. So "pair them normally first"
is not merely wrong, it is impossible.

**Control must open before interrupt.** Opening `0x13` on a fixed delay races
ahead of `0x11` and the phone rejects it with a bare `kIOReturnError` that
names nothing. Wait for control's `l2capChannelOpenComplete`, then open
interrupt.

**`openConnection()` blocks for several seconds** and logs nothing while it
does. Silence there is normal, not a hang.

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

iOS reads the HID report map at *accessory-pairing* time, which is why the
advertisement has to be up before pairing rather than after. Change the report
map and the phone keeps using the descriptor it read when the bond was made —
you must forget the device on both sides and pair again for a new map to take
effect.

## Not done

- Modifier keys, full key mapping, scroll wheel
- Reconnect handling when the phone sleeps or leaves range
- Choosing where input goes — see `SWITCHING.md`
- Integration into MirrorDeck; this is still a standalone spike
