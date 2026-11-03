// Agent Lumen (灵光): a menu bar light and a screen-edge glow that show what your AI coding agents
// are doing — Claude Code, WorkBuddy and Devin. Blue: waiting for your approval. Orange: working.
// Green: done. Each agent session reports its state through hooks (Resources/lumen-hook).
import AppKit
import QuartzCore

let home = ProcessInfo.processInfo.environment["AGENT_LUMEN_HOME"] ?? NSHomeDirectory()   // override for tests
let lumenDir = home + "/.agent-lumen"
// our own hook writes here; the NuPhy keyboard light (claude-light) writes the second folder
let sessionDirs = [lumenDir + "/sessions", home + "/.claude/claude-light/sessions"]
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
}

func readSessions() -> [Session] {
    let fm = FileManager.default
    let now = Date()
    var seen = Set<String>()
    var out: [Session] = []
    for dir in sessionDirs {
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
            out.append(Session(agent: agent, light: light))
        }
    }
    return out
}

// 0...1...0 once per period
func wave(_ t: CFTimeInterval, _ period: Double) -> CGFloat {
    CGFloat(0.5 - 0.5 * cos(2 * Double.pi * t / period))
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

    enum Status { case absent, off, lumen, keyboard }

    var status: Status {
        guard FileManager.default.fileExists(atPath: configDir) else { return .absent }
        let text = (try? String(contentsOfFile: settings, encoding: .utf8)) ?? ""
        if text.contains("lumen-hook") { return .lumen }
        if text.contains("claude-light") { return .keyboard }   // already reporting through the keyboard light
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

// Rewrites one settings file: drops earlier Lumen entries, then (when installing) puts ours first in
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
            .contains { ($0["command"] as? String ?? "").contains("lumen-hook") }
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

// MARK: - app

struct GlowStyle {
    let light: Light
    let title: String
    let onKey: String
    let levelKey: String
    let period: Double
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
    private var sliderPreview: (light: Light, until: Date)?
    private var animTimer: Timer?
    private let defaults = UserDefaults.standard

    // every state breathes in its own colour; each has an on/off switch and a strength slider.
    // strength = brightness at the top of the breath, from a faint glow (0.22) to full (1.0)
    private let styles = [
        GlowStyle(light: .attention, title: L("等你批准：蓝光呼吸", "Needs you: blue"), onKey: "glowAttention", levelKey: "levelAttention", period: 1.2),
        GlowStyle(light: .done, title: L("完成任务：绿光呼吸", "Done: green"), onKey: "glowDone", levelKey: "levelDone", period: 3.0),
        GlowStyle(light: .working, title: L("任务中：橙光呼吸", "Working: orange"), onKey: "glowWorking", levelKey: "levelWorking", period: 2.0),
    ]
    private let minLevel = 0.22
    private let maxLevel = 1.0

    private func style(_ light: Light) -> GlowStyle? { styles.first { $0.light == light } }

    func applicationDidFinishLaunching(_ note: Notification) {
        defaults.register(defaults: ["glowAttention": true, "glowDone": true, "glowWorking": true,
                                      "levelAttention": 1.0, "levelDone": 0.35, "levelWorking": 0.35])
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        buildWindows()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.buildWindows() }
        setUpDot()
        refreshLoginItem()
        try? installHookScript()   // keep the installed hook in step with this version of the app
        tick()
        // .common: keep polling and animating while the menu is open
        let poll = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(poll, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.offerHooksOnFirstRun() }
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
        sessions = readSessions()
        state = sessions.map(\.light).max() ?? .idle
        if state != shownState {
            shownState = state
            showDot()
        }
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
        } else if let st = style(state), defaults.bool(forKey: st.onKey) {
            want = state
        }
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
        let level = top * (0.35 + 0.65 * wave(t, st.period))
        windows.forEach { $0.glow.setLevel(level) }
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
        sessions = readSessions()

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
        }

        menu.addItem(.separator())
        menu.addItem(disabled(L("接入的 AI 工具", "Connected agents")))
        for (i, t) in targets.enumerated() {
            let status = t.status
            if status == .absent { continue }
            let text: String
            switch status {
            case .lumen:    text = L("已接入", "connected")
            case .keyboard: text = L("已通过键盘灯接入", "connected via keyboard light")
            default:        text = L("未接入，点击接入", "not connected — click to connect")
            }
            let mi = NSMenuItem(title: "\(t.name)\(L("：", ": "))\(text)", action: #selector(toggleHooks(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = i
            mi.state = status == .off ? .off : .on
            mi.isEnabled = status != .keyboard
            menu.addItem(mi)
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

    // dragging shows that colour breathing at the new strength for a moment
    @objc private func levelChanged(_ sender: NSSlider) {
        guard let light = Light(rawValue: sender.tag), let st = style(light) else { return }
        defaults.set(sender.doubleValue, forKey: st.levelKey)
        sliderPreview = (light, Date().addingTimeInterval(1.5))
        updateGlow()
        updateAnimating()
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
        let candidates = targets.filter { $0.status == .off }
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
        guard s == .off || s == .lumen, install || s == .lumen else {
            print("\(t.name): \(s == .absent ? "not installed" : s == .keyboard ? "uses the keyboard light hooks" : "already connected")")
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
