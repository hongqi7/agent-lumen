// Agent Lumen (灵光): a menu bar light, a screen-edge glow and (optionally) NuPhy keyboard side lights
// that show what your AI coding agents are doing — Claude Code, WorkBuddy and Devin.
// Blue: waiting for your approval. Orange: working. Green: done.
// Each agent session reports its state through hooks (Resources/lumen-hook); this app is the only reader.
import AppKit
import IOKit.hid
import QuartzCore
import SwiftUI

let home = ProcessInfo.processInfo.environment["AGENT_LUMEN_HOME"] ?? NSHomeDirectory()   // override for tests
let lumenDir = home + "/.agent-lumen"
let lumenSessions = lumenDir + "/sessions"
// written by the older standalone keyboard-light hooks (claude-light); read only while an agent still uses them
let legacySessions = home + "/.claude/claude-light/sessions"
let hookPath = lumenDir + "/lumen-hook"
let staleSeconds: TimeInterval = 120 * 60   // a busy session silent for 2 hours was interrupted: count it as done
let loginLabel = "io.github.hongqi7.agent-lumen"
let loginAgentPath = home + "/Library/LaunchAgents/\(loginLabel).plist"

let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
func L(_ zh: String, _ en: String) -> String { chinese ? zh : en }

enum Light: Int, Comparable {
    case idle, done, working, attention     // ordered by urgency

    static func < (a: Light, b: Light) -> Bool { a.rawValue < b.rawValue }

    init(word: String) {
        switch word {
        case "attention": self = .attention
        case "working":   self = .working
        case "done":      self = .done
        default:          self = .idle
        }
    }

    var color: NSColor {
        switch self {
        case .working:   return NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        case .attention: return NSColor(srgbRed: 0.24, green: 0.52, blue: 1.00, alpha: 1)
        case .done:      return NSColor(srgbRed: 0.20, green: 0.80, blue: 0.36, alpha: 1)
        case .idle:      return .secondaryLabelColor
        }
    }

    var label: String {
        switch self {
        case .working:   return L("执行中", "Working")
        case .attention: return L("待确认", "Needs you")
        case .done:      return L("已完成", "Done")
        case .idle:      return L("空闲", "Idle")
        }
    }
}

struct Session {
    let agent: String
    let light: Light
    let changed: Date      // when the hook last wrote this state
}

func readSessions(includeLegacy: Bool) -> [Session] {
    let fm = FileManager.default
    let now = Date()
    var seen = Set<String>()
    var out: [Session] = []
    for dir in includeLegacy ? [lumenSessions, legacySessions] : [lumenSessions] {
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
        for name in names where !name.hasPrefix(".") && seen.insert(name).inserted {
            let path = dir + "/" + name
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            else { continue }
            var light = Light(word: text.trimmingCharacters(in: .whitespacesAndNewlines))
            if light == .idle { continue }
            if light > .done && now.timeIntervalSince(mtime) > staleSeconds { light = .done }
            let agent = name.hasPrefix("workbuddy-") ? "WorkBuddy"
                      : name.hasPrefix("devin-") ? "Devin" : "Claude Code"
            out.append(Session(agent: agent, light: light, changed: mtime))
        }
    }
    return out
}

// One breath, 0 → 255 → 0: the table the NuPhy firmware uses, so screen and keyboard breathe alike
let breatheTable: [UInt8] = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 16, 18, 20, 22, 24, 27, 30, 33, 36, 39, 42,
    45, 49, 53, 57, 61, 65, 69, 73, 77, 81, 85, 89, 94, 99, 104, 109, 114, 119, 124, 129, 134, 140, 146, 152,
    158, 164, 170, 176, 182, 188, 194, 200, 206, 213, 220, 227, 234, 241, 248, 255, 255, 248, 241, 234, 227, 220, 213, 206,
    200, 194, 188, 182, 176, 170, 164, 158, 152, 146, 140, 134, 129, 124, 119, 114, 109, 104, 99, 94, 89, 85, 81, 77,
    73, 69, 65, 61, 57, 53, 49, 45, 42, 39, 36, 33, 30, 27, 24, 22, 20, 18, 16, 14, 12, 10, 9, 8,
    7, 6, 5, 4, 3, 2, 1, 0,
]

// a small diagnostics log, ~/.agent-lumen/lumen.log, trimmed to its last 200 lines
func lumenLog(_ text: String) {
    let path = lumenDir + "/lumen.log"
    let stamp = ISO8601DateFormatter().string(from: Date())
    var lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    lines.append("\(stamp) \(text)")
    try? FileManager.default.createDirectory(atPath: lumenDir, withIntermediateDirectories: true)
    try? (lines.suffix(200).joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
}

// 0...1...0 once per period, following breatheTable
func wave(_ t: CFTimeInterval, _ period: Double) -> CGFloat {
    let phase = t.truncatingRemainder(dividingBy: period) / period * Double(breatheTable.count)
    let i = Int(phase) % breatheTable.count
    let f = phase - phase.rounded(.down)
    let v = Double(breatheTable[i]) * (1 - f) + Double(breatheTable[(i + 1) % breatheTable.count]) * f
    return CGFloat(v / 255)
}

// MARK: - hooks

// One agent we can wire up: where its settings live and which hook events map to which state.
// Event names differ: Devin drops its whole hooks object if it sees one it doesn't know.
struct AgentTarget {
    let name: String
    let configDir: String
    let settings: String
    let arg: String                          // session file prefix
    let events: [(event: String, state: String, matcher: String?)]

    enum Status { case absent, off, lumen, legacy }

    var status: Status {
        guard FileManager.default.fileExists(atPath: configDir) else { return .absent }
        let text = (try? String(contentsOfFile: settings, encoding: .utf8)) ?? ""
        if text.contains("lumen-hook") { return .lumen }
        if text.contains("claude-light") { return .legacy }   // the older standalone keyboard-light hooks
        return .off
    }
}

let targets = [
    AgentTarget(name: "Claude Code", configDir: home + "/.claude", settings: home + "/.claude/settings.json", arg: "",
                events: [("UserPromptSubmit", "working", nil), ("PostToolUse", "working", "*"),
                         ("PreToolUse", "attention", "AskUserQuestion"), ("Notification", "attention", "permission_prompt"),
                         ("Stop", "done", nil), ("SessionEnd", "end", nil)]),
    AgentTarget(name: "WorkBuddy", configDir: home + "/.workbuddy", settings: home + "/.workbuddy/settings.json", arg: "workbuddy",
                events: [("UserPromptSubmit", "working", nil), ("PostToolUse", "working", nil),
                         ("PermissionRequest", "attention", nil), ("Notification", "attention", "permission_prompt"),
                         ("Stop", "done", nil), ("StopFailure", "done", nil), ("SessionEnd", "end", nil)]),
    AgentTarget(name: "Devin", configDir: home + "/.config/devin", settings: home + "/.config/devin/config.json", arg: "devin",
                events: [("UserPromptSubmit", "working", nil), ("PostToolUse", "working", nil),
                         ("PermissionRequest", "attention", nil), ("Stop", "done", nil), ("SessionEnd", "end", nil)]),
]

enum HookError: Error { case unreadable(String) }

// Rewrites one settings file: drops earlier Lumen entries and the older keyboard-light ones (this app drives
// the keyboard now, so one set of hooks serves both), then (when installing) puts ours first in
// each event so they never wait behind a slow hook. Backs the file up and keeps its permissions.
func setHooks(_ t: AgentTarget, install: Bool) throws {
    let fm = FileManager.default
    var root: [String: Any] = [:]
    var perms: Any?
    if let data = fm.contents(atPath: t.settings), !data.isEmpty {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookError.unreadable(t.settings)
        }
        root = obj
        perms = try? fm.attributesOfItem(atPath: t.settings)[.posixPermissions]
        let stamp = Int(Date().timeIntervalSince1970)
        try? fm.copyItem(atPath: t.settings, toPath: t.settings + ".bak-agent-lumen-\(stamp)")
    }
    var hooks = root["hooks"] as? [String: Any] ?? [:]
    func isLumen(_ entry: Any) -> Bool {
        ((entry as? [String: Any])?["hooks"] as? [[String: Any]] ?? [])
            .contains { c in ["lumen-hook", "claude-light"].contains { (c["command"] as? String ?? "").contains($0) } }
    }
    for event in Array(hooks.keys) {
        let kept = (hooks[event] as? [Any] ?? []).filter { !isLumen($0) }
        hooks[event] = kept.isEmpty ? nil : kept
    }
    if install {
        for e in t.events {
            var entry: [String: Any] = ["hooks": [["type": "command",
                                                   "command": "\"\(hookPath)\" \(e.state) \(t.arg)".trimmingCharacters(in: .whitespaces),
                                                   "timeout": 5]]]
            if let m = e.matcher { entry["matcher"] = m }
            hooks[e.event] = [entry] + (hooks[e.event] as? [Any] ?? [])
        }
    }
    root["hooks"] = hooks
    let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
    try fm.createDirectory(atPath: t.configDir, withIntermediateDirectories: true)
    try data.write(to: URL(fileURLWithPath: t.settings), options: .atomic)
    if let perms { try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: t.settings) }
}

