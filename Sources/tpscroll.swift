// SPDX-License-Identifier: MIT
// tpscroll — Linux-style middle-button scrolling for the Lenovo ThinkPad TrackPoint Keyboard II on macOS.
// A user-space take on what Linux's hid-lenovo driver does for this keyboard (independent implementation).
//
// * Switches the keyboard to "native" middle-button mode (command 09 01), plus fn-lock (05 x) and sensitivity (02 x):
//     Bluetooth  17EF:60E1  output  report 0x18, buffer [18 cmd val 00…]
//     USB recv.  17EF:60EE  feature report 0x13, buffer [13 cmd val]  (mouse interface; buffer must start with 0x13)
//   and back to compatibility mode (09 00) when stopped, so the keyboard keeps working without tpscroll.
// * Native input reports (identical on both transports):
//     0x15  byte 2 bit 0x04 = middle button      0x16 = [h, v] int8 scroll steps      0x05 byte 1 = hotkey code
// * Posts linear pixel scroll for both axes (fixed pixels per step, no acceleration — like a Linux wheel notch),
//   emits a middle click on release only if nothing scrolled (hid-lenovo's middle-click workaround).
// * Over Bluetooth the keyboard additionally keeps sending the standard GD.Wheel (report 0x02); macOS's resulting
//   scroll events are dropped per device, using the undocumented CGEvent field 87 (sender IOHIDEventService ID).
// * Fn+F4 (mic mute) toggles the default input device's mute; the Fn+F7 hotkey's Win+P (⌘P/⌥P) is swallowed.
//
// Threads: HID callbacks, device commands, settings and logging run on the main run loop; the event tap runs on its
// own thread and only reads a small locked snapshot (TapState), so nothing slow ever sits in the system's input path.
//
// Settings (defaults domain io.github.lebdron.tpscroll), re-read every few seconds:
//   pixelsPerStep (float 1…500, 20) · direction (system|natural|traditional) · invertHorizontal (bool)
//   swallowF7 (bool, true) · fnLock (int 0/1, 1) · sensitivity (int 1…255, 5) — applied on (re)connect
//   debugKeys (bool) — logs F7 detection
import Foundation
import IOKit
import IOKit.hid
import IOKit.pwr_mgt
import CoreGraphics
import CoreAudio
import ApplicationServices
import os

nonisolated let MAGIC: Int64 = 0x4C4E5650  // tags our own posted events
nonisolated let VID = 0x17EF, PID_BT = 0x60E1, PID_USB = 0x60EE
nonisolated var SUITE: CFString { "io.github.lebdron.tpscroll" as CFString }
nonisolated func now() -> Double { CFAbsoluteTimeGetCurrent() }

// MARK: - logging (thread-safe; called from the tap thread too)

nonisolated let logFormatter: DateFormatter = {  // DateFormatter is thread-safe; logLock keeps lines whole
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f
}()
nonisolated let logLock = NSLock()
func log(_ s: String) {
    logLock.lock(); defer { logLock.unlock() }
    FileHandle.standardError.write("\(logFormatter.string(from: Date())) \(s)\n".data(using: .utf8)!)
}

// MARK: - settings (main thread; CFPreferences may do IPC)

struct Settings: Equatable {
    var px = 20.0, direction = "system", invertH = false, swallowF7 = true, fnLock = 1, sensitivity = 5,
        debugKeys = false
    var natural = true  // resolved scroll direction
    static func load() -> Settings {
        CFPreferencesAppSynchronize(SUITE)
        func v(_ k: String) -> Any? { CFPreferencesCopyAppValue(k as CFString, SUITE) }
        var s = Settings()
        if let x = v("pixelsPerStep") as? Double, x.isFinite { s.px = min(max(x, 1), 500) }
        if let x = v("direction") as? String { s.direction = x }
        if let x = v("invertHorizontal") as? Bool { s.invertH = x }
        if let x = v("swallowF7") as? Bool { s.swallowF7 = x }
        if let x = v("debugKeys") as? Bool { s.debugKeys = x }
        if let x = v("fnLock") as? Int { s.fnLock = x != 0 ? 1 : 0 }
        if let x = v("sensitivity") as? Int, (1...255).contains(x) { s.sensitivity = x }
        switch s.direction {
        case "natural": s.natural = true
        case "traditional": s.natural = false
        default:
            CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
            s.natural =
                (CFPreferencesCopyAppValue(
                    "com.apple.swipescrolldirection" as CFString,
                    kCFPreferencesAnyApplication) as? Bool) ?? true  // absent = natural
        }
        return s
    }
}
var settings = Settings.load()

