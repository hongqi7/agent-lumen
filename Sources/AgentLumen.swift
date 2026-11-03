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
        case .working:   return L("正在执行", "working")
        case .attention: return L("等待你确认", "needs you")
        case .done:      return L("已完成", "done")
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

// MARK: - panel

struct AgentRow: Identifiable {
    let id: Int
    let name: String
    let status: AgentTarget.Status
}

enum PanelAction { case dismissDone, toggleAgent(Int), askKeyboardAccess, toggleLogin, quit }

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

struct PanelView: View {
    @ObservedObject var model: PanelModel
    let styles: [GlowStyle]
    let delays: [(seconds: Double, title: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            states.padding(16)
            Divider()
            keyboard.padding(16)
            Divider()
            agents.padding(16)
            Divider()
            HStack {
                Text(L("开机时自动打开", "Open at login"))
                Spacer()
                Toggle("", isOn: Binding(get: { model.openAtLogin }, set: { _ in model.perform(.toggleLogin) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            Button { model.perform(.quit) } label: {
                HStack {
                    Text(L("退出 Agent Lumen", "Quit Agent Lumen"))
                    Spacer()
                    Text("⌘Q").foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .keyboardShortcut("q")
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .font(.system(size: 13))
        .frame(width: 380)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
    }

    // wrapping text for explanations
    private func note(_ text: String, size: CGFloat = 11, secondary: Bool = false) -> some View {
        Text(text).font(.system(size: size)).foregroundStyle(secondary ? .secondary : .tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func toggle(_ key: String) -> some View {
        Toggle("", isOn: model.bool(key)).labelsHidden().toggleStyle(.switch).controlSize(.mini).frame(width: 52)
    }

    private var headline: String {
        switch model.state {
        case .attention: return L("等待你确认", "Needs you")
        case .working:   return L("正在执行", "Working")
        case .done:      return L("任务已完成", "Done")
        case .idle:      return L("当前没有任务", "No tasks right now")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            let color = Color(nsColor: model.state.color)
            RoundedRectangle(cornerRadius: 9)
                .fill(model.state == .idle ? Color.primary.opacity(0.06) : color.opacity(0.18))
                .frame(width: 36, height: 36)
                .overlay(Group {
                    if model.state == .idle {
                        Circle().stroke(Color.secondary, lineWidth: 1.5).frame(width: 11, height: 11)
                    } else {
                        Circle().fill(color).frame(width: 12, height: 12)
                    }
                })
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.system(size: 14, weight: .semibold))
                ForEach(model.summary, id: \.self) { note($0, size: 12, secondary: true) }
            }
            Spacer(minLength: 0)
            if model.doneOnScreen {
                Button(L("熄灭屏幕绿光", "Dismiss glow")) { model.perform(.dismissDone) }.controlSize(.small)
            }
        }
        .padding(16)
    }

    private func columnTitle(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 12))
            Text(title).font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
        .frame(width: 52)
    }

    private var states: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom) {
                caption(L("AI 助手处于以下状态时亮灯", "Light up when an agent"))
                Spacer()
                columnTitle("display", L("屏幕边缘", "Screen"))
                columnTitle("keyboard", L("键盘", "Keyboard"))
            }
            note(L("关闭某个开关后，该位置在这个状态下不亮灯；键盘会恢复你原本设置的灯效。",
                   "Switch one off and that place stays dark in that state; the keyboard goes back to its own effect."))
                .padding(.top, 4)
            ForEach(Array(styles.enumerated()), id: \.offset) { i, st in
                if i > 0 { Divider() }
                stateRow(st).padding(.vertical, 12)
            }
        }
    }

    private func stateRow(_ st: GlowStyle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle().fill(Color(nsColor: st.light.color)).frame(width: 10, height: 10)
                Text(st.light.label).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
                toggle(st.onKey)
                toggle(st.keyboardKey)
            }
            VStack(alignment: .leading, spacing: 2) {
                note(st.meaning, size: 12, secondary: true)
                note(st.pattern)
            }
            .padding(.leading, 20)
            HStack(spacing: 8) {
                Text(L("亮度", "Brightness")).font(.system(size: 12)).foregroundStyle(.secondary)
                Slider(value: model.double(st.levelKey), in: 0.22...1.0).controlSize(.small)
                Text("\(Int((UserDefaults.standard.double(forKey: st.levelKey) * 100).rounded()))%")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
            .padding(.leading, 20)
            if st.light == .done { doneDelay.padding(.leading, 20).padding(.top, 4) }
        }
    }

    private var doneDelay: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("屏幕上的绿光何时熄灭", "When the green glow leaves the screen")).font(.system(size: 13, weight: .medium))
            note(L("任务完成时你不在电脑前，绿光会一直亮着。你回来后，只要移动鼠标或按下任意键，就按下面的时间熄灭：",
                   "If you are away when a task finishes, the glow stays on. Once you move the mouse or press a key, it goes out after:"),
                 size: 12, secondary: true)
            Picker("", selection: model.double("doneScreenDelay")) {
                ForEach(delays, id: \.seconds) { Text($0.title).tag($0.seconds) }
            }
            .pickerStyle(.segmented).labelsHidden()
            note(L("只影响屏幕边缘。键盘和菜单栏图标会保持绿色，直到你开始下一个任务。",
                   "Only the screen edges. The keyboard and the menu bar icon stay green until your next task."))
        }
    }

    private var keyboardChip: (text: String, good: Bool) {
        switch model.keyboardSync {
        case .synced:      return (L("USB 有线连接 · 设置已写入", "USB · settings saved"), true)
        case .pending:     return (L("USB 有线连接 · 正在写入设置", "USB · saving settings"), true)
        case .oldFirmware: return (L("固件版本过旧", "Firmware too old"), false)
        case .noCable:     return (L("无线连接", "Wireless"), true)
        }
    }

    private var keyboard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                caption(L("NuPhy 键盘", "NuPhy keyboard"))
                Spacer()
                if model.keyboardName != nil {
                    let chip = keyboardChip
                    HStack(spacing: 5) {
                        Circle().fill(chip.good ? Color.green : Color.orange).frame(width: 6, height: 6)
                        Text(chip.text).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
            }
            if let name = model.keyboardName {
                HStack(spacing: 8) {
                    Image(systemName: "keyboard").foregroundStyle(.secondary)
                    Text(name)
                }
                if model.keyboardNeedsAccess {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            note(L("需要「输入监控」权限才能控制键盘灯。Agent Lumen 只设置键盘指示灯，不读取任何按键。",
                                   "Input Monitoring is needed to set the keyboard lights. Agent Lumen only sets indicator LEDs and never reads keys."),
                                 size: 12, secondary: true)
                            Button(L("前往开启", "Open settings")) { model.perform(.askKeyboardAccess) }.controlSize(.small)
                        }
                    }
                }
                if model.keyboardSync == .oldFirmware {
                    note(L("当前固件不支持调节亮度和「整块键盘一起亮」，请更新键盘固件。",
                           "This firmware can't take brightness or whole-keyboard settings. Update the keyboard firmware."),
                         size: 12, secondary: true)
                }
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("整块键盘一起亮", "Whole keyboard lights up"))
                        note(L("开启后，按键背光也变成提示颜色并同步明暗；关闭时只有侧边灯条亮。",
                               "Key backlights take the state colour and breathe too; off, only the side light bar shows it."),
                             size: 12, secondary: true)
                    }
                    Spacer(minLength: 0)
                    toggle("keyboardKeysBreathe")
                }
                .padding(.leading, 24)
                note(L("亮度和「整块键盘一起亮」需在 USB 有线连接时写入键盘。之后改用蓝牙或 2.4G 无线连接，键盘会继续使用最后一次写入的设置。",
                       "Brightness and the whole-keyboard switch are saved to the keyboard over USB. Over Bluetooth or 2.4G it keeps the last saved settings."))
                    .padding(.leading, 24)
            } else {
                Text(L("未检测到 NuPhy 键盘", "No NuPhy keyboard connected"))
                note(L("刷入本项目固件的 NuPhy Air60 V2 或 Halo65 V2 连接到这台 Mac 后，会显示在这里。",
                       "A NuPhy Air60 V2 or Halo65 V2 with this project's firmware shows up here once connected."))
            }
        }
    }

    private func chipText(_ a: AgentRow) -> String {
        switch a.status {
        case .lumen:  return a.name
        case .legacy: return a.name + L(" · 需更新", " · update needed")
        default:      return a.name + L(" · 未连接", " · not connected")
        }
    }

    private func menuText(_ a: AgentRow) -> String {
        switch a.status {
        case .lumen:  return L("断开 ", "Disconnect ") + a.name
        case .legacy: return L("更新 ", "Update ") + a.name + L(" 的钩子", " hooks")
        default:      return L("连接 ", "Connect ") + a.name
        }
    }

    private var agents: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                caption(L("已连接的 AI 助手", "AI agents"))
                Spacer()
                if !model.agents.isEmpty {
                    Menu(L("添加或移除", "Add or remove")) {
                        ForEach(model.agents) { a in Button(menuText(a)) { model.perform(.toggleAgent(a.id)) } }
                    }
                    .menuStyle(.borderlessButton).fixedSize().font(.system(size: 12))
                }
            }
            if model.agents.isEmpty {
                note(L("这台 Mac 上没有找到支持的 AI 助手（Claude Code、WorkBuddy、Devin）。",
                       "No supported agent (Claude Code, WorkBuddy, Devin) found on this Mac."), size: 12, secondary: true)
            } else {
                HStack(spacing: 6) {
                    ForEach(model.agents) { a in
                        HStack(spacing: 4) {
                            Image(systemName: a.status == .lumen ? "checkmark" : a.status == .legacy ? "exclamationmark.triangle" : "circle.dashed")
                                .foregroundStyle(a.status == .lumen ? Color.green : a.status == .legacy ? Color.orange : Color.secondary)
                            Text(chipText(a)).foregroundStyle(.secondary)
                        }
                        .font(.system(size: 11))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                }
                if model.agents.contains(where: { $0.status != .lumen }) {
                    note(L("未连接的助手不会触发提示灯；「需更新」表示仍在使用旧版键盘灯钩子。可在「添加或移除」中处理。",
                           "Agents that are not connected don't light anything; \"update needed\" means old keyboard-light hooks. Fix either under Add or remove."))
                }
            }
        }
    }
}

