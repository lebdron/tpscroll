// SPDX-License-Identifier: MIT
// tprec — diagnostic recorder for the Lenovo TrackPoint Keyboard II on macOS (used to work out tpscroll's protocol).
// Logs device info + decoded HID report descriptor, HID element values, optionally raw input reports, and the
// resulting CGEvents (scroll / middle button) via a listen-only event tap.
//
// Options:
//   --raw              log raw input reports            --xy           also log pointer X/Y
//   --all              any vendor, not just 0x17EF      --no-tap       no CGEvent tap
//   --dump-fields      log every non-zero integer field of scroll CGEvents (how field 87 was found)
//   --send "18 09 01"  send an output report (first byte = report ID) on every device match
//   --probe-usb        try USB-receiver command formats one by one; hold middle + scroll after each
//   --seconds N        run time (default 180)           --log FILE     log to FILE instead of stdout
// Run it as an app (build.sh tprec; open build/TPRec.app --args …) so it gets its own Input Monitoring grant.
import Foundation
import IOKit
import IOKit.hid
import CoreGraphics

// ---------- args ----------
var args = Array(CommandLine.arguments.dropFirst())
func flag(_ n: String) -> Bool { if let i = args.firstIndex(of: n) { args.remove(at: i); return true }; return false }
func opt(_ n: String) -> String? {
    if let i = args.firstIndex(of: n), i + 1 < args.count {
        let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
    }; return nil
}
let showXY = flag("--xy")  // also log GenericDesktop X/Y (pointer motion)
let showRaw = flag("--raw")  // log raw input reports
let allVendors = flag("--all")  // don't filter by VID 0x17EF
let noTap = flag("--no-tap")
let probeUSB = flag("--probe-usb")  // try USB-receiver command formats one by one, detect native vs compat
let dumpFields = flag("--dump-fields")  // log every non-zero integer field of scroll events
// --send "18 09 01": output report, first byte = report ID; padded to MaxOutputReportSize. Sent on every device match.
let sendBytes: [UInt8]? = opt("--send").map { $0.split(separator: " ").compactMap { UInt8($0, radix: 16) } }
let seconds = Double(opt("--seconds") ?? "180") ?? 180
let logPath = opt("--log")

let logFH: FileHandle? = {
    guard let p = logPath else { return nil }
    FileManager.default.createFile(atPath: p, contents: nil)
    return FileHandle(forWritingAtPath: p)
}()
let t0 = Date()
func log(_ s: String) {
    let line = String(format: "%8.3f ", Date().timeIntervalSince(t0)) + s + "\n"
    if let fh = logFH {
        fh.write(line.data(using: .utf8)!)
    } else {
        FileHandle.standardOutput.write(line.data(using: .utf8)!)
    }
}
func hex(_ p: UnsafePointer<UInt8>, _ n: Int) -> String {
    (0..<n).map { String(format: "%02x", p[$0]) }.joined(separator: " ")
}