// MARK: - state shared with the tap thread

struct TapState {
    // sender IDs of keyboards confirmed in native mode -> their GD.Wheel scroll is a duplicate
    var dropIDs = Set<UInt64>()
    var knownIDs = Set<UInt64>()  // sender IDs of all matched keyboard interfaces
    var anyKeyboard = false
    var middleHeld = false  // for the timing fallback only
    var lastMiddleRelease = 0.0
    var lastNativeWheel = 0.0
    var f7Time = 0.0  // when the Fn+F7 Win+P burst was seen at HID level
    var swallowF7 = true
    var debugKeys = false
}
nonisolated let shared = OSAllocatedUnfairLock(initialState: TapState())

// MARK: - per-device state

/// One matched IOHIDDevice. Bluetooth: one device does everything. USB receiver: three interfaces — the mouse
/// interface (1:2) takes commands and carries the native reports, the keyboard interface (1:6) sends report-ID-less
/// keyboard reports, the vendor interface (FF00:5) is unused.
@MainActor final class Keyboard {
    let dev: IOHIDDevice
    let usb: Bool
    let isCommandTarget: Bool  // receives commands, sends 0x15/0x16/0x05 and the standard mouse report
    let sendsKeyboard: Bool  // sends boot-keyboard reports (BT: report 0x01; USB: report ID 0 on 1:6)
    let group: String  // interfaces of one physical connection share this
    let name: String
    let buffer: UnsafeMutablePointer<UInt8>
    static let bufferSize = 64

    var senderIDs = Set<UInt64>()
    var nativeConfirmed = false  // a native report arrived since the last configure
    var middleDown = false
    var scrolledWhileDown = false
    var lastHotkey: UInt8 = 0
    var lastConfigure = 0.0
    var guiDown = false, guiDownTime = 0.0

    init(_ dev: IOHIDDevice) {
        func prop(_ k: String) -> Int { (IOHIDDeviceGetProperty(dev, k as CFString) as? Int) ?? 0 }
        self.dev = dev
        usb = prop(kIOHIDProductIDKey) == PID_USB
        let page = prop(kIOHIDPrimaryUsagePageKey), usage = prop(kIOHIDPrimaryUsageKey)
        isCommandTarget = !usb || (page == 1 && usage == 2)
        sendsKeyboard = !usb || (page == 1 && usage == 6)
        group = "\(prop(kIOHIDProductIDKey))-\(prop(kIOHIDLocationIDKey))"
        name = String(format: "%@ %x:%x", usb ? "USB receiver" : "Bluetooth", page, usage)
        buffer = .allocate(capacity: Keyboard.bufferSize)
    }
}
var keyboards: [Keyboard] = []

/// Recompute the tap's view of the keyboards. Main thread.
@MainActor func publish() {
    var drop = Set<UInt64>(), known = Set<UInt64>()
    let nativeGroups = Set(keyboards.filter { $0.isCommandTarget && $0.nativeConfirmed }.map(\.group))
    for k in keyboards {
        known.formUnion(k.senderIDs)
        if nativeGroups.contains(k.group) { drop.formUnion(k.senderIDs) }
    }
    let held = keyboards.contains { $0.middleDown }
    let s = settings, any = !keyboards.isEmpty, dropIDs = drop, knownIDs = known
    shared.withLock {
        $0.dropIDs = dropIDs; $0.knownIDs = knownIDs; $0.anyKeyboard = any; $0.middleHeld = held
        $0.swallowF7 = s.swallowF7; $0.debugKeys = s.debugKeys
    }
}

// MARK: - device commands

