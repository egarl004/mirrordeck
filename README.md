<div align="center">

# MirrorDeck

**Put your iPhone screen on your Mac over Wi-Fi — and drive it with your mouse and keyboard.**

[![License: GPL v3](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)](#requirements)
[![Release](https://img.shields.io/github/v/release/egarl004/mirrordeck)](https://github.com/egarl004/mirrordeck/releases/latest)

</div>

MirrorDeck turns your Mac into a wireless screen-mirroring target. It appears in
your iPhone's Control Center under **Screen Mirroring**, exactly like an Apple TV
— pick it, and your phone shows up in a device-shaped window on your desktop.
Nothing to install on the phone.

With a bit more setup, you can also reach in and *use* the phone: click to tap,
drag to swipe, type to type. It drives the real device, not a simulator.

---

## Installing

Download the latest `.dmg` from **[Releases](https://github.com/egarl004/mirrordeck/releases/latest)**,
open it, and drag MirrorDeck to Applications.

The app is signed with a Developer ID and notarized by Apple, so it opens
without a Gatekeeper warning.

MirrorDeck lives in the **menu bar** — there is no Dock icon and no window until
a phone connects. On first launch macOS will ask for **local network
permission**; mirroring cannot work without it.

Then on your iPhone: **Control Center → Screen Mirroring → "‹your Mac› (MirrorDeck)"**.

### Requirements

| | |
|---|---|
| **macOS** | 14 (Sonoma) or later — Apple silicon or Intel |
| **iPhone** | Any iPhone on the same Wi-Fi network |
| **For mirroring** | Nothing else. No phone-side install. |
| **For control** | Xcode and your own Apple Developer account — see below |

## Controlling your phone

Mirroring is one-way: AirPlay carries video, not touches. Control is a separate
channel going the other way, and iOS is strict about it — applications are not
permitted to send touch events to other applications. The only route is
[WebDriverAgent](https://github.com/appium/WebDriverAgent), Apple's own
UI-testing tool, which is privileged because it runs as an XCUITest bundle.

**This means control requires Xcode and your own Apple Developer account.**
There is no way to engineer around it and no App Store path. Mirroring is the
part that works for everyone; control is a bonus for people who already have a
development environment.

### Setup

```sh
git clone https://github.com/egarl004/mirrordeck.git
cd mirrordeck
./scripts/bootstrap.sh

TEAM_ID=YOURTEAM ./scripts/wda.sh install   # once per phone
TEAM_ID=YOURTEAM ./scripts/wda.sh run       # leave running while controlling
```

`TEAM_ID` is your 10-character Apple Developer Team ID (Xcode → Settings →
Accounts, or the [developer portal](https://developer.apple.com/account)).
`BUNDLE_PREFIX` overrides the bundle identifier prefix if you need to.

`run` prints the address it bound, like
`ServerURLHere->http://192.168.1.42:8100<-ServerURLHere`. In the mirror window,
hover the top edge to reveal the toolbar, click **Enable Control**, and enter
that IP. It is remembered per device and reconnects automatically next time.

Re-run `run` after each phone reboot. The install itself lasts until your
provisioning profile expires.

### Interactions

Simulator conventions, so they should already feel familiar:

| Input | Action |
|---|---|
| Click | Tap |
| Click and drag | Swipe / pan |
| Click and hold | Long press |
| Scroll | Scroll |
| Type | Text input |
| → / ← | Next / previous home screen page |
| ↑ | Home |
| ↓ | Scroll down |
| ⌘⇧H | Home |
| ⌘-drag | Move the window (the video fills it, so there is little bezel to grab) |

The menu bar item has **Keep Window on Top**, which floats the mirror above
other applications and is remembered across launches.

## Known limitations

Worth reading before you install — some of these are permanent.

- **No audio.** Video only; audio frames are currently discarded.
- **Gestures take about half a second.** That is the floor for touch injection
  through XCUITest on a physical device. MirrorDeck already disables WDA's
  post-gesture idle waits (which cut swipes from ~1.0s to ~0.65s) and sends
  gestures fire-and-forget so the interface never blocks, but going below ~0.5s
  would need a lower-level HID channel that this project does not use.
- **The control helper needs restarting** every few hours, and whenever the
  phone leaves Wi-Fi.
- **The phone's IP is typed by hand** and goes stale when it rejoins the network.
- **Control is developer-only**, permanently — see above.
- **No Mac App Store.** The App Store accepts neither the AirPlay
  implementation nor GPL-licensed code. Direct download is the only route, the
  same one Reflector and AirServer take.

## Troubleshooting

**The menu bar icon doesn't appear.** On a Mac with a notch, macOS can place a
new status item *behind the notch*, where it renders as nothing and cannot be
clicked — even with free space beside it. MirrorDeck seeds a menu bar position
on first launch to avoid that. If the icon is still missing, your menu bar is
genuinely full: quit a menu bar app or two. You can ⌘-drag the icon anywhere
afterwards and the position is remembered.

Run with `MIRRORDECK_DEBUG=1` to have the app report exactly where it placed the
icon and whether that is behind the notch.

**Control won't connect, or gestures stop working.** The WebDriverAgent runner
degrades over long sessions. It can start reporting
`Application local.pid.0 is not running` for `/window/size`, after which
gestures fail with `point.x != INFINITY` because no screen size resolves.
Restart it:

```sh
./scripts/wda.sh run
```

To confirm that's the cause, `curl -s http://‹phone-ip›:8100/status` will still
report ready while `/session/‹id›/window/size` returns a stale element error.
MirrorDeck recovers from an *expired session* on its own, but it cannot repair a
degraded runner process on the phone.

**Mirroring doesn't appear in Control Center.** Check both devices are on the
same network, and that MirrorDeck has local network permission (System Settings
→ Privacy & Security → Local Network).

## Building from source

Requires Xcode, plus Homebrew `openssl@3`, `libplist`, `cmake`, `pkg-config`.

```sh
./scripts/bootstrap.sh   # fetch UxPlay + WebDriverAgent at pinned commits
./native/build.sh        # build the AirPlay core -> libMirrorCore.dylib
swift build
./.build/debug/MirrorDeck
```

To produce a distributable app and disk image:

```sh
./scripts/package.sh                 # -> dist/MirrorDeck.app + dist/MirrorDeck-<ver>.dmg
NOTARIZE=1 ./scripts/package.sh      # also notarize and staple both
```

`package.sh` signs with a *Developer ID Application* certificate when one exists
and falls back to ad-hoc signing otherwise — ad-hoc builds run locally but
Gatekeeper blocks them elsewhere. Notarization needs stored credentials once:

```sh
xcrun notarytool store-credentials mirrordeck \
    --apple-id you@example.com --team-id YOURTEAM
```

The app-specific password comes from
[appleid.apple.com](https://appleid.apple.com) → Sign-In and Security →
App-Specific Passwords.

## How it works

```
iPhone ──(AirPlay: Bonjour + pairing + FairPlay + RTSP/H.264)──▶ libMirrorCore.dylib
                                                                     │ decrypted Annex-B H.264
                                                                     ▼
                                              Swift app: VideoPipeline ▶ AVSampleBufferDisplayLayer
                                                                     ▲
iPhone ◀──(HTTP: taps/swipes/keys via WebDriverAgent :8100)── WDAClient ◀─ mouse/keyboard
```

- **`native/`** — `mirror_bridge.c` wraps the vendored AirPlay protocol core
  behind a two-function C API (`mb_start` / `mb_stop`), built as
  `libMirrorCore.dylib`. All third-party code lives here and nowhere else.
- **`Sources/MirrorDeck/`** — the app: menu bar shell, borderless mirror window,
  H.264 → `AVSampleBufferDisplayLayer` pipeline (hardware decode, ~1 frame of
  latency), and the WebDriverAgent client.
- **`vendor/`** — [UxPlay](https://github.com/FDH2/UxPlay) and
  [WebDriverAgent](https://github.com/appium/WebDriverAgent), fetched at pinned
  commits by `scripts/bootstrap.sh` rather than committed.
- **`web/`** — the project landing page.

## Roadmap

- [ ] Audio playback (AAC-ELD decode via AudioToolbox)
- [ ] Discover WebDriverAgent automatically instead of typing an IP, removing
      both the manual step and the staleness when the phone's address changes
- [ ] Keep the WDA runner alive. Its death is now detected and reported —
      the toolbar turns red and names the cause — but the runner still has to
      be restarted by hand.
- [ ] H.265 support (feature bit 42 + HEVC format descriptions)

Contributions welcome. The two roadmap items above about WebDriverAgent
reliability are the highest-value places to start.

## License

GPL-3.0 — see [LICENSE](LICENSE).

MirrorDeck is GPL-3.0 because `playfair`, the FairPlay handshake implementation
it depends on, is GPL-3.0 and cannot be removed: `fairplay_decrypt()` recovers
the media keys, so nothing mirrors without it.

Third-party components, all confined to `libMirrorCore.dylib`:

| Component | Origin | License |
|---|---|---|
| AirPlay/RAOP core | UxPlay `lib/` | LGPL-2.1-or-later |
| `playfair` (FairPlay) | UxPlay `lib/playfair/` | GPL-3.0 |
| llhttp | UxPlay `lib/llhttp/` | MIT |
| libplist | libimobiledevice | LGPL-2.1-or-later |
| libcrypto | OpenSSL 3 | Apache-2.0 |

The LGPL relinking obligation is met structurally: those components live in a
replaceable shared library exporting only `mb_start` and `mb_stop`, so anyone
can rebuild it with `./native/build.sh` and substitute their own build. See
[licenses/NOTICE.md](licenses/NOTICE.md).

### A note on FairPlay

Two different things share the FairPlay name, and they are worth separating.

**FairPlay Streaming** is the content DRM protecting Netflix, Disney+ and Apple
TV+. It needs hardware-backed keys. MirrorDeck does not have them and cannot
obtain them — protected video will black out when mirrored, exactly as it does
with every other third-party receiver. iOS excludes protected layers from the
mirrored capture before anything is encoded, so this is enforced by the phone,
not by us.

**FairPlay SAP** is the session handshake, and it is what `playfair` implements.
It answers an authentication challenge so the phone will release the key for
*its own screen*. That is all it does: `fairplay_decrypt()` turns the 72-byte
key the phone sends during setup into the 16-byte AES key for the mirroring
stream. It is not optional — without it no session starts at all.

So MirrorDeck decrypts no copyrighted work. It authenticates to a protocol so a
device can show its own screen on its owner's computer. Every open-source AirPlay
receiver depends on the same handshake, and the commercial ones reverse-engineer
it too.

Following the practice of [UxPlay](https://github.com/FDH2/UxPlay) and
[RPiPlay](https://github.com/FD-/RPiPlay), on which this work builds:

> This project is built from freely available information and is intended for
> educational purposes. It is the user's responsibility to comply with local
> law. It depends on a third-party GPL library for the FairPlay handshake whose
> legal status is unclear. If you represent Apple and object to that library or
> its use here, please open an issue or contact the maintainer and appropriate
> steps will be taken.

---

Built on the work of [UxPlay](https://github.com/FDH2/UxPlay), whose AirPlay
implementation makes the mirroring possible, and
[Appium's WebDriverAgent](https://github.com/appium/WebDriverAgent) for touch
input. Not affiliated with or endorsed by Apple Inc.
