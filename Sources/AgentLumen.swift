// Agent Lumen (灵光): a menu bar light, a screen-edge glow and (optionally) NuPhy keyboard side lights
// that show what your AI coding agents are doing — Claude Code, WorkBuddy and Devin.
// Blue: waiting for your approval. Orange: working. Green: done.
// Each agent session reports its state through hooks (Resources/lumen-hook); this app is the only reader.
import AppKit
import IOKit.hid
import QuartzCore

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
        case .working:   return L("任务中", "working")
        case .attention: return L("等你批准", "needs you")
        case .done:      return L("完成任务", "done")
        case .idle:      return L("空闲", "idle")
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

// MARK: - app

struct GlowStyle {
    let light: Light
    let title: String
    let onKey: String          // shown on the screen edges
    let keyboardKey: String    // shown on the keyboard
    let levelKey: String
    let period: Double
}

// seconds since the last keyboard or mouse input anywhere; needs no permission and reads no keys
func secondsSinceInput() -> TimeInterval {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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

    // every state breathes in its own colour; each has an on/off switch and a strength slider.
    // strength = brightness at the top of the breath, from a faint glow (0.22) to full (1.0)
    private let styles = [
        GlowStyle(light: .attention, title: L("等你批准：蓝光呼吸", "Needs you: blue"), onKey: "glowAttention", keyboardKey: "keyboardAttention",
                  levelKey: "levelAttention", period: 1.2),
        GlowStyle(light: .done, title: L("完成任务：绿光呼吸", "Done: green"), onKey: "glowDone", keyboardKey: "keyboardDone",
                  levelKey: "levelDone", period: 3.0),
        GlowStyle(light: .working, title: L("任务中：橙光呼吸", "Working: orange"), onKey: "glowWorking", keyboardKey: "keyboardWorking",
                  levelKey: "levelWorking", period: 2.0),
    ]
    // how long the screen keeps green after you are back: 0 = at once, -1 = until the next task
    private let doneDelays: [(seconds: Double, title: String)] = [
        (0, L("你一动就熄灭", "as soon as you're back")),
        (8, L("你回来 8 秒后熄灭", "8 seconds after you're back")),
        (30, L("你回来 30 秒后熄灭", "30 seconds after you're back")),
        (-1, L("一直亮到下一个任务", "until the next task")),
    ]
    private let fadeSeconds = 2.0
    private let minLevel = 0.22
    private let maxLevel = 1.0

    private func style(_ light: Light) -> GlowStyle? { styles.first { $0.light == light } }

    func applicationDidFinishLaunching(_ note: Notification) {
        defaults.register(defaults: ["glowAttention": true, "glowDone": true, "glowWorking": true, "keyboardSync": true, "keyboardKeysBreathe": false,
                                      "keyboardAttention": true, "keyboardDone": true, "keyboardWorking": true, "doneScreenDelay": 8.0,
                                      "levelAttention": 1.0, "levelDone": 0.35, "levelWorking": 0.35])
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
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
        let want = defaults.bool(forKey: "keyboardSync") ? strongest { self.defaults.bool(forKey: $0.keyboardKey) } ?? .idle : .idle
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
        windows = NSScreen.screens.map { GlowWindow(screen: $0) }
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

    private func menuDot(_ light: Light) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            light.color.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2)).fill()
            return true
        }
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        sessions = readSessions(includeLegacy: legacyHooksInUse)

        let byAgent = Dictionary(grouping: sessions, by: \.agent)
        if byAgent.isEmpty {
            menu.addItem(disabled(L("当前没有会话", "No agent sessions")))
        }
        for agent in ["Claude Code", "WorkBuddy", "Devin"] {
            guard let list = byAgent[agent] else { continue }
            let parts = [Light.attention, .working, .done].compactMap { l -> String? in
                let n = list.filter { $0.light == l }.count
                return n > 0 ? "\(l.label) \(n)" : nil
            }
            let line = disabled("\(agent)\(L("：", ": "))\(parts.joined(separator: L("，", ", ")))")
            line.image = menuDot(list.map(\.light).max() ?? .idle)
            menu.addItem(line)
        }

        menu.addItem(.separator())
        menu.addItem(disabled(L("屏幕边缘发光（拖动滑块可预览）", "Screen edge glow (drag to preview)")))
        for st in styles {
            let mi = NSMenuItem(title: st.title, action: #selector(toggleOption(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = st.onKey
            mi.state = defaults.bool(forKey: st.onKey) ? .on : .off
            mi.image = menuDot(st.light)
            menu.addItem(mi)
            menu.addItem(sliderItem(st))
            if st.light == .done { menu.addItem(doneDelayItem()) }
        }
        if glow == .done && fadeStart == nil && sliderPreview == nil {
            let ok = NSMenuItem(title: L("知道了，屏幕上的绿光先灭掉", "Got it — turn off the green glow"), action: #selector(dismissDone), keyEquivalent: "")
            ok.target = self
            menu.addItem(ok)
        }

        menu.addItem(.separator())
        menu.addItem(disabled(L("接入的 AI 工具", "Connected agents")))
        for (i, t) in targets.enumerated() {
            let status = t.status
            if status == .absent { continue }
            let text: String
            switch status {
            case .lumen:  text = L("已接入", "connected")
            case .legacy: text = L("用的是旧版键盘灯钩子，点击换成共享钩子", "old keyboard-light hooks — click to switch")
            default:      text = L("未接入，点击接入", "not connected — click to connect")
            }
            let mi = NSMenuItem(title: "\(t.name)\(L("：", ": "))\(text)", action: #selector(toggleHooks(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = i
            mi.state = status == .lumen ? .on : .off
            menu.addItem(mi)
        }

        menu.addItem(.separator())
        let names = keyboard.names
        if names.isEmpty {
            menu.addItem(disabled(L("键盘灯：没有连接 NuPhy 键盘", "Keyboard light: no NuPhy keyboard connected")))
        } else {
            let mi = NSMenuItem(title: L("键盘灯同步：", "Keyboard light: ") + names.joined(separator: L("、", ", ")),
                                action: #selector(toggleKeyboard), keyEquivalent: "")
            mi.target = self
            mi.state = defaults.bool(forKey: "keyboardSync") ? .on : .off
            menu.addItem(mi)
            if defaults.bool(forKey: "keyboardSync") {
                for st in styles {
                    let k = NSMenuItem(title: L("    键盘显示", "    Show on keyboard: ") + st.light.label, action: #selector(toggleOption(_:)), keyEquivalent: "")
                    k.target = self
                    k.representedObject = st.keyboardKey
                    k.state = defaults.bool(forKey: st.keyboardKey) ? .on : .off
                    k.image = menuDot(st.light)
                    menu.addItem(k)
                }
            }
            let keys = NSMenuItem(title: L("整个键盘一起呼吸", "Whole keyboard breathes too"), action: #selector(toggleKeysBreathe), keyEquivalent: "")
            keys.target = self
            keys.state = defaults.bool(forKey: "keyboardKeysBreathe") ? .on : .off
            menu.addItem(keys)
            let note: String
            switch keyboardSettings.status {
            case .synced:      note = L("    亮度和开关已同步到键盘（插线时实时调整）", "    Brightness and switch synced (live while wired)")
            case .oldFirmware: note = L("    键盘固件太旧，不支持调亮度，请更新固件", "    Keyboard firmware too old for these settings")
            case .pending:     note = L("    正在同步到键盘…", "    Syncing to the keyboard…")
            case .noCable:     note = L("    亮度和开关在插线时同步到键盘，拔线后照样生效", "    Brightness and switch sync while wired, then stay")
            }
            menu.addItem(disabled(note))
            if defaults.bool(forKey: "keyboardSync") && keyboard.access != kIOHIDAccessTypeGranted {
                let ask = NSMenuItem(title: L("    需要“输入监控”权限，点此开启", "    Needs Input Monitoring — click to allow"),
                                     action: #selector(askKeyboardAccess), keyEquivalent: "")
                ask.target = self
                menu.addItem(ask)
            }
        }

        menu.addItem(.separator())
        let login = NSMenuItem(title: L("开机自动启动", "Open at login"), action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = FileManager.default.fileExists(atPath: loginAgentPath) ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: L("退出 Agent Lumen", "Quit Agent Lumen"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    private func sliderItem(_ st: GlowStyle) -> NSMenuItem {
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        let weak = NSTextField(labelWithString: L("弱", "dim"))
        let strong = NSTextField(labelWithString: L("强", "bright"))
        for l in [weak, strong] {
            l.font = .menuFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
        }
        weak.alignment = .right
        weak.frame = NSRect(x: 18, y: 5, width: 36, height: 15)
        strong.frame = NSRect(x: 240, y: 5, width: 40, height: 15)
        let slider = NSSlider(value: defaults.double(forKey: st.levelKey), minValue: minLevel, maxValue: maxLevel,
                              target: self, action: #selector(levelChanged(_:)))
        slider.isContinuous = true
        slider.tag = st.light.rawValue
        slider.frame = NSRect(x: 58, y: 2, width: 178, height: 22)
        [weak, slider, strong].forEach { box.addSubview($0) }
        let mi = NSMenuItem()
        mi.view = box
        return mi
    }

    private func doneDelayItem() -> NSMenuItem {
        let current = defaults.double(forKey: "doneScreenDelay")
        let title = doneDelays.first { $0.seconds == current }?.title ?? doneDelays[1].title
        let mi = NSMenuItem(title: L("    屏幕绿光：", "    Screen green: ") + title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for d in doneDelays {
            let o = NSMenuItem(title: d.title, action: #selector(setDoneDelay(_:)), keyEquivalent: "")
            o.target = self
            o.representedObject = d.seconds
            o.state = d.seconds == current ? .on : .off
            sub.addItem(o)
        }
        sub.addItem(.separator())
        sub.addItem(disabled(L("键盘和状态栏的绿色会一直保持到下一个任务", "The keyboard and menu bar stay green until the next task")))
        mi.submenu = sub
        return mi
    }

    @objc private func setDoneDelay(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Double else { return }
        defaults.set(seconds, forKey: "doneScreenDelay")
        tick()
    }

    @objc private func dismissDone() {
        if let newest = sessions.filter({ $0.light == .done }).map(\.changed).max() { doneSeenThrough = newest }
        tick()
    }

    // dragging shows that colour breathing at the new strength for a moment
    @objc private func levelChanged(_ sender: NSSlider) {
        guard let light = Light(rawValue: sender.tag), let st = style(light) else { return }
        defaults.set(sender.doubleValue, forKey: st.levelKey)
        sliderPreview = (light, Date().addingTimeInterval(1.5))
        updateGlow()
        updateAnimating()
        keyboardSettings.send()
    }

    @objc private func toggleKeysBreathe() {
        defaults.set(!defaults.bool(forKey: "keyboardKeysBreathe"), forKey: "keyboardKeysBreathe")
        keyboardSettings.send(force: true)
    }

    @objc private func toggleKeyboard() {
        defaults.set(!defaults.bool(forKey: "keyboardSync"), forKey: "keyboardSync")
        syncKeyboard(force: true)
    }

    // macOS only lets an app set keyboard LEDs with Input Monitoring; the grant applies after a relaunch
    @objc private func askKeyboardAccess() {
        keyboard.requestAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    @objc private func toggleOption(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        defaults.set(!defaults.bool(forKey: key), forKey: key)
        tick()
    }

    // MARK: hooks

    @objc private func toggleHooks(_ sender: NSMenuItem) {
        let t = targets[sender.tag]
        connect([t], install: t.status != .lumen)
    }

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

    @objc private func toggleLogin() {
        if FileManager.default.fileExists(atPath: loginAgentPath) {
            try? FileManager.default.removeItem(atPath: loginAgentPath)
        } else {
            writeLoginItem()
        }
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