@MainActor func sendCmd(_ k: Keyboard, _ a: UInt8, _ b: UInt8) {
    var buf: [UInt8], r: IOReturn
    if k.usb {
        // hid-lenovo passes {0x18, a, b} to hid_hw_raw_request(…, 0x13, FEATURE); on macOS the receiver only reacts
        // when the buffer starts with the report ID (probed: [18 09 01] -> ok but ignored, [13 09 01] -> native).
        buf = [0x13, a, b]
        r = IOHIDDeviceSetReport(k.dev, kIOHIDReportTypeFeature, 0x13, &buf, buf.count)
    } else {
        buf = [0x18, a, b, 0, 0, 0, 0, 0, 0]
        r = IOHIDDeviceSetReport(k.dev, kIOHIDReportTypeOutput, 0x18, &buf, buf.count)
    }
    let bytes = buf.prefix(3).map { String(format: "%02x", $0) }.joined(separator: " ")
    let pad = buf.count > 3 ? " (+\(buf.count - 3) zero pad)" : ""
    let result = r == kIOReturnSuccess ? "ok" : String(format: "0x%08x", r)
    log("cmd \(k.usb ? "feature" : "output") \(bytes)\(pad) -> \(result)")
}

@MainActor func resetMiddle(_ k: Keyboard) {
    k.middleDown = false; k.scrolledWhileDown = false
}

@MainActor func configure(_ k: Keyboard, reason: String) {
    guard k.isCommandTarget else { return }
    log(
        "configuring keyboard [\(k.name)] (\(reason)): native middle, fnLock=\(settings.fnLock), sensitivity=\(settings.sensitivity)"
    )
    k.nativeConfirmed = false
    resetMiddle(k)
    k.lastConfigure = now()
    publish()
    // Lenovo's Windows tool waits 50 ms after each command. Chain them: a BLE write can block for ~100 ms, so fixed
    // offsets would bunch the later commands up right after it.
    sendChain(k, [(0x09, 0x01), (0x05, UInt8(settings.fnLock)), (0x02, UInt8(settings.sensitivity))])
}
@MainActor func sendChain(_ k: Keyboard, _ cmds: [(UInt8, UInt8)]) {
    guard let c = cmds.first, keyboards.contains(where: { $0 === k }) else { return }
    sendCmd(k, c.0, c.1)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak k] in
        if let k = k { sendChain(k, Array(cmds.dropFirst())) }
    }
}

// MARK: - event posting (main thread)

@MainActor func post(_ e: CGEvent?) {
    guard let e = e else { return }
    e.setIntegerValueField(.eventSourceUserData, value: MAGIC)
    // post downstream of HID-level taps (ours and other tools'), so synthesized scroll isn't re-filtered/re-accelerated
    e.post(tap: .cgSessionEventTap)
}
@MainActor func postScroll(h: Int, v: Int) {
    let sign = settings.natural ? -1.0 : 1.0
    // HID: v>0 = push up, h>0 = push right. CG pixel scroll: wheel1>0 = scroll up, wheel2>0 = scroll left.
    let w1 = Int32((Double(v) * settings.px * sign).rounded())
    var w2 = Int32((Double(-h) * settings.px * sign).rounded())
    if settings.invertH { w2 = -w2 }
    post(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: w1, wheel2: w2, wheel3: 0))
}
@MainActor func postMiddleClick() {
    let loc = CGEvent(source: nil)?.location ?? .zero
    for t in [CGEventType.otherMouseDown, .otherMouseUp] {
        let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: loc, mouseButton: .center)
        e?.setIntegerValueField(.mouseEventClickState, value: 1)
        post(e)
    }
}

// MARK: - mic mute (Fn+F4), off the main thread: CoreAudio calls can block

