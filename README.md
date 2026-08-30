# MirrorDeck

Wireless iOS screen mirroring to your Mac — with mouse control of the real phone.

Free software under the [GPL-3.0](LICENSE).

The Mac advertises itself as an AirPlay screen-mirroring target (like Reflector),
so it appears in the iPhone's Control Center → Screen Mirroring list. The mirrored
screen shows up in a minimal, device-shaped borderless window. With WebDriverAgent
running on the phone, you can tap, swipe, scroll, and type on the actual device
using Simulator-style mouse interactions.

## Architecture

```
iPhone ──(AirPlay: Bonjour + pairing + FairPlay + RTSP/H.264)──▶ native/ C core
                                                                     │ decrypted Annex-B H.264
                                                                     ▼
                                              Swift app: VideoPipeline ▶ AVSampleBufferDisplayLayer
                                                                     ▲
iPhone ◀──(HTTP: taps/swipes/keys via WebDriverAgent :8100)── WDAClient ◀─ mouse/keyboard
```

- `vendor/UxPlay` — vendored [UxPlay](https://github.com/FDH2/UxPlay) sources.
  Only its protocol core (`lib/`, LGPL-2.1) is compiled; its GStreamer renderer
  is not used.
- `native/` — `mirror_bridge.c` wraps the core behind a tiny start/stop +
  callbacks C API; `build.sh` produces `native/build/libMirrorCore.a`
  (protocol core + playfair + llhttp + dnssd + static libplist + libcrypto).
- `Sources/MirrorDeck/` — the Mac app (menu bar shell, borderless mirror
  window, H.264 → `AVSampleBufferDisplayLayer` pipeline, WDA client).
- `vendor/WebDriverAgent` — Appium's WebDriverAgent, used for touch injection.
  `scripts/wda.sh` builds, installs, and launches it.

## Build & run

Prereqs: Xcode, Homebrew `openssl@3`, `libplist`, `cmake`, `pkg-config`.

```sh
./native/build.sh   # build the AirPlay core (rerun only when native/ or vendor/ changes)
swift build
./.build/debug/MirrorDeck
```

The app lives in the menu bar (no Dock icon). On the iPhone: Control Center →
Screen Mirroring → "<your Mac> (MirrorDeck)". The mirror window appears when
video starts. macOS may show firewall / local-network prompts on first run —
allow them.

## Controlling the phone

Mirroring is one-way; AirPlay has no touch backchannel. Control uses
[WebDriverAgent](https://github.com/appium/WebDriverAgent) (the XCUITest-based
server Appium uses), running on the phone over Wi-Fi. `scripts/wda.sh` wraps
the whole flow:

```sh
./scripts/wda.sh install   # build + sign + install the runner (once)
./scripts/wda.sh run       # start the WDA server; leave running while controlling
```

Then in the mirror window, hover to reveal the toolbar → **Enable Control** →
the phone's IP (prefilled from last use). It's remembered per device and
reconnects automatically next time.

### If control stops working

The WebDriverAgent runner degrades over long sessions. After a few hours of use
— app launches, expiring sessions, lock/unlock cycles — it can end up reporting
`Application local.pid.0 is not running` for `/window/size`, and gestures then
fail with `point.x != INFINITY` because no screen size can be resolved. The app
cannot connect in that state.

The fix is to restart the runner:

```sh
./scripts/wda.sh run
```

Check whether this is the problem with
`curl -s http://<phone-ip>:8100/status`. If it reports ready but
`curl -s http://<phone-ip>:8100/session/<sid>/window/size` returns a stale
element error, the runner needs restarting. MirrorDeck now recovers on its own
from an *expired session* (keep-awake detects it and reconnects), but it cannot
repair a degraded runner process on the phone.

`run` prints the server URL it bound, e.g.
`ServerURLHere->http://192.168.1.197:8100<-ServerURLHere`. Signing uses team
`HLL4A3K24N` and bundle prefix `com.emersongarland`; override with `TEAM_ID=` /
`BUNDLE_PREFIX=` env vars. The runner must be re-launched (`run`) after each
phone reboot; the install itself lasts until the provisioning profile expires.

Interactions (Simulator conventions): click = tap, click-drag = swipe/pan,
click-hold = long press, scroll = swipe, typing goes to the phone,
⌘⇧H = Home button.

Keyboard navigation (all verified against a physical iPhone 15 Pro):

| Key | Action |
|---|---|
| → | Next home screen page (finger swipes right-to-left) |
| ← | Previous page / back |
| ↑ | Home button |
| ↓ | Scroll content down |

Arrow keys are intercepted before the text-input fallback — they carry
private-use function characters that would otherwise be typed to the phone as
garbage. Navigation is rate-limited to one gesture per 0.35s so holding a key
(auto-repeat) can't flood the ~0.5s-per-gesture queue.

### Latency

Touch injection goes through XCUITest, which has a hard floor of ~0.5s per
gesture on a physical device (measured: tap ~0.5s, swipe ~0.6–0.75s after
tuning). Two things keep it usable:

- On connect, MirrorDeck disables WDA's post-gesture idle/animation waits
  (`waitForIdleTimeout`/`animationCoolOffTimeout` → 0), which cut swipes from
  ~1.0s to ~0.65s.
- Gestures are **fire-and-forget** — the Mac never blocks on that half-second,
  so input stays fluid and gestures pipeline. The tap ripple is drawn
  immediately as local feedback.

Going below ~0.5s is not possible through WDA; it needs a lower-level HID
injection channel (e.g. the on-device instruments/DVT services), which is a
larger project and also outside App Store rules — see below.

### Keep awake

While control is connected, MirrorDeck polls the phone's lock state every 8s
and re-unlocks if it auto-locked, so the mirror never drops to black. This is
reactive (a brief black frame is possible before re-wake) because a periodic
synthetic "nudge" tap would risk activating whatever is on screen. Truly
preventing the screen from ever dimming requires an on-device app holding
`isIdleTimerDisabled`, which is part of the productization path below.

## Status / roadmap

- [x] AirPlay receiver: Bonjour advertise, pairing, FairPlay, mirroring stream
- [x] Hardware H.264 render via AVSampleBufferDisplayLayer (~1 frame latency)
- [x] Device-shaped borderless window, hover toolbar, tap ripples, menu bar app
- [x] WDA control client: tap / long-press / drag / scroll / type / Home
- [x] Keyboard navigation: arrows for pages, Home, scroll
- [x] App bundle, generated icon, signed disk image (`scripts/package.sh`)
- [ ] Audio playback (AAC-ELD decode via AudioToolbox — frames currently dropped)
- [ ] Auto-discover WDA instead of typing the phone's IP. The phone's address
      changes when it rejoins Wi-Fi, so the stored host goes stale; discovering
      the runner over Bonjour (or launching it via `go-ios`) would remove both
      the manual step and the staleness.
- [ ] Keep the WDA runner alive, or detect its death from the Mac. It degrades
      after a few hours and dies outright when the phone leaves the network.
- [ ] H.265 support (advertise feature bit 42 + HEVC format descriptions)

## Packaging

```sh
./scripts/bootstrap.sh    # fetch vendored deps (first checkout only)
./scripts/package.sh      # -> dist/MirrorDeck.app and dist/MirrorDeck-<ver>.dmg
```

Produces a self-contained bundle (no external dylibs — the AirPlay core,
libplist, and libcrypto are all statically linked) with a generated icon,
`LSUIElement` set for menu-bar-only operation, and the `NSBonjourServices` /
`NSLocalNetworkUsageDescription` keys macOS requires to advertise on the local
network. `VERSION=0.2.0 ./scripts/package.sh` sets the version.

### Distribution

**Signing.** `package.sh` uses a *Developer ID Application* certificate when one
exists and falls back to ad-hoc signing otherwise. Ad-hoc builds run on the
machine that made them, but Gatekeeper blocks them everywhere else, so a
Developer ID certificate is required before sharing the app. Create one in
Xcode: Settings → Accounts → Manage Certificates → **+** → Developer ID
Application. `package.sh` picks it up automatically and enables the hardened
runtime.

**Notarization.** Apple scans and approves the build so it opens without
warnings. Store credentials once, then package with `NOTARIZE=1`:

```sh
xcrun notarytool store-credentials mirrordeck \
    --apple-id <you@example.com> --team-id HLL4A3K24N
NOTARIZE=1 ./scripts/package.sh
```

The app-specific password comes from appleid.apple.com → Sign-In and Security →
App-Specific Passwords.

**Licensing.** MirrorDeck is GPL-3.0 (see `LICENSE`). That follows from
`lib/playfair`, the FairPlay handshake implementation, which is GPL-3.0 and
mandatory — `fairplay_decrypt()` recovers the media keys, so nothing mirrors
without it. GPL-3.0 is strong copyleft and a shared library is not a cure for it
(that accommodation is what distinguishes LGPL), so the combined work is
GPL-3.0. Distributing the source alongside the app satisfies this.

The separate LGPL-2.1 obligation is handled structurally: the AirPlay core and
libplist live in a replaceable `Contents/Frameworks/libMirrorCore.dylib`
exporting only `mb_start` and `mb_stop`, so anyone can rebuild it with
`./native/build.sh` and substitute their own build. Verified — deleting the
library stops the app launching, and a rebuilt one works in its place.

**One thing engineering cannot settle.** `playfair` is a reverse-engineered
implementation of Apple's FairPlay DRM. Distributing DRM-circumvention code
carries risk under DMCA §1201 in the US, and that risk does not disappear
because the software is free. [docs/legal-brief.md](docs/legal-brief.md)
describes the code and the open questions for a lawyer; it is worth reading
before publishing this anywhere public.

## Platform limits worth knowing

**No Mac App Store.** The App Store will not accept the reverse-engineered
AirPlay implementation or the GPL-licensed code. Direct download is the only
route — the same one Reflector, AirServer, and X-Mirage take.

**Control is developer-only, permanently.** iOS does not let apps inject touch
events into other apps. WebDriverAgent works only because it is a privileged
XCUITest bundle, which means every user needs their own Apple Developer account
and Xcode. There is no App Store path and no way to engineer around it, so
mirroring is the feature that works for everyone and control is a bonus for
people who already have a development environment.

## Licensing note

All third-party code is confined to `libMirrorCore.dylib`:

| Component | Origin | License |
|---|---|---|
| AirPlay/RAOP core | UxPlay `lib/` | LGPL-2.1-or-later |
| `playfair` (FairPlay) | UxPlay `lib/playfair/` | **GPL-3.0** |
| llhttp | UxPlay `lib/llhttp/` | MIT |
| libplist | libimobiledevice | LGPL-2.1-or-later |
| libcrypto | OpenSSL 3 | Apache-2.0 |

UxPlay's renderer/app code is not used. `playfair` is GPL-3.0 and mandatory,
which is why MirrorDeck as a whole is GPL-3.0 — see [LICENSE](LICENSE),
[licenses/NOTICE.md](licenses/NOTICE.md), and
[docs/legal-brief.md](docs/legal-brief.md).