// ---------- HID report descriptor decoder ----------
func decodeDescriptor(_ d: [UInt8]) -> String {
    var out = "", i = 0, indent = 0, usagePage: UInt32 = 0
    let main: [UInt8: String] = [
        0x80: "Input", 0x90: "Output", 0xB0: "Feature", 0xA0: "Collection", 0xC0: "End Collection",
    ]
    let glob: [UInt8: String] = [
        0x04: "Usage Page", 0x14: "Logical Min", 0x24: "Logical Max", 0x34: "Physical Min",
        0x44: "Physical Max", 0x54: "Unit Exponent", 0x64: "Unit", 0x74: "Report Size", 0x84: "Report ID",
        0x94: "Report Count", 0xA4: "Push", 0xB4: "Pop",
    ]
    let loc: [UInt8: String] = [0x08: "Usage", 0x18: "Usage Min", 0x28: "Usage Max"]
    while i < d.count {
        let b = d[i]
        if b == 0xFE {  // long item
            let len = i + 1 < d.count ? Int(d[i + 1]) : 0; out += "  [long item len \(len)]\n"; i += 3 + len; continue
        }
        let sizeCode = Int(b & 3), size = sizeCode == 3 ? 4 : sizeCode, tag = b & 0xFC
        var u: UInt32 = 0
        for k in 0..<size where i + 1 + k < d.count { u |= UInt32(d[i + 1 + k]) << (8 * k) }
        var s: Int64 = Int64(u)
        if size > 0 && size < 4 {
            let bits = size * 8; if u & (1 << (bits - 1)) != 0 { s = Int64(u) - (1 << bits) }
        } else if size == 4 {
            s = Int64(Int32(bitPattern: u))
        }
        let bytes = (0...size).compactMap { i + $0 < d.count ? String(format: "%02x", d[i + $0]) : nil }.joined(
            separator: " ")
        if tag == 0xC0 { indent = max(0, indent - 1) }
        var name = main[tag] ?? glob[tag] ?? loc[tag] ?? String(format: "tag 0x%02x", tag)
        var val: String
        switch tag {
        case 0x04: usagePage = u; val = String(format: "0x%04X", u)
        case 0x08, 0x18, 0x28:
            val = size == 4 ? String(format: "0x%08X", u) : String(format: "0x%04X (page 0x%04X)", u, usagePage)
        case 0x80, 0x90, 0xB0:
            val = [(u & 1 != 0 ? "Const" : "Data"), (u & 2 != 0 ? "Var" : "Array"), (u & 4 != 0 ? "Rel" : "Abs")]
                .joined(separator: ",")
        case 0xA0:
            val =
                ["Physical", "Application", "Logical", "Report", "NamedArray", "UsageSwitch", "UsageModifier"][
                    min(Int(u), 6)]
        case 0x84: val = String(format: "0x%02X", u)
        default: val = size == 0 ? "" : "\(s)"
        }
        if tag == 0xC0 { val = ""; name = "End Collection" }
        out +=
            String(repeating: "  ", count: indent + 1)
            + "\(name) \(val)".padding(toLength: 44 - indent * 2, withPad: " ", startingAt: 0) + "; \(bytes)\n"
        if tag == 0xA0 { indent += 1 }
        i += 1 + size
    }
    return out
}

// ---------- names ----------
func usageName(_ page: UInt32, _ usage: UInt32) -> String {
    switch (page, usage) {
    case (0x01, 0x30): return "GD.X"
    case (0x01, 0x31): return "GD.Y"
    case (0x01, 0x38): return "GD.Wheel"
    case (0x0C, 0x238): return "Consumer.ACPan"
    case (0x09, _): return "Button\(usage)"
    case (0x07, _): return String(format: "Key 0x%02X", usage)
    case (0x0C, _): return String(format: "Consumer 0x%03X", usage)
    default: return String(format: "page 0x%04X usage 0x%04X", page, usage) + (page >= 0xFF00 ? " (VENDOR)" : "")
    }
}
func prop(_ dev: IOHIDDevice, _ key: String) -> Any? { IOHIDDeviceGetProperty(dev, key as CFString) }
func devTag(_ dev: IOHIDDevice) -> String {
    let pid = (prop(dev, kIOHIDProductIDKey) as? Int) ?? 0
    let up = (prop(dev, kIOHIDPrimaryUsagePageKey) as? Int) ?? 0, u = (prop(dev, kIOHIDPrimaryUsageKey) as? Int) ?? 0
    return String(format: "[%04x %x:%x]", pid, up, u)
}