func toggleMicMute() {
    var dev = AudioObjectID(0); var sz = UInt32(MemoryLayout<AudioObjectID>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &dev) == noErr,
        dev != 0
    else {
        log("mic mute: no default input device"); return
    }
    var mute = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)
    var settable: DarwinBoolean = false
    if AudioObjectHasProperty(dev, &mute), AudioObjectIsPropertySettable(dev, &mute, &settable) == noErr,
        settable.boolValue
    {
        var m: UInt32 = 0; sz = 4
        AudioObjectGetPropertyData(dev, &mute, 0, nil, &sz, &m)
        m = m == 0 ? 1 : 0
        let r = AudioObjectSetPropertyData(dev, &mute, 0, nil, 4, &m)
        log("mic mute -> \(m == 1 ? "MUTED" : "unmuted") (\(r))"); return
    }
    // Fallback: input volume 0 <-> previous
    var vol = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(dev, &vol) else { log("mic mute: device has neither mute nor volume"); return }
    var cur: Float32 = 0; sz = 4
    AudioObjectGetPropertyData(dev, &vol, 0, nil, &sz, &cur)
    let key = "savedInputVolume" as CFString
    var newVol: Float32
    if cur > 0 {
        CFPreferencesSetAppValue(key, cur as CFNumber, SUITE); newVol = 0
    } else {
        newVol = (CFPreferencesCopyAppValue(key, SUITE) as? Float32) ?? 0.75
    }
    CFPreferencesAppSynchronize(SUITE)
    let r = AudioObjectSetPropertyData(dev, &vol, 0, nil, 4, &newVol)
    log("mic mute (volume fallback) -> \(newVol == 0 ? "MUTED" : "volume \(newVol)") (\(r))")
}

// MARK: - HID input (main thread)

func s8(_ b: UInt8) -> Int { Int(Int8(bitPattern: b)) }

@MainActor func handleKeyboard(_ k: Keyboard, mods: UInt8, keys: [UInt8]) {
    let gui = mods & 0x88 != 0
    if gui && !k.guiDown { k.guiDownTime = now() }
    k.guiDown = gui
    // The Fn+F7 hotkey sends Win down and Win+P within ~1 ms; a person never does that within 20 ms.
    let f7 = gui && keys.contains(0x13) && now() - k.guiDownTime < 0.02
    if f7 { let t = now(); shared.withLock { $0.f7Time = t } }
    if settings.debugKeys && (gui || keys.contains(0x13)) {
        log(
            String(
                format: "dbg HID kbd mods=%02x keys=%@ f7=%@", mods,
                keys.filter { $0 != 0 }.map { String(format: "%02x", $0) }.joined(separator: ","), f7 ? "YES" : "no"))
    }
}

@MainActor func handleReport(_ k: Keyboard, _ id: UInt32, _ p: UnsafePointer<UInt8>, _ len: Int) {
    if k.sendsKeyboard {
        if k.usb && id == 0 && len >= 3 { handleKeyboard(k, mods: p[0], keys: (2..<len).map { p[$0] }); return }
        if !k.usb && id == 0x01 && len >= 4 { handleKeyboard(k, mods: p[1], keys: (3..<len).map { p[$0] }); return }
    }
    guard k.isCommandTarget else { return }
    switch id {
    case 0x15 where len >= 3:  // native middle button
        if !k.nativeConfirmed { k.nativeConfirmed = true; publish() }
        let down = p[2] & 0x04 != 0
        if down == k.middleDown { return }
        k.middleDown = down
        if down {
            k.scrolledWhileDown = false
        } else {
            if !k.scrolledWhileDown { postMiddleClick() }
            k.scrolledWhileDown = false
            let t = now(); shared.withLock { $0.lastMiddleRelease = t }
        }
        let held = keyboards.contains { $0.middleDown }
        shared.withLock { $0.middleHeld = held }
    case 0x16 where len >= 3:  // native scroll steps [h, v]
        if !k.nativeConfirmed { k.nativeConfirmed = true; publish() }
        let h = s8(p[1]), v = s8(p[2])
        if h == 0 && v == 0 { return }
        let t = now(); shared.withLock { $0.lastNativeWheel = t }
        k.scrolledWhileDown = true
        postScroll(h: h, v: v)
    case 0x05 where len >= 2:  // vendor hotkey (one code; 00 on release)
        let code = p[1]
        if code == 0xbb && code != k.lastHotkey { DispatchQueue.global(qos: .userInitiated).async { toggleMicMute() } }
        k.lastHotkey = code
    case 0x02 where !k.usb && len >= 2, 0x01 where k.usb && len >= 2:  // standard mouse report
        // Button 3 only appears in compatibility mode: the keyboard lost native mode (e.g. its own power cycle)
        if p[1] & 0x04 != 0 && now() - k.lastConfigure > 2 {
            log("compat-mode Button3 seen [\(k.name)] -> native mode was lost")
            configure(k, reason: "mode lost")
        }
    default: break
    }
}