// The hook lives at a fixed path outside the app, so moving the app never breaks the agents' settings.
func installHookScript() throws {
    guard let src = Bundle.main.path(forResource: "lumen-hook", ofType: nil) else { return }
    let fm = FileManager.default
    try fm.createDirectory(atPath: lumenDir + "/sessions", withIntermediateDirectories: true)
    try? fm.removeItem(atPath: hookPath)
    try fm.copyItem(atPath: src, toPath: hookPath)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookPath)
}

// MARK: - glow window

// Four gradients, strongest at the screen edge and fading inward.
final class GlowView: NSView {
    private let container = CALayer()
    private let edges = (0..<4).map { _ in CAGradientLayer() }
    private let thickness: CGFloat = 80

    override init(frame: NSRect) {
        super.init(frame: frame)
        // layer before wantsLayer = a layer-hosting view: AppKit leaves our layer tree alone
        layer = CALayer()
        wantsLayer = true
        container.opacity = 0
        layer!.addSublayer(container)
        edges.forEach { container.addSublayer($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        let b = bounds, t = thickness
        // bottom, top, left, right
        let frames = [CGRect(x: 0, y: 0, width: b.width, height: t),
                      CGRect(x: 0, y: b.height - t, width: b.width, height: t),
                      CGRect(x: 0, y: 0, width: t, height: b.height),
                      CGRect(x: b.width - t, y: 0, width: t, height: b.height)]
        let from = [CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1), CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5)]
        let to   = [CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5)]
        for i in 0..<4 {
            edges[i].frame = frames[i]
            edges[i].startPoint = from[i]
            edges[i].endPoint = to[i]
        }
        CATransaction.commit()
    }

    func setColor(_ color: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let c = color.cgColor
        let colors = [c.copy(alpha: 0.95)!, c.copy(alpha: 0.4)!, c.copy(alpha: 0)!]
        for e in edges {
            e.colors = colors
            e.locations = [0, 0.3, 1]
        }
        CATransaction.commit()
    }

    // Core Animation's own animations never draw in this background window, so the app drives the level
    func setLevel(_ level: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.opacity = Float(max(0, min(1, level)))
        CATransaction.commit()
    }
}

// A click-through, see-through window covering one screen, above everything including full-screen apps.
// A display as the user knows it. The id is macOS's UUID for the panel, so a setting survives unplugging,
// rearranging and restarts; screens with the same name get their position added.
struct Display {
    let id: String
    let name: String
    let builtIn: Bool
    let screen: NSScreen

    static var all: [Display] {
        let raw = NSScreen.screens.compactMap { screen -> (String, String, Bool, NSScreen)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
            let builtIn = CGDisplayIsBuiltin(number.uint32Value) != 0
            let name = builtIn ? L("内建显示器", "Built-in display") : screen.localizedName
            return (CFUUIDCreateString(nil, uuid) as String, name, builtIn, screen)
        }.sorted { $0.3.frame.minX < $1.3.frame.minX }
        return raw.map { id, name, builtIn, screen in
            let twins = raw.filter { $0.1 == name }
            var shown = name
            if twins.count == 2 {
                shown += twins[0].0 == id ? L("（左）", " (left)") : L("（右）", " (right)")
            } else if twins.count > 2, let i = twins.firstIndex(where: { $0.0 == id }) {
                shown += " \(i + 1)"
            }
            return Display(id: id, name: shown, builtIn: builtIn, screen: screen)
        }
    }
}

// displays the user switched the glow off on; anything not listed (including a newly connected display) glows
var glowOffDisplays: Set<String> {
    get { Set(UserDefaults.standard.stringArray(forKey: "glowOffDisplays") ?? []) }
    set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "glowOffDisplays") }
}

final class GlowWindow: NSWindow {
    let glow: GlowView

    init(screen: NSScreen) {
        glow = GlowView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView = glow
    }
}

// MARK: - keyboard

// NuPhy keyboards running the claude-light firmware (github.com/hongqi7/nuphy-air60-v2-claude-light) read the
// state from two indicator bits macOS never uses: Num Lock = working, Scroll Lock = done, both = needs you.
// The bits travel over USB, Bluetooth and 2.4G alike. A reconnecting keyboard starts with them cleared,
// so they are sent again when it shows up.
final class KeyboardLight {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var opened = false
    private var bits: (num: Bool, scroll: Bool) = (false, false)
    var nameMatch: String { UserDefaults.standard.string(forKey: "keyboardName") ?? "NuPhy" }

