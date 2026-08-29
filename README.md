# MirrorDeck

Wireless iOS screen mirroring to your Mac — with mouse control of the real phone.

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
- [ ] Audio playback (AAC-ELD decode via AudioToolbox — frames currently dropped)
- [ ] Auto-discover WDA / launch via go-ios instead of manual IP entry
- [ ] H.265 support (advertise feature bit 42 + HEVC format descriptions)
- [ ] App bundle + icon (currently a bare SwiftPM executable)

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

### Before it can be sold

Three things stand between this and a shippable product. The first is
mechanical; the other two are not.

**1. Developer ID certificate (mechanical).** This machine has only *Apple
Development* certificates, so `package.sh` currently falls back to ad-hoc
signing — Gatekeeper will block that build on any other Mac. You need a
**Developer ID Application** certificate (Apple Developer Program, $99/yr,
already active given the 2027 provisioning profile). Create it in Xcode via
Settings → Accounts → Manage Certificates → **+** → Developer ID Application,
then re-run `package.sh` — it picks the identity up automatically and switches
on the hardened runtime. For notarization, store credentials once:

```sh
xcrun notarytool store-credentials mirrordeck --apple-id <you@example.com> --team-id HLL4A3K24N
```

then `NOTARIZE=1 ./scripts/package.sh`.

**2. LGPL compliance (fixable, needs work).** The AirPlay core is UxPlay's
`lib/`, which is LGPL-2.1. LGPL permits use in a commercial closed-source
product, but it requires that users be able to **relink** the app against a
modified version of the LGPL part. The current build statically links
everything into one binary, which does not satisfy that. To comply, either
build the AirPlay core as a **dynamic library** the app loads (the usual fix),
or ship the object files so a user can relink. Either way you must also
distribute the LGPL source and its license text. This is real work, not a
paperwork step — worth deciding before writing marketing copy.

**3. FairPlay / DMCA exposure (needs a lawyer, not a commit).** Mirroring only
works because `lib/playfair` implements Apple's FairPlay handshake, which was
obtained by reverse engineering. Selling software whose core function depends
on circumventing a DRM scheme carries genuine legal risk in the US under DMCA
§1201, and Apple controls the AirPlay trademark and its official licensing
program (MFi). Reflector and AirServer are the proof this market exists, but
they are companies that have taken deliberate positions on this exact question.
**Get actual legal advice before selling this** — it is the single largest risk
to the project, and no amount of engineering removes it.

None of this blocks building, using, or sharing the app privately. It blocks
*selling* it.

## Productization / App Store reality

Two parts of this project sit on opposite sides of Apple's distribution rules:

**Mac app (mirroring):** shippable, but **not via the Mac App Store** — it uses
the reverse-engineered AirPlay/FairPlay protocol and LGPL/GPL code, which MAS
won't accept. This is normal for the category: Reflector, AirServer, and
X-Mirage all ship as **direct downloads signed with a Developer ID and
notarized**. That path is fully legitimate and is how a MirrorDeck product
would be distributed.

**iPhone touch control:** there is **no App Store path**. Injecting touches
into other apps is forbidden on stock iOS (the sandbox has no cross-app
synthetic events). WebDriverAgent works only because it's a developer-signed
XCUITest bundle launched via Xcode/`go-ios` — a developer/automation tool, not
something an end user can install from the App Store. Apple's own iPhone
Mirroring does this only through private frameworks + account continuity that
third parties can't use.

So a realistic product is a **direct-download, notarized Mac app** where:
- Mirroring works for any user out of the box (no phone-side install).
- Control is a **power-user feature** gated behind a one-time WDA setup, ideally
  streamlined by bundling `go-ios` to build/install/launch WDA automatically
  and auto-discover its port. It will always require the user's own Apple
  developer signing — that constraint can't be removed.

The keep-awake, faster-than-0.5s control, and any "no phone setup" control
would all require an on-device companion app doing what stock iOS doesn't
allow, so they don't change the App-Store answer.

## Licensing note

The vendored protocol core is LGPL-2.1 (UxPlay's `lib/`, descended from
shairplay/RPiPlay); UxPlay's own renderer/app code (GPL-3.0) is not linked.
The FairPlay handshake implementation (`playfair`) is reverse-engineered —
fine for personal use; do your own diligence before shipping commercially.