// MARK: - sender IDs (CGEvent field 87)

// Undocumented CGEvent field 87 = registry entry ID of the IOHIDEventService that produced the event
// (observed on macOS 27.2: TrackPoint wheel -> its AppleUserHIDEventDriver, trackpad -> AppleMultitouchDevice).
// If it ever reads 0 / unknown, a timing-based fallback is used instead.
nonisolated let kSenderIDField = unsafeBitCast(UInt32(87), to: CGEventField.self)

func eventServiceIDs(of dev: IOHIDDevice) -> Set<UInt64> {
    var ids = Set<UInt64>()
    let svc = IOHIDDeviceGetService(dev)
    guard svc != 0 else { return ids }
    var it: io_iterator_t = 0
    guard
        IORegistryEntryCreateIterator(svc, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &it)
            == KERN_SUCCESS
    else { return ids }
    defer { IOObjectRelease(it) }
    while case let e = IOIteratorNext(it), e != 0 {
        if IOObjectConformsTo(e, "IOHIDEventService") != 0 {
            var id: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(e, &id) == KERN_SUCCESS { ids.insert(id) }
        }
        IOObjectRelease(e)
    }
    return ids
}
@MainActor func refreshSenderIDs(_ k: Keyboard) {
    let ids = eventServiceIDs(of: k.dev)
    guard ids != k.senderIDs else { return }
    k.senderIDs = ids
    log("event service ID(s) for [\(k.name)]: " + ids.map { String(format: "0x%llx", $0) }.joined(separator: ", "))
    publish()
}

// MARK: - device matching

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatchingMultiple(
    mgr,
    [
        [kIOHIDVendorIDKey: VID, kIOHIDProductIDKey: PID_BT],
        [kIOHIDVendorIDKey: VID, kIOHIDProductIDKey: PID_USB],
    ] as CFArray)
IOHIDManagerRegisterDeviceMatchingCallback(
    mgr,
    { _, _, _, dev in
        MainActor.assumeIsolated {  // scheduled on the main run loop
            let k = Keyboard(dev)
            keyboards.append(k)
            log("keyboard connected [\(k.name)]")
            IOHIDDeviceRegisterInputReportCallback(
                dev, k.buffer, Keyboard.bufferSize,
                { ctx, _, _, _, rid, rep, len in
                    MainActor.assumeIsolated {
                        handleReport(Unmanaged<Keyboard>.fromOpaque(ctx!).takeUnretainedValue(), rid, rep, len)
                    }
                }, Unmanaged.passUnretained(k).toOpaque())
            publish()
            // the event service is created asynchronously after the device appears; look it up a few times
            for d in [0.5, 2.0, 5.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak k] in
                    if let k = k, keyboards.contains(where: { $0 === k }) { refreshSenderIDs(k) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { [weak k] in
                guard let k = k, k.isCommandTarget, keyboards.contains(where: { $0 === k }) else { return }
                if !keyboards.contains(where: { $0.group == k.group && !$0.senderIDs.isEmpty }) {
                    log("no event service IDs for [\(k.name)]; duplicate-scroll filter uses the timing fallback")
                }
            }
            // small delay: a BLE link may not accept writes in the very first moments after (re)connect
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak k] in
                if let k = k, keyboards.contains(where: { $0 === k }) { configure(k, reason: "connect") }
            }
        }
    }, nil)
IOHIDManagerRegisterDeviceRemovalCallback(
    mgr,
    { _, _, _, dev in
        MainActor.assumeIsolated {
            guard let i = keyboards.firstIndex(where: { $0.dev === dev }) else { return }
            let k = keyboards.remove(at: i)
            // stop callbacks, then free the buffer
            IOHIDDeviceRegisterInputReportCallback(dev, k.buffer, Keyboard.bufferSize, nil, nil)
            k.buffer.deallocate()
            log("keyboard disconnected [\(k.name)]")
            publish()
        }
    }, nil)

// MARK: - event tap (own thread)

