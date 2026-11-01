# tpscroll

Linux-style middle-button scrolling for the **Lenovo ThinkPad TrackPoint Keyboard II** on macOS.

On Linux, the `hid-lenovo` driver switches this keyboard into its *native* mode: hold the middle button and push the
TrackPoint to scroll **vertically and horizontally**, with no stray middle click afterwards. On macOS the keyboard
stays in its default mode, where you get vertical-only, accelerated scrolling, and every scroll ends in a middle
click. `tpscroll` is a small background agent (~400 lines of Swift, no UI) that does what the Linux driver does,
from user space.

## Features

- **Two-axis scrolling**: hold middle + TrackPoint scrolls vertically and horizontally.
- **Linear speed, like Linux**: every scroll step moves a fixed number of pixels on both axes, with no macOS wheel
  acceleration, so vertical and horizontal feel the same.
- **Middle click on release, only if you didn't scroll**: the same behaviour as hid-lenovo's middle-click workaround.
- **Bluetooth and USB receiver** (`17EF:60E1` and `17EF:60EE`).
- **Duplicate-scroll filter for this keyboard only**: over Bluetooth the keyboard keeps sending a standard wheel
  event as well. tpscroll drops those events only when they come from this keyboard, so other mice and the trackpad
  are never affected.
- **Fn+F4 mic mute** toggles the mute of the default input device.
- **Fn+F7** (*Win+P*, which macOS sees as ⌘P/⌥P and which would open Print or similar) is swallowed.
- **Re-applies settings** on reconnect, wake, and if the keyboard ever drops back to its default mode.
- **Fn-lock and sensitivity** are set the same way the Linux driver sets them.
- **Stays out of the way**: the event tap runs on its own thread and does only a few lookups per event. Keystrokes
  pass through it only while Fn+F7 swallowing is on (`swallowF7`, the default).

## Requirements

- macOS 13 or later on Apple silicon or Intel. Developed and tested on macOS 27.2.
- Xcode or the Command Line Tools, for `swiftc`.

## Install

```sh
git clone https://github.com/lebdron/tpscroll.git
cd tpscroll
./install.sh
```

Then grant **TPScroll** two permissions in *System Settings › Privacy & Security*. TPScroll picks up each grant
within a few seconds:

1. **Input Monitoring**: needed to read the keyboard's HID reports.
2. **Accessibility**: needed to post scroll and click events and to filter the duplicate wheel. Some macOS
   versions list this permission as *Device Control and Data Access*.

macOS shows a prompt for each, but for a newly installed app the prompt does not always add it to the list. If
TPScroll is missing, click **+**, press ⌘⇧G, and add `~/Applications/TPScroll.app`.

The keyboard switches to native mode as soon as TPScroll is running; no power-cycle is needed. When TPScroll stops
(uninstall, logout), it switches the keyboard back to its default mode.

> **Rebuilding:** ad-hoc signed builds get a new code signature every time, which invalidates the grants. After a
> rebuild, run `./install.sh --reset-permissions` and grant both permissions again. To avoid this, sign with a
> stable identity: `SIGN_ID="Apple Development: …" ./install.sh`.

Uninstall with `./uninstall.sh`. Add `--purge` to also delete the settings, the log and the privacy grants.

## Settings

Settings are stored in the defaults domain `io.github.lebdron.tpscroll` and picked up within about 3 seconds,
with no restart needed:

```sh
defaults write io.github.lebdron.tpscroll pixelsPerStep -float 20      # pixels per step, 1–500 (default 20)
defaults write io.github.lebdron.tpscroll direction -string system     # system | natural | traditional
defaults write io.github.lebdron.tpscroll invertHorizontal -bool true  # flip horizontal only
defaults write io.github.lebdron.tpscroll swallowF7 -bool false        # let Fn+F7 (Win+P) through
defaults write io.github.lebdron.tpscroll fnLock -int 0                # 1 (default): F1–F12, hotkeys on Fn
defaults write io.github.lebdron.tpscroll sensitivity -int 5           # TrackPoint sensitivity (default 5)
```

