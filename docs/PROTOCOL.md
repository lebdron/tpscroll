# TrackPoint Keyboard II protocol notes (macOS)

These notes come from recordings made with `tools/tprec` on macOS 27.2, checked against Linux `hid-lenovo`,
tp2ctl's USB captures of Lenovo's Windows utility, and a reverse-engineering write-up of that utility.

## Devices

| Transport | VID:PID | macOS HID devices |
|---|---|---|
| Bluetooth LE | `17EF:60E1` | 1 device: keyboard, mouse, consumer and vendor collections |
| 2.4 GHz USB receiver | `17EF:60EE` | 3 interfaces: keyboard `1:6` (reports have no ID), mouse `1:2` (mouse, consumer and vendor collections), vendor `FF00:5` |

## Commands

Each command is three bytes, `cmd val` preceded by the report ID:

| cmd | meaning | Linux default |
|---|---|---|
| `09` | middle button / scrolling: `01` = native, `00` = compatibility (keyboard scrolls by itself) | `01` |
| `05` | fn-lock: `1` = F1–F12, with hotkeys on Fn | `1` |
| `02` | TrackPoint sensitivity | `5` |

How to send them from macOS with `IOHIDDeviceSetReport`:

- **Bluetooth**: report type *Output*, ID `0x18`, buffer `18 cmd val` (zero-padding to 9 bytes also works).
- **USB receiver**: report type *Feature*, ID `0x13`, buffer **`13 cmd val`**, sent to the mouse interface (`1:2`).
  The Linux driver passes `18 cmd val` to `hid_hw_raw_request(…, 0x13, FEATURE)`. Copying that literally on macOS
  returns success but the receiver ignores it, because the buffer has to start with `0x13`. Lenovo's Windows utility
  sends the same `13 cmd val …` (9 bytes), sends each command twice, and waits 50 ms after each one.

The keyboard forgets these settings when it is power-cycled.

**Do not send `01 03`.** That command is meant for the older Compact keyboard, and on Keyboard II it breaks Fn+Esc
(noted by trackpoint-daemon-macos).

## Default (compatibility) mode, as macOS sees it

- **Bluetooth**: the mouse report `0x02` carries buttons 1–3, X, Y and a vertical wheel. It has **no horizontal
  axis**. Holding middle sends Button 3 immediately (macOS turns it into a middle-button down), and moving the
  TrackPoint produces vertical wheel steps of ±1 at about 65 Hz. Sideways movement produces nothing at all.
- **USB**: the mouse report `0x01` carries buttons, X, Y, wheel and AC Pan.

## Native mode reports

| Report | Contents |
|---|---|
| `0x15` | middle button: byte 2 bit `0x04` (Bluetooth: 9 bytes, USB: 3 bytes). Over USB the descriptor matches: vendor usages `0xF1–0xFC` as bits, with `0xFB` = middle. Over Bluetooth it declares an 8-byte array instead, so read the raw bytes. |
| `0x16` | `[h, v]` signed bytes, ±1 (sometimes ±2) about every 15 ms while scrolling. `v > 0` = up, `h > 0` = right. |
| `0x05` | hotkey code (Bluetooth `05 code 00`, USB `05 code`), with `00` on release. Over Bluetooth the descriptor wrongly declares this report as 13 bits (usages `0xF1–0xFC`) even though it carries a code byte; Linux patches the descriptor (`lenovo_report_fixup`). |

Hotkey codes, with Fn-lock on, sent while Fn is held:

| Key | Code | | Key | Code |
|---|---|---|---|---|
| F4 mic mute | `bb` | | F11 keyboard settings | `b7` |
| F8 notification centre | `c1` | | F12 ★ | `b8` |
| F9 control panel | `bc` | | Fn+PrtSc snipping tool | `b9` |
| F10 Bluetooth | `b6` | | Fn+Esc fn-lock toggle | `b5` (the keyboard toggles fn-lock itself; a driver should track it so re-sending `05` keeps the user's choice, as Linux does) |

F1–F3 are standard consumer keys (mute, volume down, volume up) and F5–F6 send brightness down/up (consumer `0x70`,
`0x6F`), all handled by macOS. **F7 sends Win+P** as normal keyboard input: Win down, Win+P, Win, all within 1 ms.
The keyboard then **holds Win for about 1.1 s and sends no other key reports during that time**. Keys pressed and
released in that window are lost inside the keyboard; typing resumes about 16 ms after Win is released. This
happened in every Bluetooth recording (the USB receiver was not measured). Sending command `01` with `0a` (what
Lenovo's Windows tool sends at startup) or `03` (the Compact keyboard's "F7/F9/F11 as regular keys") changed
nothing on Keyboard II.

**Over Bluetooth the keyboard keeps sending the standard vertical wheel on report `0x02` in native mode**, with
Button 3 no longer set. macOS keeps scrolling from it unless something filters it out. The USB receiver sends no
such duplicate.

## Telling devices apart in event taps

`CGEventGetIntegerValueField(event, 87)` holds the registry entry ID of the `IOHIDEventService` that produced the
event. For the keyboard over Bluetooth this is the `AppleUserHIDEventDriver` under its `IOHIDUserDevice`, and for
the built-in trackpad it is `AppleMultitouchDevice`. To find a device's IDs, take `IOHIDDeviceGetService` and walk
its children (recursively, in the service plane), collecting every entry that conforms to `IOHIDEventService`.
Events you post yourself carry `0`.

## Natural scrolling

macOS reverses wheel direction for natural scrolling before events reach the HID-level tap. Events you post
yourself are never reversed, so apply `com.apple.swipescrolldirection` yourself (macOS treats a missing value as
natural scrolling on).