// Tap-thread state: only touched on the tap thread (tapRunLoop is written there once, before tapReady is signalled).
nonisolated(unsafe) var tap: CFMachPort?
nonisolated(unsafe) var tapSource: CFRunLoopSource?
nonisolated(unsafe) var tapRunLoop: CFRunLoop!
nonisolated(unsafe) var droppingP = false
nonisolated let kVK_P: Int64 = 35

func tapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ ev: CGEvent, _ ctx: UnsafeMutableRawPointer?)
    -> Unmanaged<CGEvent>?
{
    let pass = Unmanaged.passUnretained(ev)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        log("event tap disabled (\(type.rawValue)), re-enabling")
        if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
        return pass
    }
    if ev.getIntegerValueField(.eventSourceUserData) == MAGIC { return pass }
    let st = shared.withLock { $0 }
    switch type {
    case .scrollWheel:
        // Drop the duplicate scroll macOS makes from this keyboard's GD.Wheel (Bluetooth only; the USB receiver
        // sends none) — only for keyboards confirmed in native mode, so a failed mode switch keeps normal scrolling.
        let sender = UInt64(bitPattern: ev.getIntegerValueField(kSenderIDField))
        if sender != 0 && !st.knownIDs.isEmpty {
            return st.dropIDs.contains(sender) ? nil : pass
        }
        // Fallback (sender ID unknown): non-continuous wheel events while the TrackPoint scrolls.
        if ev.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 && st.anyKeyboard {
            let t = now()
            if st.middleHeld || t - st.lastMiddleRelease < 0.15 || t - st.lastNativeWheel < 0.15 { return nil }
        }
    case .flagsChanged:
        if st.debugKeys { log(String(format: "dbg CG flagsChanged flags=%llx", ev.flags.rawValue)) }
    case .keyDown, .keyUp:
        let kc = ev.getIntegerValueField(.keyboardEventKeycode)
        if st.debugKeys && (kc == kVK_P || !ev.flags.intersection([.maskCommand, .maskAlternate]).isEmpty) {
            log(
                String(
                    format: "dbg CG %@ keycode=%lld flags=%llx sinceF7HID=%.1fms",
                    type == .keyDown ? "keyDown" : "keyUp  ",
                    kc, ev.flags.rawValue, (now() - st.f7Time) * 1000))
        }
        if type == .keyUp {
            if droppingP && kc == kVK_P { droppingP = false; return nil }
            return pass
        }
        // Win becomes ⌘ or ⌥ depending on the user's Modifier Keys setting; the HID burst (see handleKeyboard)
        // reliably arrives 2–5 ms before this keyDown.
        if st.swallowF7 && kc == kVK_P && !ev.flags.intersection([.maskCommand, .maskAlternate]).isEmpty
            && now() - st.f7Time < 0.3
        {
            droppingP = true; log("swallowed F7 hotkey (Win+P)"); return nil
        }
    default: break
    }
    return pass
}

/// (Re)create the tap with or without keyboard events. Runs on the tap thread.
func installTap(keys: Bool) {
    if let t = tap {
        CGEvent.tapEnable(tap: t, enable: false)
        if let s = tapSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), s, .commonModes) }
        CFMachPortInvalidate(t)
        tap = nil; tapSource = nil
    }
    var types: [CGEventType] = [.scrollWheel]
    if keys { types += [.flagsChanged, .keyDown, .keyUp] }
    let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    while tap == nil {
        tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: tapCallback, userInfo: nil)
        if tap == nil { log("event tap creation failed, retrying"); Thread.sleep(forTimeInterval: 3) }
    }
    tapSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), tapSource, .commonModes)
    CGEvent.tapEnable(tap: tap!, enable: true)
    log("event tap: scroll\(keys ? " + keys (for F7)" : " only")")
}
func onTapThread(_ block: @escaping () -> Void) {
    CFRunLoopPerformBlock(tapRunLoop, CFRunLoopMode.commonModes.rawValue, block)
    CFRunLoopWakeUp(tapRunLoop)
}
func tapNeedsKeys(_ s: Settings) -> Bool { s.swallowF7 || s.debugKeys }

// MARK: - power (wake)

