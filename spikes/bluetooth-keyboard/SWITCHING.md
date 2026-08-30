# Switching input between the Mac and the phone

Once the Mac is a Bluetooth keyboard and mouse, the interesting question is
where your typing and pointer go. Three designs, in increasing order of how
much they take over.

## 1. Window focus decides it (no permissions)

Input goes to the phone whenever the MirrorDeck mirror window is focused, and
to the Mac otherwise — which is how the WDA path already behaves. Clicking the
window means "control the phone"; clicking anything else gives your Mac back.

Needs no permissions and cannot strand you, because the escape is clicking
another window. The limitation is that it only captures what the window
receives: system shortcuts and the menu bar still belong to macOS, and the
pointer stays inside the window's bounds.

Best default. This is the same model as a VM or Simulator window.

## 2. A toggle key that captures everything (needs Accessibility)

A hotkey flips a global mode. While it is on, a `CGEventTap` intercepts
keyboard and mouse events before any app sees them, forwards them over
Bluetooth HID, and swallows them so the Mac does not react. Pressing the
hotkey again gives the Mac back.

This is the Synergy / Universal Control model, and it is what makes the phone
feel like a second screen rather than a window. It needs Accessibility
permission — a one-time grant in System Settings, far lighter than the Xcode
and developer-account requirement WDA imposes.

Two rules matter for not stranding the user:

- **The toggle key must never be swallowed.** Whatever else the tap consumes,
  it has to let the toggle through, or there is no way back.
- **Fail open.** If the Bluetooth link drops while captured, release the tap
  immediately and return input to the Mac. Being captured with nowhere for the
  events to go is the worst possible state.

Worth adding a dead-man's switch: if no HID report has been acknowledged for a
few seconds, drop out of capture on its own.

## 3. Edge push (needs Accessibility)

Move the pointer off the edge of the screen nearest the mirror window and input
follows onto the phone, like a second display. Nicest to use, most fiddly to
get right, and the easiest to trigger by accident. Only worth building after
(2) works.

## Recommended path

Start with (1), because it is free and already matches how the app behaves.
Add (2) behind a preference for people who want the phone to feel like a real
second device. Treat (3) as polish.

## Reporting the state

Whichever is chosen, the current target must be obvious at a glance — the
failure mode is typing a password into the wrong device. The menu bar icon
should change, and the mirror window should show a clear border or badge while
it owns input. Cheap to build, and it prevents the one genuinely bad outcome.