// MARK: - app

struct GlowStyle {
    let light: Light
    let meaning: String        // what the state means, for the panel
    let pattern: String        // how it looks
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
        GlowStyle(light: .attention, meaning: L("需要你批准一项操作，或回答它的提问", "Waiting for your approval or an answer"),
                  pattern: L("蓝光，每 1.2 秒明暗一次", "Blue, one breath every 1.2 s"),
                  onKey: "glowAttention", keyboardKey: "keyboardAttention", levelKey: "levelAttention", period: 1.2),
        GlowStyle(light: .working, meaning: L("正在思考，或正在运行命令、修改文件", "Thinking, running commands or editing files"),
                  pattern: L("橙光，每 2 秒明暗一次", "Orange, one breath every 2 s"),
                  onKey: "glowWorking", keyboardKey: "keyboardWorking", levelKey: "levelWorking", period: 2.0),
        GlowStyle(light: .done, meaning: L("本轮任务已做完，等你查看结果", "Finished, waiting for you to look"),
                  pattern: L("绿光，每 3 秒明暗一次", "Green, one breath every 3 s"),
                  onKey: "glowDone", keyboardKey: "keyboardDone", levelKey: "levelDone", period: 3.0),
    ]
    private let minLevel = 0.22
    private let maxLevel = 1.0
    // how long the screen keeps green after you are back: 0 = at once, -1 = until the next task
    private let doneDelays: [(seconds: Double, title: String)] = [
        (0, L("立即", "At once")),
        (8, L("8 秒后", "8 s")),
        (30, L("30 秒后", "30 s")),
        (-1, L("一直亮着", "Never")),
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
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func refreshPanel() {
        panel.state = state
        let byAgent = Dictionary(grouping: sessions, by: \.agent)
        panel.summary = byAgent.isEmpty
            ? [L("AI 助手开始工作后，这里会显示它的状态。", "Agent states show up here once an agent starts working.")]
            : ["Claude Code", "WorkBuddy", "Devin"].compactMap { agent in
                guard let list = byAgent[agent] else { return nil }
                let parts = [Light.attention, .working, .done].compactMap { l -> String? in
                    let n = list.filter { $0.light == l }.count
                    return n == 0 ? nil : L("\(n) 个会话\(l.label)", "\(n) \(l.label)")
                }
                return agent + L("：", ": ") + parts.joined(separator: L("，", ", "))
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