    init() {
        let match = [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard] as CFDictionary
        IOHIDManagerSetDeviceMatching(manager, match)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            let light = Unmanaged<KeyboardLight>.fromOpaque(ctx!).takeUnretainedValue()
            guard light.matches(device) else { return }
            // give the link a moment to settle before writing
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { light.apply() }
        }, me)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    // reading device names needs no permission; writing the LEDs needs Input Monitoring
    var access: IOHIDAccessType { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) }

    func requestAccess() { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }

    private func openIfAllowed() -> Bool {
        if !opened && access == kIOHIDAccessTypeGranted {
            let r = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            opened = r == kIOReturnSuccess
            lumenLog("keyboard: open manager -> 0x\(String(r, radix: 16))")
        }
        return opened
    }

    // what went wrong last time, so the log shows a change instead of a line every 20 s
    private var lastProblem = ""

    private func name(_ d: IOHIDDevice) -> String {
        IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? ""
    }

    func matches(_ d: IOHIDDevice) -> Bool { name(d).localizedCaseInsensitiveContains(nameMatch) }

    private var devices: [IOHIDDevice] {
        guard let set = IOHIDManagerCopyDevices(manager) else { return [] }
        var refs = [UnsafeRawPointer?](repeating: nil, count: CFSetGetCount(set))
        CFSetGetValues(set, &refs)
        return refs.compactMap { $0 }.map { Unmanaged<IOHIDDevice>.fromOpaque($0).takeUnretainedValue() }.filter(matches)
    }

    var names: [String] { Array(Set(devices.map(name))).sorted() }

    func show(_ light: Light) {
        let next = (num: light == .working || light == .attention, scroll: light == .done || light == .attention)
        guard next != bits else { return }
        bits = next
        apply()
    }

    func apply() {
        guard openIfAllowed() else {
            let problem = "keyboard: no Input Monitoring (access \(access.rawValue)), lights not sent"
            if problem != lastProblem { lumenLog(problem) }
            lastProblem = problem
            return
        }
        var results: [String] = []
        for d in devices {
            guard let els = IOHIDDeviceCopyMatchingElements(d, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else { continue }
            for e in els where IOHIDElementGetUsagePage(e) == UInt32(kHIDPage_LEDs) {
                let on: Bool
                switch Int(IOHIDElementGetUsage(e)) {
                case kHIDUsage_LED_NumLock:    on = bits.num
                case kHIDUsage_LED_ScrollLock: on = bits.scroll
                default:                       continue
                }
                let r = IOHIDDeviceSetValue(d, e, IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, e, 0, on ? 1 : 0))
                if r != kIOReturnSuccess { results.append("\(name(d)) led \(IOHIDElementGetUsage(e)) -> 0x\(String(r, radix: 16))") }
            }
        }
        let problem = devices.isEmpty ? "keyboard: none connected" : results.joined(separator: "; ")
        if problem != lastProblem {
            lumenLog(problem.isEmpty ? "keyboard: lights sent to \(names.joined(separator: ", ")) num=\(bits.num) scroll=\(bits.scroll)" : problem)
        }
        lastProblem = problem
    }
}

// Brightness per state and the "whole keyboard breathes" switch go to the keyboard over its USB raw HID
// (VIA) interface — the wireless module forwards only the lock bits, so this works while the cable is in.
// The keyboard stores them, so they keep applying over Bluetooth and 2.4G.
//   'L' 'M' 0x01 <working> <done> <needs you> <flags>  →  echoed back with the stored values, byte 7 = version
final class KeyboardSettings {
    enum Sync { case noCable, synced, oldFirmware, pending }

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var opened = false
    private var buffers: [UnsafeMutablePointer<UInt8>] = []
    private var pending: [UInt8]?
    private var lastSent = Date.distantPast
    private(set) var status = Sync.noCable
    var currentPayload: (() -> [UInt8])?     // levels and flags, read fresh each time
    var nameMatch = "NuPhy"

    init() {
        let match = [kIOHIDDeviceUsagePageKey: 0xFF60, kIOHIDDeviceUsageKey: 0x61] as CFDictionary
        IOHIDManagerSetDeviceMatching(manager, match)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            let s = Unmanaged<KeyboardSettings>.fromOpaque(ctx!).takeUnretainedValue()
            guard s.matches(device) else { return }
            s.listen(device)
            // a keyboard just plugged in: give it what was set while it was wireless
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { s.send(force: true) }
        }, me)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, _ in
            let s = Unmanaged<KeyboardSettings>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { if s.devices.isEmpty { s.status = .noCable } }
        }, me)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    func start() {
        guard !opened else { return }
        opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
    }

    private func matches(_ d: IOHIDDevice) -> Bool {
        (IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? "").localizedCaseInsensitiveContains(nameMatch)
    }

    private var devices: [IOHIDDevice] {
        guard let set = IOHIDManagerCopyDevices(manager) else { return [] }
        var refs = [UnsafeRawPointer?](repeating: nil, count: CFSetGetCount(set))
        CFSetGetValues(set, &refs)
        return refs.compactMap { $0 }.map { Unmanaged<IOHIDDevice>.fromOpaque($0).takeUnretainedValue() }.filter(matches)
    }

    // replies tell us whether the firmware understood: ours echoes 'L' 'M', older firmware answers as VIA would
    private func listen(_ device: IOHIDDevice) {
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        buffers.append(buf)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buf, 64, { ctx, _, _, _, _, report, length in
            let s = Unmanaged<KeyboardSettings>.fromOpaque(ctx!).takeUnretainedValue()
            let ok = length >= 8 && report[0] == 0x4C && report[1] == 0x4D && report[7] >= 1
            DispatchQueue.main.async { s.status = ok ? .synced : .oldFirmware }
        }, me)
    }

    // called for every slider move: at most 20 writes a second, and the last value is never dropped
    func send(force: Bool = false) {
        guard let payload = currentPayload?() else { return }
        pending = payload
        let wait = 0.05 - Date().timeIntervalSince(lastSent)
        if wait > 0 && !force {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.flush() }
            return
        }
        flush()
    }

    private func flush() {
        guard let payload = pending else { return }
        start()
        let targets = devices
        guard !targets.isEmpty else {
            status = .noCable
            return
        }
        pending = nil
        lastSent = Date()
        var report = [UInt8](repeating: 0, count: 32)
        report[0] = 0x4C   // 'L'
        report[1] = 0x4D   // 'M'
        report[2] = 0x01
        for (i, b) in payload.prefix(4).enumerated() { report[3 + i] = b }
        if status != .synced { status = .pending }
        for d in targets {
            _ = IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 0, report, report.count)
        }
    }
}

// MARK: - panel

struct DisplayRow: Identifiable {
    let id: String
    let name: String
    let builtIn: Bool
    let on: Bool
}

struct AgentRow: Identifiable {
    let id: Int
    let name: String
    let status: AgentTarget.Status
}

enum PanelAction { case dismissDone, toggleAgent(Int), toggleDisplay(String), askKeyboardAccess, toggleLogin, quit }