var rootPort: io_connect_t = 0
var notifier: io_object_t = 0
var notifyPort: IONotificationPortRef?
@MainActor func setupWake() {
    rootPort = IORegisterForSystemPower(
        nil, &notifyPort,
        { _, _, msg, arg in
            MainActor.assumeIsolated {  // main run loop
                switch msg {
                case 0xE000_0270, 0xE000_0280:  // kIOMessageCanSystemSleep, kIOMessageSystemWillSleep
                    IOAllowPowerChange(rootPort, Int(bitPattern: arg))
                case 0xE000_0300:  // kIOMessageSystemHasPoweredOn
                    log("system woke")
                    for k in keyboards { resetMiddle(k) }  // a release may have been lost while asleep
                    publish()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        for k in keyboards { refreshSenderIDs(k); configure(k, reason: "wake") }
                    }
                default: break
                }
            }
        }, &notifier)
    if let p = notifyPort {
        CFRunLoopAddSource(
            CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(p).takeUnretainedValue(), .defaultMode)
    }
}

// MARK: - shutdown: hand the keyboard back in compatibility mode

@MainActor func restoreAndExit(_ sig: Int32) -> Never {
    let targets = keyboards.filter(\.isCommandTarget)
    if !targets.isEmpty { log("stopping (signal \(sig)): restoring compatibility mode") }
    for k in targets { sendCmd(k, 0x09, 0x00); usleep(50_000) }
    exit(0)
}
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)  // handled by the dispatch source on the main queue, where IOKit calls are safe
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { MainActor.assumeIsolated { () -> Void in restoreAndExit(sig) } }  // main queue
    src.resume()
    signalSources.append(src)
}

// MARK: - startup

log("tpscroll starting, settings: px=\(settings.px) direction=\(settings.direction) natural=\(settings.natural)")

if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
    // A running process never sees a new Input Monitoring grant, so exit and let launchd restart us. Request only
    // once: every request queues another system prompt, and we restart every ~10 s while waiting.
    if CFPreferencesCopyAppValue("askedInputMonitoring" as CFString, SUITE) == nil {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        CFPreferencesSetAppValue("askedInputMonitoring" as CFString, kCFBooleanTrue, SUITE)
        CFPreferencesAppSynchronize(SUITE)
    }
    log("Input Monitoring not granted; exiting so launchd restarts us (grant is only seen by a fresh process)")
    CFRunLoopRunInMode(.defaultMode, 10, false); exit(1)
}
if !AXIsProcessTrusted() {
    // key = kAXTrustedCheckOptionPrompt (the imported global isn't concurrency-safe)
    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    log("waiting for Accessibility permission…")
    while !AXIsProcessTrusted() { CFRunLoopRunInMode(.defaultMode, 3, false) }
    log("Accessibility granted")
}

// event tap thread
nonisolated let tapReady = DispatchSemaphore(value: 0)
var tapHasKeys = tapNeedsKeys(settings)  // main thread's record of what the tap currently listens to
let initialKeys = tapHasKeys
let tapThread = Thread { [initialKeys] in
    tapRunLoop = CFRunLoopGetCurrent()  // published to the main thread by tapReady below
    installTap(keys: initialKeys)
    tapReady.signal()
    CFRunLoopRun()
}
tapThread.name = "event tap"
tapThread.qualityOfService = .userInteractive
tapThread.start()
tapReady.wait()

publish()
IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
let r = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
log("HID manager open: \(r == kIOReturnSuccess ? "ok" : String(format: "0x%08x", r)); waiting for keyboard")
setupWake()

// settings: poll (another process writes them via `defaults`); apply changes without touching the tap thread's path
Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
    MainActor.assumeIsolated {  // main run loop
        let s = Settings.load()
        guard s != settings else { return }
        log(
            "settings changed: px=\(s.px) direction=\(s.direction) natural=\(s.natural) invertH=\(s.invertH) swallowF7=\(s.swallowF7)"
        )
        settings = s
        publish()
        if tapNeedsKeys(s) != tapHasKeys {
            tapHasKeys = tapNeedsKeys(s)
            let keys = tapHasKeys
            onTapThread { installTap(keys: keys) }
        }
    }
}
CFRunLoopRun()