// ---------- USB receiver command probe ----------
let variants: [(String, IOHIDReportType, CFIndex, [UInt8])] = [
    ("A feature 0x13 [18 09 01] (Linux literal)", kIOHIDReportTypeFeature, 0x13, [0x18, 0x09, 0x01]),
    ("B feature 0x13 [13 09 01]", kIOHIDReportTypeFeature, 0x13, [0x13, 0x09, 0x01]),
    ("C feature 0x13 [13 09 01 00 00 00 00 00]", kIOHIDReportTypeFeature, 0x13, [0x13, 0x09, 0x01, 0, 0, 0, 0, 0]),
    ("D feature 0x13 [18 09 01 00 00 00 00 00]", kIOHIDReportTypeFeature, 0x13, [0x18, 0x09, 0x01, 0, 0, 0, 0, 0]),
    ("E feature 0x13 [13 18 09 01 00 00 00 00]", kIOHIDReportTypeFeature, 0x13, [0x13, 0x18, 0x09, 0x01, 0, 0, 0, 0]),
    (
        "F output  0x18 [18 09 01 00 00 00 00 00 00] (BT style)", kIOHIDReportTypeOutput, 0x18,
        [0x18, 0x09, 0x01, 0, 0, 0, 0, 0, 0]
    ),
]
var probeIdx = -1, probeDev: IOHIDDevice?, probeVerdictGiven = false
func probeNext() {
    probeIdx += 1
    guard let d = probeDev else { return }
    if probeIdx >= variants.count { log("PROBE: all variants tried, none switched to native mode"); return }
    let (name, type, id, bytes) = variants[probeIdx]
    var b = bytes
    let r = IOHIDDeviceSetReport(d, type, id, &b, b.count)
    probeVerdictGiven = false
    log("PROBE \(name) -> \(r == kIOReturnSuccess ? "ok" : String(format: "0x%08x", r)). Now hold middle + scroll…")
}
func probeReport(_ rid: UInt32, _ p: UnsafePointer<UInt8>, _ len: Int) {
    guard probeIdx >= 0, probeIdx < variants.count, !probeVerdictGiven else { return }
    if rid == 0x16 || rid == 0x15 {
        probeVerdictGiven = true
        log("PROBE RESULT: \(variants[probeIdx].0) => NATIVE MODE ✅ (got report 0x\(String(format: "%02x", rid)))")
    } else if rid == 0x01 && len >= 2 && p[1] & 0x04 != 0 {
        probeVerdictGiven = true; log("PROBE RESULT: \(variants[probeIdx].0) => still compat (Button3)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { probeNext() }  // let the user release
    }
}
func startProbe() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        guard let devs = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>,
            let d = devs.first(where: {
                (prop($0, kIOHIDProductIDKey) as? Int) == 0x60EE && (prop($0, kIOHIDPrimaryUsageKey) as? Int) == 2
                    && (prop($0, kIOHIDPrimaryUsagePageKey) as? Int) == 1
            })
        else { log("PROBE: receiver mouse interface not found"); return }
        probeDev = d
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        // this replaces the --raw logger on this interface (one report callback per device), so log here too
        IOHIDDeviceRegisterInputReportCallback(
            d, buf, 64,
            { _, _, _, _, rid, rep, len in
                if showRaw { log("RAW [60ee 1:2] id=0x\(String(format: "%02x", rid)) len=\(len): \(hex(rep, len))") }
                probeReport(rid, rep, len)
            }, nil)
        probeNext()
    }
}

// ---------- permission ----------
let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
log(
    "Input Monitoring access: \(access == kIOHIDAccessTypeGranted ? "GRANTED" : access == kIOHIDAccessTypeDenied ? "DENIED" : "UNKNOWN (requesting…)")"
)
if access != kIOHIDAccessTypeGranted {
    _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    log("Grant Input Monitoring in System Settings › Privacy & Security, then re-run.")
}

// ---------- IOHIDManager ----------
let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(mgr, allVendors ? nil : [kIOHIDVendorIDKey: 0x17EF] as CFDictionary)

let matchCB: IOHIDDeviceCallback = { _, _, _, dev in
    var s = "DEVICE ADDED \(devTag(dev))\n"
    for k in [
        kIOHIDProductKey, kIOHIDManufacturerKey, kIOHIDTransportKey, kIOHIDVendorIDKey, kIOHIDProductIDKey,
        kIOHIDVersionNumberKey, kIOHIDPrimaryUsagePageKey, kIOHIDPrimaryUsageKey, kIOHIDMaxInputReportSizeKey,
        kIOHIDMaxOutputReportSizeKey, kIOHIDMaxFeatureReportSizeKey, kIOHIDSerialNumberKey, "DeviceUsagePairs",
    ] {
        guard let v = prop(dev, k) else { continue }
        var vs = "\(v)".split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(
            separator: " ")
        if let n = v as? Int, k == kIOHIDVendorIDKey || k == kIOHIDProductIDKey || k.hasPrefix("PrimaryUsage") {
            vs = String(format: "0x%04X", n)
        }
        s += "    \(k) = \(vs)\n"
    }
    if let d = prop(dev, kIOHIDReportDescriptorKey) as? Data {
        let b = [UInt8](d)
        s +=
            "    ReportDescriptor (\(b.count) bytes): " + b.map { String(format: "%02x", $0) }.joined(separator: " ")
            + "\n"
        s += decodeDescriptor(b)
    }
    log(s)
    if let cmd = sendBytes, !cmd.isEmpty {
        let maxOut = (prop(dev, kIOHIDMaxOutputReportSizeKey) as? Int) ?? cmd.count
        for attempt in [cmd + [UInt8](repeating: 0, count: max(0, maxOut - cmd.count)), cmd] {
            let rr = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(attempt[0]), attempt, attempt.count)
            log(
                "SEND output report \(attempt.map { String(format: "%02x", $0) }.joined(separator: " ")) -> \(rr == kIOReturnSuccess ? "ok" : String(format: "0x%08x", rr))"
            )
            if rr == kIOReturnSuccess { break }
        }
    }
    if showRaw {
        let size = max((prop(dev, kIOHIDMaxInputReportSizeKey) as? Int) ?? 64, 64)
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        let ctx = Unmanaged.passRetained(dev).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            dev, buf, size,
            { ctx, _, _, _, rid, rep, len in
                let d = Unmanaged<IOHIDDevice>.fromOpaque(ctx!).takeUnretainedValue()
                log("RAW \(devTag(d)) id=0x\(String(format: "%02x", rid)) len=\(len): \(hex(rep, len))")
            }, ctx)
    }
}
IOHIDManagerRegisterDeviceMatchingCallback(mgr, matchCB, nil)
IOHIDManagerRegisterDeviceRemovalCallback(mgr, { _, _, _, dev in log("DEVICE REMOVED \(devTag(dev))") }, nil)
IOHIDManagerRegisterInputValueCallback(
    mgr,
    { _, _, _, value in
        let el = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(el), usage = IOHIDElementGetUsage(el)
        if !showXY && page == 0x01 && (usage == 0x30 || usage == 0x31) { return }
        if page == 0x07 && (usage == 0xFFFFFFFF || usage <= 3) { return }  // keyboard array noise
        let v = IOHIDValueGetIntegerValue(value)
        let dev = IOHIDElementGetDevice(el)
        log(
            "HID \(devTag(dev)) rid=0x\(String(format: "%02x", IOHIDElementGetReportID(el))) \(usageName(page, usage)) = \(v)"
        )
    }, nil)
IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
let r = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
log(
    "IOHIDManagerOpen: \(r == kIOReturnSuccess ? "ok" : String(format: "0x%08x", r))\(allVendors ? "" : " (matching VID 0x17EF; waiting for device…)")"
)

// ---------- listen-only CGEventTap ----------
if !noTap {
    let types: [CGEventType] = [.scrollWheel, .otherMouseDown, .otherMouseUp, .otherMouseDragged]
    let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    let tap = CGEvent.tapCreate(
        tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
        eventsOfInterest: mask,
        callback: { _, type, ev, _ in
            switch type {
            case .scrollWheel where dumpFields:
                var parts: [String] = []
                for i in 0..<256 {
                    let f = unsafeBitCast(UInt32(i), to: CGEventField.self)
                    let v = ev.getIntegerValueField(f)
                    if v != 0 { parts.append("\(i)=\(v)") }
                }
                log("CG scrollfields " + parts.joined(separator: " "))
            case .scrollWheel:
                log(
                    String(
                        format: "CG scroll  v=%lld h=%lld  pt v=%lld h=%lld  cont=%lld phase=%lld mom=%lld",
                        ev.getIntegerValueField(.scrollWheelEventDeltaAxis1),
                        ev.getIntegerValueField(.scrollWheelEventDeltaAxis2),
                        ev.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
                        ev.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),
                        ev.getIntegerValueField(.scrollWheelEventIsContinuous),
                        ev.getIntegerValueField(.scrollWheelEventScrollPhase),
                        ev.getIntegerValueField(.scrollWheelEventMomentumPhase)))
            case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
                let n = type == .otherMouseDown ? "down" : type == .otherMouseUp ? "UP  " : "drag"
                if type == .otherMouseDragged && !showXY { return Unmanaged.passUnretained(ev) }
                log(
                    "CG other\(n) button=\(ev.getIntegerValueField(.mouseEventButtonNumber)) clicks=\(ev.getIntegerValueField(.mouseEventClickState))"
                )
            case .tapDisabledByTimeout, .tapDisabledByUserInput: log("CG tap disabled (\(type.rawValue))")
            default: break
            }
            return Unmanaged.passUnretained(ev)
        }, userInfo: nil)
    if let tap = tap {
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("CGEventTap: ok (listen-only)")
    } else {
        log("CGEventTap: FAILED (Input Monitoring not granted?)")
    }
}

if probeUSB { startProbe() }
log("Recording for \(Int(seconds)) s. Ctrl-C (or pkill tprec) to stop.")
signal(SIGINT) { _ in exit(0) }; signal(SIGTERM) { _ in exit(0) }
CFRunLoopRunInMode(.defaultMode, seconds, false)
log("done")