// what the panel shows; the app delegate fills it in and carries out the actions
final class PanelModel: ObservableObject {
    @Published var state = Light.idle
    @Published var summary: [String] = []
    @Published var doneOnScreen = false
    @Published var keyboardName: String?
    @Published var keyboardSync = KeyboardSettings.Sync.noCable
    @Published var keyboardNeedsAccess = false
    @Published var agents: [AgentRow] = []
    @Published var openAtLogin = false
    @Published var displays: [DisplayRow] = []
    @Published var selected = Light.working   // the state whose settings the panel shows
    @Published var height: CGFloat = 600   // fits the screen; the panel scrolls when its content is taller
    var changed: (String) -> Void = { _ in }
    var perform: (PanelAction) -> Void = { _ in }

    func bool(_ key: String) -> Binding<Bool> {
        Binding(get: { UserDefaults.standard.bool(forKey: key) },
                set: { self.objectWillChange.send(); UserDefaults.standard.set($0, forKey: key); self.changed(key) })
    }

    func double(_ key: String) -> Binding<Double> {
        Binding(get: { UserDefaults.standard.double(forKey: key) },
                set: { self.objectWillChange.send(); UserDefaults.standard.set($0, forKey: key); self.changed(key) })
    }
}

let panelWidth: CGFloat = 340

// the panel's own dark look, so the lights in the preview stand out
enum Ink {
    static let text = Color(red: 0.95, green: 0.93, blue: 0.91)
    static let muted = text.opacity(0.55)
    static let faint = text.opacity(0.35)
    static let card = Color.white.opacity(0.05)
    static let cardOn = Color.white.opacity(0.12)
    static let line = Color.white.opacity(0.08)
    static let back = Color(red: 0.114, green: 0.110, blue: 0.122)
    static let rim = Color(red: 0.227, green: 0.220, blue: 0.239)
}

struct PanelView: View {
    @ObservedObject var model: PanelModel
    let styles: [GlowStyle]
    let delays: [(seconds: Double, title: String)]

    var body: some View {
        ScrollView(.vertical) { PanelContent(model: model, styles: styles, delays: delays) }
            .frame(width: panelWidth, height: model.height)
            .background(Ink.back)
            .preferredColorScheme(.dark)
    }
}

// ⓘ: hovering shows the explanation, a click keeps it open until clicked again or dismissed
struct InfoButton: View {
    let text: String
    @State private var hovering = false
    @State private var pinned = ProcessInfo.processInfo.environment["AGENT_LUMEN_SHOW_INFO"] != nil

    var body: some View {
        Button { pinned.toggle() } label: {
            Image(systemName: hovering || pinned ? "info.circle.fill" : "info.circle")
                .font(.system(size: 12))
                .foregroundColor(hovering || pinned ? .accentColor : Ink.faint)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .popover(isPresented: Binding(get: { hovering || pinned }, set: { if !$0 { hovering = false; pinned = false } }),
                 arrowEdge: .bottom) {
            Text(text)
                .font(.system(size: 12))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 240, alignment: .leading)
                .padding(12)
        }
    }
}

// A small screen and keyboard lit the way the selected state will look, breathing at its real pace
struct LightPreview: View {
    let style: GlowStyle
    let level: Double
    let onScreen: Bool
    let onKeyboard: Bool
    let wholeKeyboard: Bool

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let a = level * (0.35 + 0.65 * Double(wave(t, style.period)))
            let color = Color(nsColor: style.light.color)
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(RadialGradient(colors: [Color(red: 0.165, green: 0.157, blue: 0.173), Color(red: 0.086, green: 0.082, blue: 0.094)],
                                         center: .init(x: 0.5, y: 0.3), startRadius: 0, endRadius: 200))
                VStack(spacing: 0) {
                    // screen
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.055, green: 0.055, blue: 0.063))
                        RoundedRectangle(cornerRadius: 4).fill(Color(red: 0.122, green: 0.118, blue: 0.133))
                            .padding(.horizontal, 16).padding(.vertical, 14)
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(0..<3) { i in
                                Capsule().fill(Color.white.opacity(0.08)).frame(width: i == 2 ? 60 : 90, height: 5)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.leading, 26).padding(.top, 24)
                        if onScreen {
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(color, lineWidth: 5)
                                .blur(radius: 5)
                                .opacity(a)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                        RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.rim, lineWidth: 2)
                    }
                    .frame(width: 180, height: 104)
                    RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.173, green: 0.165, blue: 0.184)).frame(width: 40, height: 10)
                    // keyboard
                    ZStack {
                        RoundedRectangle(cornerRadius: 5).fill(Color(red: 0.165, green: 0.157, blue: 0.176))
                        VStack(spacing: 2) {
                            ForEach(0..<3) { _ in
                                HStack(spacing: 3) {
                                    ForEach(0..<11) { _ in
                                        RoundedRectangle(cornerRadius: 1)
                                            .fill(onKeyboard && wholeKeyboard ? color.opacity(0.25 + 0.75 * a) : Color(red: 0.27, green: 0.26, blue: 0.29))
                                            .frame(width: 9, height: 3)
                                    }
                                }
                            }
                        }
                        HStack {
                            Capsule().fill(onKeyboard ? color.opacity(0.3 + 0.7 * a) : Ink.rim).frame(width: 3)
                            Spacer()
                            Capsule().fill(onKeyboard ? color.opacity(0.3 + 0.7 * a) : Ink.rim).frame(width: 3)
                        }
                        .padding(.vertical, 3).padding(.horizontal, 2)
                        .shadow(color: onKeyboard ? color.opacity(a) : .clear, radius: 5)
                        RoundedRectangle(cornerRadius: 5).strokeBorder(Ink.rim, lineWidth: 1)
                    }
                    .frame(width: 150, height: 22)
                    .padding(.top, 10)
                }
            }
        }
        .frame(height: 178)
    }
}

struct PanelContent: View {
    @ObservedObject var model: PanelModel
    let styles: [GlowStyle]
    let delays: [(seconds: Double, title: String)]