`fnLock` and `sensitivity` take effect the next time the keyboard connects. `direction system` follows the macOS
*Natural scrolling* setting. Linux defaults to traditional scrolling.

Log: `~/Library/Logs/tpscroll.log`.

## How it works

| | Bluetooth (`60E1`) | USB receiver (`60EE`) |
|---|---|---|
| Command | output report `0x18`: `18 cmd val` | feature report `0x13` on the mouse interface: `13 cmd val` |
| Native mode | `09 01` | `09 01` |
| Middle button | report `0x15`, byte 2 bit `0x04` | same |
| Scroll steps | report `0x16`: `[h, v]` as signed bytes | same |
| Hotkeys | report `0x05`: `[code]` (`0xbb` = mic mute) | same |
| Extra standard wheel in native mode | **yes** (report `0x02`) | no |

- **Scrolling**: each step from report `0x16` becomes a pixel scroll event on both axes. The direction follows your
  macOS setting, and the events are posted downstream of HID-level event taps.
- **Duplicate filter**: macOS scroll events carry an undocumented field (number 87) that holds the registry ID of the
  `IOHIDEventService` that produced them. tpscroll looks up the keyboard's service IDs on connect and drops only
  scroll events from those services, and only once native mode is confirmed. If the field is ever missing, a
  timing-based fallback takes over. If the mode switch fails, normal macOS scrolling keeps working.
- **F7 detection**: the Win+P hotkey arrives as the GUI modifier and P within 20 ms of each other in one HID burst.
  The raw report reaches tpscroll 2–5 ms before macOS's key event, so only that combination is dropped.
  A ⌘P or ⌥P you type yourself still works.

[docs/PROTOCOL.md](docs/PROTOCOL.md) has the full protocol notes and how they were found. `tools/tprec` is the
diagnostic recorder used to find them. Build it with `./build.sh tprec`.

## Limitations

- **Field 87 is undocumented** and a future macOS version could change it. tpscroll then falls back to a timing rule.
- **Ad-hoc builds** need the permissions granted again after every rebuild (see above).
- **Other hotkeys** (Fn+F8–F12, Fn+PrtSc) are ignored, as they are on a stock Linux desktop.

## Related projects

- [hid-lenovo](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-lenovo.c): the Linux driver whose
  behaviour this mirrors. tpscroll is an independent implementation, not derived from its code.
- [hoyaaaa/trackpoint-daemon-macos](https://github.com/hoyaaaa/trackpoint-daemon-macos): a fuller macOS menu-bar
  app for the same keyboard, with a settings UI, F-key actions and modifier remapping. Over Bluetooth it keeps
  macOS's accelerated vertical scroll and synthesizes horizontal scroll only. tpscroll is the minimal, Linux-like
  alternative.
- [telecastr/tp2ctl](https://github.com/telecastr/tp2ctl): a Linux tool with USB captures of Lenovo's Windows utility.
- [pgkt04/tp2-driver-reversal](https://github.com/pgkt04/tp2-driver-reversal): notes on the Windows driver.

## Development

```sh
./build.sh            # build/TPScroll.app, compiled in Swift 6 language mode (strict concurrency)
./build.sh tprec      # build/TPRec.app, the diagnostic recorder
xcrun swift-format lint --strict --configuration .swift-format Sources/tpscroll.swift tools/tprec/tprec.swift
shellcheck build.sh install.sh uninstall.sh
```

CI runs the same steps on every push. The agent's threading model is checked by the compiler. HID, power, timer
and signal callbacks run on the main actor, and each callback asserts this with `MainActor.assumeIsolated`. The
event tap runs on its own thread and only reads a lock-protected snapshot. The only shared mutable state is a few
`nonisolated(unsafe)` variables that only the tap thread ever touches.

## License

MIT, see [LICENSE](LICENSE).