    private var st: GlowStyle { styles.first { $0.light == model.selected } ?? styles[0] }
    private func isOn(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            LightPreview(style: st, level: UserDefaults.standard.double(forKey: st.levelKey),
                         onScreen: isOn(st.onKey), onKeyboard: isOn(st.keyboardKey), wholeKeyboard: isOn("keyboardKeysBreathe"))
                .padding(.top, 12)
            tabs.padding(.top, 12)
            Text(st.help.replacingOccurrences(of: "\n", with: chinese ? "" : " "))
                .font(.system(size: 12)).foregroundColor(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10).padding(.horizontal, 2)
            HStack(spacing: 8) {
                tile(L("屏幕边缘", "Screen edges"), "display", st.onKey)
                tile(L("键盘侧灯", "Keyboard"), "keyboard", st.keyboardKey)
            }
            .padding(.top, 10)
            brightness.padding(.top, 12)
            if st.light == .done { doneDelay.padding(.top, 10) }
            list.padding(.top, 14)
        }
        .padding(16)
        .foregroundColor(Ink.text)
        .font(.system(size: 13))
        .frame(width: panelWidth)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if model.state == .idle {
                Circle().stroke(Ink.muted, lineWidth: 1.5).frame(width: 10, height: 10)
            } else {
                Circle().fill(Color(nsColor: model.state.color)).frame(width: 10, height: 10)
            }
            Text(model.state.label).font(.system(size: 16, weight: .semibold))
            Spacer(minLength: 8)
            if model.doneOnScreen {
                Button(L("关闭屏幕绿光", "Turn off glow")) { model.perform(.dismissDone) }
                    .buttonStyle(.plain).font(.system(size: 11))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Ink.cardOn))
            } else {
                Text(model.summary.joined(separator: L("；", "; ")))
                    .font(.system(size: 12)).foregroundColor(Ink.muted).lineLimit(1).truncationMode(.tail)
            }
        }
    }

    private var tabs: some View {
        HStack(spacing: 6) {
            ForEach(styles, id: \.onKey) { s in
                let sel = s.light == model.selected
                Button { model.selected = s.light } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Color(nsColor: s.light.color)).frame(width: 8, height: 8)
                        Text(s.light.label).font(.system(size: 12))
                    }
                    .foregroundColor(sel ? Ink.text : Ink.muted)
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9).fill(sel ? Ink.cardOn : Ink.card))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(sel ? Color.white.opacity(0.14) : .clear, lineWidth: 0.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func tile(_ title: String, _ symbol: String, _ key: String) -> some View {
        let on = isOn(key)
        return Button { model.bool(key).wrappedValue.toggle() } label: {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: symbol).font(.system(size: 16))
                Text(title).font(.system(size: 13, weight: .medium)).padding(.top, 2)
                Text(on ? L("发光", "On") : L("不发光", "Off")).font(.system(size: 11))
                    .foregroundColor(on ? Ink.text.opacity(0.75) : Ink.faint)
            }
            .foregroundColor(on ? Ink.text : Ink.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(on ? Ink.cardOn : Ink.card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var brightness: some View {
        VStack(spacing: 2) {
            HStack {
                Text(L("亮度", "Brightness")).font(.system(size: 12)).foregroundColor(Ink.muted)
                Spacer()
                Text("\(Int((UserDefaults.standard.double(forKey: st.levelKey) * 100).rounded()))%")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
            Slider(value: model.double(st.levelKey), in: 0.22...1.0)
                .tint(Color(nsColor: st.light.color))
                .controlSize(.small)
        }
    }

    private var doneDelay: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(L("屏幕绿光自动关闭", "Turn off screen glow")).font(.system(size: 12)).foregroundColor(Ink.muted)
                InfoButton(text: L("你离开电脑期间，绿光保持显示。你回到电脑前、操作鼠标或键盘后，按所选时间关闭。\n仅作用于屏幕；键盘和菜单栏图标保持绿色，直到下一项任务开始。",
                                   "While you are away the glow stays on. Once you use the mouse or keyboard again, it turns off after the chosen time.\nScreen only: the keyboard and the menu bar icon stay green until the next task starts."))
            }
            HStack(spacing: 6) {
                ForEach(delays, id: \.seconds) { d in
                    let sel = model.double("doneScreenDelay").wrappedValue == d.seconds
                    Button { model.double("doneScreenDelay").wrappedValue = d.seconds } label: {
                        Text(d.title).font(.system(size: 11))
                            .foregroundColor(sel ? Ink.text : Ink.muted)
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 8).fill(sel ? Color.white.opacity(0.16) : Ink.card))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // one settings row: icon, title (and an optional second line), then whatever goes on the right
    private func row<Trailing: View>(_ symbol: String, _ title: String, _ detail: String? = nil, info: String? = nil,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundColor(Ink.muted).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(title)
                    if let info { InfoButton(text: info) }
                }
                if let detail { Text(detail).font(.system(size: 11)).foregroundColor(Ink.faint) }
            }
            Spacer(minLength: 6)
            trailing()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private var keyboardStatus: String {
        switch model.keyboardSync {
        case .synced:      return L("USB 连接 · 设置已写入", "USB · settings saved")
        case .pending:     return L("USB 连接 · 正在写入", "USB · saving")
        case .oldFirmware: return L("固件需更新", "firmware update needed")
        case .noCable:     return L("无线连接", "wireless")
        }
    }

    private func menuText(_ a: AgentRow) -> String {
        switch a.status {
        case .lumen:  return L("断开 ", "Disconnect ") + a.name
        case .legacy: return L("更新 ", "Update ") + a.name + L(" 的钩子", " hooks")
        default:      return L("接入 ", "Connect ") + a.name
        }
    }

    private var agentsValue: String {
        let ok = model.agents.filter { $0.status == .lumen }.count
        if model.agents.isEmpty { return L("未检测到", "none found") }
        return ok == model.agents.count ? L("\(ok) 个", "\(ok)") : L("\(ok) / \(model.agents.count) 个", "\(ok) of \(model.agents.count)")
    }

    private func valueMenu<Content: View>(_ value: String, @ViewBuilder _ items: () -> Content) -> some View {
        Menu {
            items()
        } label: {
            Text(value).font(.system(size: 12)).foregroundColor(Ink.muted)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var list: some View {
        VStack(spacing: 0) {
            if model.displays.count > 1 {
                row("display", L("发光的显示器", "Displays that glow"),
                    info: L("选择在哪些显示器上显示屏幕边缘发光，对三种状态统一生效。\n未选的显示器不发光。拔掉再接上、重启电脑后，设置保持不变。",
                            "Choose which displays show the edge glow, for all three states.\nThe choice survives unplugging and restarts.")) {
                    let on = model.displays.filter(\.on)
                    valueMenu(on.isEmpty ? L("无", "none") : on.count == model.displays.count ? L("全部", "all") : on.map(\.name).joined(separator: L("、", ", "))) {
                        ForEach(model.displays) { d in
                            Toggle(d.name, isOn: Binding(get: { d.on }, set: { _ in model.perform(.toggleDisplay(d.id)) }))
                        }
                    }
                }
                Divider().overlay(Ink.line)
            }
            if let name = model.keyboardName {
                row("keyboard", L("按键背光同步", "Key backlights"), "\(name) · \(keyboardStatus)",
                    info: L("开启：按键背光与侧边灯条一同显示状态颜色。\n关闭：仅侧边灯条显示。\n亮度与本项需在 USB 有线连接时写入键盘，写入后改用蓝牙或 2.4G 连接仍然有效。",
                            "On: key backlights show the state colour with the side light bar.\nOff: only the side light bar.\nSaved to the keyboard over USB; stays in effect over Bluetooth or 2.4G.")) {
                    Toggle("", isOn: model.bool("keyboardKeysBreathe")).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
                if model.keyboardNeedsAccess {
                    row("exclamationmark.triangle.fill", L("需要「输入监控」权限", "Needs Input Monitoring"),
                        info: L("macOS 要求此权限才能设置键盘指示灯。Agent Lumen 仅设置指示灯，不读取按键内容。",
                                "macOS requires it to set keyboard LEDs. Agent Lumen only sets the LEDs and never reads keys.")) {
                        Button(L("去开启", "Allow")) { model.perform(.askKeyboardAccess) }.controlSize(.small)
                    }
                }
            } else {
                row("keyboard", L("未连接 NuPhy 键盘", "No NuPhy keyboard"),
                    info: L("支持刷入本项目固件的 NuPhy Air60 V2、Halo65 V2。连接到这台 Mac 后在此显示。",
                            "NuPhy Air60 V2 and Halo65 V2 with this project's firmware show up here once connected.")) { EmptyView() }
            }
            Divider().overlay(Ink.line)
            row("link", L("已接入的 AI 助手", "AI agents"),
                model.agents.isEmpty ? nil : model.agents.map { a in
                    a.name + (a.status == .lumen ? "" : a.status == .legacy ? L("（需更新）", " (update)") : L("（未接入）", " (off)"))
                }.joined(separator: L("、", ", "))) {
                if model.agents.isEmpty {
                    Text(agentsValue).font(.system(size: 12)).foregroundColor(Ink.muted)
                } else {
                    valueMenu(agentsValue) {
                        ForEach(model.agents) { a in Button(menuText(a)) { model.perform(.toggleAgent(a.id)) } }
                    }
                }
            }
            Divider().overlay(Ink.line)
            row("power", L("开机自动启动", "Open at login")) {
                Toggle("", isOn: Binding(get: { model.openAtLogin }, set: { _ in model.perform(.toggleLogin) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
            Divider().overlay(Ink.line)
            Button { model.perform(.quit) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "xmark.circle").font(.system(size: 13)).foregroundColor(Ink.muted).frame(width: 18)
                    Text(L("退出 Agent Lumen", "Quit Agent Lumen"))
                    Spacer()
                    Text("⌘Q").font(.system(size: 11)).foregroundColor(Ink.faint)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).keyboardShortcut("q")
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
    }
}

// MARK: - app

struct GlowStyle {
    let light: Light
    let help: String           // what the state means and how it looks, for the panel's tooltip
    let onKey: String          // shown on the screen edges
    let keyboardKey: String    // shown on the keyboard
    let levelKey: String
    let period: Double
}

// seconds since the last keyboard or mouse input anywhere; needs no permission and reads no keys
func secondsSinceInput() -> TimeInterval {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let dot = CALayer()
    private let halo = CALayer()
    private var windows: [GlowWindow] = []
    private var sessions: [Session] = []
    private var state = Light.idle
    private var shownState: Light?
    private var glow: Light?            // the colour currently breathing on the screen edges
    private var fadeStart: CFTimeInterval?   // the screen glow is fading out
    private var keyboardState: Light?   // what the keyboard was last told
    // done on the screen goes dark once you have been back for a while; the keyboard and menu bar keep it
    private var doneSeenThrough = Date.distantPast   // done states written up to here have been seen
    private var doneShown: (stamp: Date, at: Date)?  // the newest done state and when it appeared
    private var backSince: Date?                     // first input after it appeared
    private var sliderPreview: (light: Light, until: Date)?
    private var animTimer: Timer?
    private let defaults = UserDefaults.standard
    private let keyboard = KeyboardLight()
    private let keyboardSettings = KeyboardSettings()
    private let popover = NSPopover()
    private let panel = PanelModel()

    // every state breathes in its own colour; each has an on/off switch and a strength slider.
    // strength = brightness at the top of the breath, from a faint glow (0.22) to full (1.0)
    private let styles = [
        GlowStyle(light: .attention, help: L("AI 助手正在等你批准操作或回答问题。\n蓝色呼吸灯，周期 1.2 秒。",
                                             "The agent is waiting for your approval or an answer.\nBlue, breathing every 1.2 s."),
                  onKey: "glowAttention", keyboardKey: "keyboardAttention", levelKey: "levelAttention", period: 1.2),
        GlowStyle(light: .working, help: L("AI 助手正在思考、运行命令或修改文件。\n橙色呼吸灯，周期 2 秒。",
                                           "The agent is thinking, running commands or editing files.\nOrange, breathing every 2 s."),
                  onKey: "glowWorking", keyboardKey: "keyboardWorking", levelKey: "levelWorking", period: 2.0),
        GlowStyle(light: .done, help: L("AI 助手已完成本轮任务，等你查看结果。\n绿色呼吸灯，周期 3 秒。",
                                        "The agent has finished and is waiting for you to look.\nGreen, breathing every 3 s."),
                  onKey: "glowDone", keyboardKey: "keyboardDone", levelKey: "levelDone", period: 3.0),
    ]
    private let minLevel = 0.22
    private let maxLevel = 1.0
    // how long the screen keeps green after you are back: 0 = at once, -1 = until the next task
    private let doneDelays: [(seconds: Double, title: String)] = [
        (0, L("立即", "At once")),
        (8, L("8 秒后", "8 s")),
        (30, L("30 秒后", "30 s")),
        (-1, L("不关闭", "Never")),
    ]
    private let fadeSeconds = 2.0

    private func style(_ light: Light) -> GlowStyle? { styles.first { $0.light == light } }

    func applicationDidFinishLaunching(_ note: Notification) {
        defaults.register(defaults: ["glowAttention": true, "glowDone": true, "glowWorking": true, "keyboardKeysBreathe": false,
                                      "keyboardAttention": true, "keyboardDone": true, "keyboardWorking": true, "doneScreenDelay": 8.0,
                                      "levelAttention": 1.0, "levelDone": 0.35, "levelWorking": 0.35])
        // the old menu had one switch for the whole keyboard; it is now a switch per state
        if defaults.object(forKey: "keyboardSync") as? Bool == false {
            styles.forEach { defaults.set(false, forKey: $0.keyboardKey) }
            defaults.removeObject(forKey: "keyboardSync")
        }
        panel.changed = { [weak self] key in self?.settingChanged(key) }
        panel.perform = { [weak self] action in self?.perform(action) }
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = NSHostingController(rootView: PanelView(model: panel, styles: styles, delays: doneDelays))
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        buildWindows()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.buildWindows() }
        setUpDot()
        keyboardSettings.currentPayload = { [weak self] in self?.keyboardPayload() ?? [] }
        keyboardSettings.start()
        refreshLoginItem()
        try? installHookScript()   // keep the installed hook in step with this version of the app
        tick()
        // .common: keep polling and animating while the menu is open
        let poll = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(poll, forMode: .common)
        // a keyboard can drop the bits without reconnecting (sleep, mode switch): send them again now and then
        let resend = Timer(timeInterval: 20, repeats: true) { [weak self] _ in self?.syncKeyboard(force: true) }
        RunLoop.main.add(resend, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.offerHooksOnFirstRun() }
        // for screenshots of the panel: AGENT_LUMEN_OPEN_PANEL=1 opens it right away
        if ProcessInfo.processInfo.environment["AGENT_LUMEN_OPEN_PANEL"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.togglePanel() }
        }
    }

    // levels in the keyboard's order: working, done, needs you; byte 4 bit0 = the whole keyboard breathes
    private func keyboardPayload() -> [UInt8] {
        let levels = [Light.working, .done, .attention].map { l -> UInt8 in
            guard let st = style(l) else { return 255 }
            return UInt8(max(0, min(255, (defaults.double(forKey: st.levelKey) * 255).rounded())))
        }
        return levels + [defaults.bool(forKey: "keyboardKeysBreathe") ? 1 : 0]
    }

    func applicationWillTerminate(_ note: Notification) {
        keyboard.show(.idle)   // hand the side lights back to the keyboard's own effect
    }

    private var legacyHooksInUse: Bool { targets.contains { $0.status == .legacy } }

    // the most urgent state among those switched on for a place (screen or keyboard)
    private func strongest(_ allowed: (GlowStyle) -> Bool) -> Light? {
        sessions.map(\.light).filter { l in style(l).map(allowed) ?? false }.max()
    }

    private func syncKeyboard(force: Bool = false) {
        let want = strongest { self.defaults.bool(forKey: $0.keyboardKey) } ?? .idle
        guard force || want != keyboardState else { return }
        keyboardState = want
        if want != .idle, !keyboard.names.isEmpty, keyboard.access == kIOHIDAccessTypeUnknown, !defaults.bool(forKey: "askedKeyboardAccess") {
            defaults.set(true, forKey: "askedKeyboardAccess")
            keyboard.requestAccess()
        }
        keyboard.show(want)
        if force { keyboard.apply() }
    }

    // false once you have been back at the computer for the chosen time since the newest done state appeared
    private func doneOnScreen() -> Bool {
        guard let newest = sessions.filter({ $0.light == .done }).map(\.changed).max(), newest > doneSeenThrough else {
            doneShown = nil
            backSince = nil
            return false
        }
        let now = Date()
        if doneShown?.stamp != newest {
            doneShown = (newest, now)
            backSince = nil
        }
        let delay = defaults.double(forKey: "doneScreenDelay")
        if delay < 0 { return true }
        if backSince == nil, let shown = doneShown, now.addingTimeInterval(-secondsSinceInput()) > shown.at {
            backSince = now
        }
        if let back = backSince, now.timeIntervalSince(back) >= delay {
            doneSeenThrough = newest
            lumenLog("screen: done seen, green glow off")
            return false
        }
        return true
    }

    private func buildWindows() {
        windows.forEach { $0.orderOut(nil) }
        let off = glowOffDisplays
        windows = Display.all.filter { !off.contains($0.id) }.map { GlowWindow(screen: $0.screen) }
        glow = nil
    }

    // a coloured dot drawn as layers inside the menu bar button, so it can breathe without image redraws
    private func setUpDot() {
        guard let button = item.button else { return }
        button.wantsLayer = true
        halo.frame = CGRect(x: 0, y: 0, width: 16, height: 16)
        halo.cornerRadius = 8
        dot.frame = CGRect(x: 0, y: 0, width: 9, height: 9)
        dot.cornerRadius = 4.5
        button.layer?.addSublayer(halo)
        button.layer?.addSublayer(dot)
    }

    private func tick() {
        sessions = readSessions(includeLegacy: legacyHooksInUse)
        state = sessions.map(\.light).max() ?? .idle
        if state != shownState {
            shownState = state
            showDot()
        }
        syncKeyboard()
        updateGlow()
        updateAnimating()
        if popover.isShown { refreshPanel() }
    }

    // menu bar dot: coloured when busy or done, a hollow ring when idle; animate() makes it breathe
    private func showDot() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let b = item.button?.bounds {
            halo.position = CGPoint(x: b.midX, y: b.midY)
            dot.position = CGPoint(x: b.midX, y: b.midY)
        }
        let lit = state != .idle
        item.button?.image = lit ? nil : idleIcon()
        dot.isHidden = !lit
        halo.isHidden = !lit
        dot.backgroundColor = state.color.cgColor
        halo.backgroundColor = state.color.withAlphaComponent(0.35).cgColor
        dot.opacity = 1
        halo.opacity = 1
        CATransaction.commit()
    }

    private func updateGlow() {
        var want: Light?
        if let p = sliderPreview, Date() < p.until {
            want = p.light
        } else {
            let done = doneOnScreen()
            want = strongest { self.defaults.bool(forKey: $0.onKey) && ($0.light != .done || done) }
        }
        if want == nil, glow != nil {
            // fade out instead of switching off at once
            if fadeStart == nil { fadeStart = CACurrentMediaTime() }
            if CACurrentMediaTime() - fadeStart! < fadeSeconds { return }
        }
        fadeStart = nil
        guard want != glow else { return }
        glow = want
        guard let want else {
            windows.forEach { $0.orderOut(nil) }
            return
        }
        for w in windows {
            w.glow.setColor(want.color)
            w.glow.setLevel(0)
            w.orderFrontRegardless()
        }
    }

    // fast frames only while something moves: 30 fps for the screen glow, 10 fps for the menu bar dot
    private func updateAnimating() {
        let interval: TimeInterval? = glow != nil ? 1.0 / 30 : state != .idle ? 1.0 / 10 : nil
        if animTimer?.timeInterval == interval { return }
        animTimer?.invalidate()
        animTimer = nil
        if let interval {
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.animate() }
            RunLoop.main.add(timer, forMode: .common)
            animTimer = timer
        } else {
            showDot()   // settle the dot
        }
    }

    // Core Animation's own animations never draw in the background glow window, so the app drives every frame
    private func animate() {
        let t = CACurrentMediaTime()
        if let st = style(state) {
            let w = wave(t, st.period)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dot.opacity = Float(0.35 + 0.65 * w)
            halo.opacity = Float(w)
            CATransaction.commit()
        }
        guard let glow, let st = style(glow) else { return }
        let top = CGFloat(defaults.double(forKey: st.levelKey))
        var level = top * (0.35 + 0.65 * wave(t, st.period))
        if let f = fadeStart { level *= CGFloat(max(0, 1 - (t - f) / fadeSeconds)) }
        windows.forEach { $0.glow.setLevel(level) }
        if let f = fadeStart, t - f >= fadeSeconds { updateGlow() }
    }

    // hollow ring that follows the menu bar's light/dark look
    private func idleIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 4.5, dy: 4.5))
            NSColor.black.setStroke()
            ring.lineWidth = 1.5
            ring.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: panel

    @objc private func togglePanel() {
        if popover.isShown { return popover.performClose(nil) }
        guard let button = item.button else { return }
        tick()
        refreshPanel()
        panel.selected = state == .idle ? .working : state   // open on what is lit now
        // as tall as the content, but never taller than the screen; beyond that the panel scrolls
        let natural = NSHostingView(rootView: PanelContent(model: panel, styles: styles, delays: doneDelays)).fittingSize.height
        let room = (button.window?.screen ?? NSScreen.main).map { $0.visibleFrame.height - 24 } ?? natural
        panel.height = min(natural, room)
        popover.contentSize = NSSize(width: panelWidth, height: panel.height)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func refreshPanel() {
        panel.state = state
        let byAgent = Dictionary(grouping: sessions, by: \.agent)
        // one line per agent: just the count when all its sessions are in the state the header shows
        panel.summary = byAgent.isEmpty
            ? [L("暂无进行中的任务", "Nothing in progress")]
            : ["Claude Code", "WorkBuddy", "Devin"].compactMap { agent in
                guard let list = byAgent[agent] else { return nil }
                if list.allSatisfy({ $0.light == state }) {
                    return agent + " · " + L("\(list.count) 个会话", "\(list.count) session\(list.count == 1 ? "" : "s")")
                }
                let parts = [Light.attention, .working, .done].compactMap { l -> String? in
                    let n = list.filter { $0.light == l }.count
                    return n == 0 ? nil : "\(l.label) \(n)"
                }
                return agent + " · " + parts.joined(separator: L("、", ", "))
            }
        panel.doneOnScreen = glow == .done && fadeStart == nil && sliderPreview == nil
        // macOS numbers keyboards with the same name ("NuPhy Air60 V2-1"); the number means nothing to people
        panel.keyboardName = keyboard.names.first.map { $0.replacingOccurrences(of: #"-\d+$"#, with: "", options: .regularExpression) }
        panel.keyboardSync = keyboardSettings.status
        panel.keyboardNeedsAccess = !keyboard.names.isEmpty && keyboard.access != kIOHIDAccessTypeGranted
        panel.agents = targets.enumerated().compactMap { i, t in
            let status = t.status
            return status == .absent ? nil : AgentRow(id: i, name: t.name, status: status)
        }
        panel.openAtLogin = FileManager.default.fileExists(atPath: loginAgentPath)
        let off = glowOffDisplays
        panel.displays = Display.all.map { DisplayRow(id: $0.id, name: $0.name, builtIn: $0.builtIn, on: !off.contains($0.id)) }
    }

    private func settingChanged(_ key: String) {
        if let st = styles.first(where: { $0.levelKey == key }) {
            // dragging shows that colour breathing at the new strength for a moment
            sliderPreview = (st.light, Date().addingTimeInterval(1.5))
            updateGlow()
            updateAnimating()
            keyboardSettings.send()
        } else if key == "keyboardKeysBreathe" {
            keyboardSettings.send(force: true)
        } else if styles.contains(where: { $0.keyboardKey == key }) {
            sessions = readSessions(includeLegacy: legacyHooksInUse)
            syncKeyboard(force: true)
        } else {
            tick()
        }
    }

    private func perform(_ action: PanelAction) {
        switch action {
        case .dismissDone:
            if let newest = sessions.filter({ $0.light == .done }).map(\.changed).max() { doneSeenThrough = newest }
            tick()
        case .toggleAgent(let i):
            popover.performClose(nil)
            let t = targets[i]
            connect([t], install: t.status != .lumen)
        case .askKeyboardAccess:
            // macOS only lets an app set keyboard LEDs with Input Monitoring; the grant applies after a relaunch
            keyboard.requestAccess()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        case .toggleLogin:
            if FileManager.default.fileExists(atPath: loginAgentPath) {
                try? FileManager.default.removeItem(atPath: loginAgentPath)
            } else {
                writeLoginItem()
            }
            refreshPanel()
        case .toggleDisplay(let id):
            var off = glowOffDisplays
            if off.contains(id) { off.remove(id) } else { off.insert(id) }
            glowOffDisplays = off
            buildWindows()
            tick()
            refreshPanel()
        case .quit:
            NSApp.terminate(nil)
        }
    }

    // MARK: hooks

    private func connect(_ list: [AgentTarget], install: Bool) {
        var failed: [String] = []
        do { try installHookScript() } catch { failed.append(L("钩子脚本", "hook script")) }
        for t in list {
            do { try setHooks(t, install: install) } catch { failed.append(t.name) }
        }
        if !failed.isEmpty {
            alert(L("下面这些没能改好（配置文件读不了），原文件没有动：", "These could not be updated (unreadable settings file); nothing was changed:")
                  + "\n" + failed.joined(separator: "\n"))
        } else if install {
            alert(L("已接入：", "Connected: ") + list.map(\.name).joined(separator: L("、", ", "))
                  + L("\n\n已经开着的会话要重新打开才会亮灯（Devin 桌面版要退出重开，并在“信任此工作区”时选信任）。",
                      "\n\nSessions that are already open start reporting after a restart (quit and reopen Devin Desktop, and trust the workspace when asked)."))
        }
    }

    private func offerHooksOnFirstRun() {
        guard !defaults.bool(forKey: "offeredHooks") else { return }
        let candidates = targets.filter { $0.status == .off || $0.status == .legacy }
        guard !candidates.isEmpty else { return }
        defaults.set(true, forKey: "offeredHooks")
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = L("接入你的 AI 工具？", "Connect your AI agents?")
        a.informativeText = L("Agent Lumen 要在下面这些工具的设置里加几条钩子，才能知道它们在干活、在等你还是已经完成：",
                              "Agent Lumen adds a few hooks to these agents' settings so it can tell when they are working, need you, or are done:")
            + "\n\n" + candidates.map { "• \($0.name)  (\($0.settings.replacingOccurrences(of: home, with: "~")))" }.joined(separator: "\n")
            + L("\n\n修改前会自动备份原文件；以后可以在菜单里随时断开。",
                "\n\nEach file is backed up first; you can disconnect any time from the menu.")
        a.addButton(withTitle: L("接入", "Connect"))
        a.addButton(withTitle: L("以后再说", "Not now"))
        if a.runModal() == .alertFirstButtonReturn {
            connect(candidates, install: true)
        }
    }

    private func alert(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Agent Lumen"
        a.informativeText = text
        a.runModal()
    }

    // MARK: login item

    private func writeLoginItem() {
        guard let exe = Bundle.main.executablePath else { return }
        let plist: [String: Any] = ["Label": loginLabel, "ProgramArguments": [exe], "RunAtLoad": true]
        try? FileManager.default.createDirectory(atPath: (loginAgentPath as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        (plist as NSDictionary).write(toFile: loginAgentPath, atomically: true)
    }

    // the app may have been moved since the login item was written
    private func refreshLoginItem() {
        guard let exe = Bundle.main.executablePath,
              let plist = NSDictionary(contentsOfFile: loginAgentPath),
              (plist["ProgramArguments"] as? [String])?.first != exe else { return }
        writeLoginItem()
    }
}

// command line: AgentLumen --connect | --disconnect   wires every installed agent without opening the app
let args = CommandLine.arguments
if args.contains("--connect") || args.contains("--disconnect") {
    let install = args.contains("--connect")
    if install { try? installHookScript() }
    for t in targets {
        let s = t.status
        guard s != .absent, install || s == .lumen else {
            print("\(t.name): \(s == .absent ? "not installed" : "not connected")")
            continue
        }
        do {
            try setHooks(t, install: install)
            print("\(t.name): \(install ? "connected" : "disconnected")")
        } catch {
            print("\(t.name): failed — \(error)")
        }
    }
    exit(0)
}

let bundleID = Bundle.main.bundleIdentifier ?? loginLabel
if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
