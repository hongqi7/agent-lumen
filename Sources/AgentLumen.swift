// Agent Lumen (灵光): a menu bar light, a screen-edge glow and (optionally) NuPhy keyboard side lights
// that show what your AI coding agents are doing — Claude Code, Codex, Gemini CLI, Qoder, WorkBuddy, Devin and ZCode.
// Blue: waiting for your approval. Orange: working. Green: done.
// Each agent session reports its state through hooks (Resources/lumen-hook); this app is the only reader.
import AppKit
import CoreImage
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
// waiting for you can rightly last hours, but a prompt dismissed with Esc never reports again, so it can't stay blue for good
let attentionStaleSeconds: TimeInterval = 24 * 60 * 60
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
            // the state, then for an agent with no session end event its process
            let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            var light = Light(word: lines.first ?? "")
            if light == .idle { continue }
            if lines.count > 1, let pid = pid_t(lines[1]), kill(pid, 0) != 0, errno == ESRCH {
                try? fm.removeItem(atPath: path)
                lumenLog("session cleared, its process has gone: \(name)")
                continue
            }
            let target = targets.first { !$0.arg.isEmpty && name.hasPrefix($0.arg + "-") } ?? targets[0]
            if now.timeIntervalSince(mtime) > (light == .attention ? attentionStaleSeconds : staleSeconds) {
                // an agent that never reports a session's end can't clear its last state: let it go in time
                if !target.reportsEnd { continue }
                light = .done
            }
            out.append(Session(agent: target.name, light: light, changed: mtime))
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

// follows links, so a settings file linked into a dotfiles repo still shows its edits
func fileModified(_ path: String) -> Date? {
    var s = stat()
    guard stat(path, &s) == 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(s.st_mtimespec.tv_sec) + TimeInterval(s.st_mtimespec.tv_nsec) / 1e9)
}

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

// where command line agents usually live: an app started from Finder doesn't get the shell's PATH
let commandDirs: [String] = {
    var dirs = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", home + "/.npm-global/bin",
                home + "/.bun/bin", home + "/.volta/bin", home + "/Library/pnpm"]
    let nvm = home + "/.nvm/versions/node"
    for version in (try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? [] { dirs.append("\(nvm)/\(version)/bin") }
    return dirs
}()

// One agent we can wire up: where its settings live and which hook events map to which state.
// Event names differ: Devin drops its whole hooks object if it sees one it doesn't know.
struct AgentTarget {
    let name: String
    let configDir: String
    let settings: String
    let arg: String                          // session file prefix
    let events: [(event: String, state: String, matcher: String?)]
    var timeout = 5                          // in the unit this agent reads: seconds, milliseconds for Gemini CLI
    var nestedEvents = false                 // ZCode: { "hooks": { "enabled": true, "events": { ... } } }
    // a folder alone doesn't prove these are installed: other tools create ~/.codex and ~/.gemini too
    var commands: [String] = []
    var apps: [String] = []
    var folderMeansInstalled = true
    var needsTrust = false                   // the agent skips new hooks until the user approves them there
    var note: String? = nil

    enum Status { case absent, off, lumen, legacy, broken }

    var reportsEnd: Bool { events.contains { $0.state == "end" } }

    var installed: Bool {
        let fm = FileManager.default
        if folderMeansInstalled && fm.fileExists(atPath: configDir) { return true }
        return commands.contains { c in commandDirs.contains { fm.isExecutableFile(atPath: "\($0)/\(c)") } }
            || apps.contains { fm.fileExists(atPath: "/Applications/\($0).app") || fm.fileExists(atPath: home + "/Applications/\($0).app") }
    }

    var status: Status {
        let data = FileManager.default.contents(atPath: settings) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        guard text.contains("lumen-hook") || installed else { return .absent }   // still connected: keep it offered
        if !data.isEmpty, parseSettings(data) == nil { return .broken }
        if text.contains("lumen-hook") { return .lumen }
        if text.contains("claude-light") { return .legacy }   // the older standalone keyboard-light hooks
        return .off
    }
}

// Claude Code tools that wait for your answer inside the call, so no permission event reports it. PermissionRequest
// isn't used: nothing follows an approval until the tool ends, so a long command would stay blue while it runs.
let claudeToolsThatAsk = "^(AskUserQuestion|ExitPlanMode|mcp__computer-use__request_(access|full_control|teach_access))$"

// the order the panel lists them in
let targets = [
    AgentTarget(name: "Claude Code", configDir: home + "/.claude", settings: home + "/.claude/settings.json", arg: "",
                events: [("UserPromptSubmit", "working", nil), ("PostToolUse", "working", "*"), ("PostToolUseFailure", "working", nil),
                         ("PreToolUse", "attention", claudeToolsThatAsk),
                         ("Notification", "attention", "permission_prompt|elicitation_dialog|elicitation_url_dialog"),
                         ("Stop", "done", nil), ("SessionEnd", "end", nil)]),
    // SessionEnd and Interrupt allow 3 seconds at most. Stopping a turn is neither work nor a finished task: back to idle
    AgentTarget(name: "Codex", configDir: home + "/.codex", settings: home + "/.codex/hooks.json", arg: "codex",
                events: [("UserPromptSubmit", "working", nil), ("PostToolUse", "working", nil),
                         ("PermissionRequest", "attention", nil), ("Stop", "done", nil),
                         ("Interrupt", "end", nil), ("SessionEnd", "end", nil)],
                timeout: 3, commands: ["codex"], apps: ["Codex"], folderMeansInstalled: false, needsTrust: true,
                note: L("Codex 会跳过未经审核的钩子。在 Codex 里输入 /hooks，或打开桌面版的“设置 → Hooks”，信任后开始生效。",
                        "Codex skips hooks it hasn't reviewed. Type /hooks in Codex, or open Settings → Hooks in the desktop app, and trust them.")),
    AgentTarget(name: "Gemini CLI", configDir: home + "/.gemini", settings: home + "/.gemini/settings.json", arg: "gemini",
                events: [("BeforeAgent", "working", nil), ("AfterTool", "working", nil),
                         ("Notification", "attention", nil), ("AfterAgent", "done", nil), ("SessionEnd", "end", nil)],
                timeout: 5000, commands: ["gemini"], folderMeansInstalled: false),
    AgentTarget(name: "Qoder", configDir: home + "/.qoder", settings: home + "/.qoder/settings.json", arg: "qoder",
                events: [("UserPromptSubmit", "working", nil), ("PostToolUse", "working", nil),
                         ("PermissionRequest", "attention", nil), ("Notification", "attention", "permission_prompt"),
                         ("Stop", "done", nil), ("StopFailure", "done", nil), ("SessionEnd", "end", nil)]),
    AgentTarget(name: "WorkBuddy", configDir: home + "/.workbuddy", settings: home + "/.workbuddy/settings.json", arg: "workbuddy",
                events: [("UserPromptSubmit", "working", nil), ("PostToolUse", "working", nil),
                         ("PermissionRequest", "attention", nil), ("Notification", "attention", "permission_prompt"),
                         ("Stop", "done", nil), ("StopFailure", "done", nil), ("SessionEnd", "end", nil)]),
    AgentTarget(name: "Devin", configDir: home + "/.config/devin", settings: home + "/.config/devin/config.json", arg: "devin",
                events: [("UserPromptSubmit", "working", nil), ("PostToolUse", "working", nil),
                         ("PermissionRequest", "attention", nil), ("Stop", "done", nil), ("SessionEnd", "end", nil)],
                note: L("Devin 桌面版要退出重开，并在“信任此工作区”时选择信任。云端会话不显示状态。",
                        "Quit and reopen Devin Desktop, and trust the workspace when asked. Cloud sessions don't report.")),
    // ZCode has no session end event, and leaves hooks off until asked
    AgentTarget(name: "ZCode", configDir: home + "/.zcode", settings: home + "/.zcode/cli/config.json", arg: "zcode",
                events: [("UserPromptSubmit", "working", nil), ("PostToolUse", "working", nil), ("PostToolUseFailure", "working", nil),
                         ("PermissionRequest", "attention", nil), ("Stop", "done", nil)],
                nestedEvents: true, commands: ["zcode"], apps: ["ZCode"],
                note: L("接入时会打开 ZCode 的钩子总开关，断开时只移除 Agent Lumen 的钩子，总开关保持打开。",
                        "Connecting turns on ZCode's hooks setting. Disconnecting removes only Agent Lumen's hooks and leaves that setting on.")),
]

enum HookError: Error { case unreadable(String) }

// the file a settings path really is. A link into a dotfiles repo must stay a link: an atomic write would replace it.
// Unlike resolvingSymlinksInPath, this also follows a link whose target doesn't exist yet.
func followLinks(_ path: String) -> String {
    var p = path
    for _ in 0..<32 {
        guard let next = try? FileManager.default.destinationOfSymbolicLink(atPath: p) else { break }
        p = next.hasPrefix("/") ? next : ((p as NSString).deletingLastPathComponent as NSString).appendingPathComponent(next)
    }
    return p
}

// the same bytes with // and /* */ comments blanked out (Gemini CLI allows them), so offsets match the original
func blankComments(_ data: Data) -> [UInt8] {
    var b = [UInt8](data)
    var i = 0
    var inString = false
    while i < b.count {
        let c = b[i]
        if inString {
            if c == 0x5C { i += 1 } else if c == 0x22 { inString = false }   // \ skips the next byte
        } else if c == 0x22 {
            inString = true
        } else if c == 0x2F, i + 1 < b.count, b[i + 1] == 0x2F || b[i + 1] == 0x2A {
            let block = b[i + 1] == 0x2A
            var end = i + 2
            while end < b.count && !(block ? end > i + 2 && b[end - 1] == 0x2A && b[end] == 0x2F : b[end] == 0x0A) { end += 1 }
            if block { end = min(end + 1, b.count) }
            for j in i..<end where b[j] != 0x0A { b[j] = 0x20 }
            i = end - 1
        }
        i += 1
    }
    return b
}

func parseSettings(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(blankComments(data)))) as? [String: Any]
}

private func isJSONSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 }

// where the value of a top-level key sits in comment-free JSON
func topLevelValueRange(_ b: [UInt8], key: String) -> Range<Int>? {
    let wanted = Array("\"\(key)\"".utf8)
    var i = 0, depth = 0
    var start: Int?
    while i < b.count {
        let c = b[i]
        if c == 0x22 {
            let from = i
            i += 1
            while i < b.count && b[i] != 0x22 { i += b[i] == 0x5C ? 2 : 1 }
            if depth == 1, start == nil, i < b.count, b[from...i].elementsEqual(wanted) {
                var j = i + 1
                while j < b.count && isJSONSpace(b[j]) { j += 1 }
                if j < b.count && b[j] == 0x3A {   // a key, not a value that happens to read the same
                    j += 1
                    while j < b.count && isJSONSpace(b[j]) { j += 1 }
                    start = j
                }
            }
        } else if c == 0x7B || c == 0x5B {
            depth += 1
        } else if c == 0x7D || c == 0x5D || c == 0x2C {
            if c != 0x2C { depth -= 1 }
            if let s = start, depth == (c == 0x2C ? 1 : 0) {
                var end = i
                while end > s && isJSONSpace(b[end - 1]) { end -= 1 }
                return s..<end
            }
        }
        i += 1
    }
    return nil
}

// The new file contents. A settings file stays the user's: only the value of "hooks" is replaced, so the key order,
// formatting and comments everywhere else survive. Falls back to writing the whole file if that can't be done safely.
func renderSettings(original: Data?, root: [String: Any]) throws -> Data {
    let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let whole = try JSONSerialization.data(withJSONObject: root, options: options)
    guard let original, !original.isEmpty, let hooks = root["hooks"] else { return whole }
    let value = String(decoding: try JSONSerialization.data(withJSONObject: hooks, options: options), as: UTF8.self)
        .replacingOccurrences(of: "\n", with: "\n  ")   // one level in; a JSON string can't hold a raw line break
    let b = blankComments(original)
    var out = [UInt8](original)
    if let range = topLevelValueRange(b, key: "hooks") {
        out.replaceSubrange(range, with: Array(value.utf8))
    } else if let close = b.lastIndex(of: 0x7D), let last = b[..<close].lastIndex(where: { !isJSONSpace($0) }) {
        let lineBreak = b[(last + 1)..<close].contains(0x0A) ? "" : "\n"
        let text = (b[last] == 0x7B ? "" : ",") + "\n  \"hooks\": " + value + lineBreak
        out.insert(contentsOf: Array(text.utf8), at: last + 1)
    } else {
        return whole
    }
    guard let parsed = parseSettings(Data(out)), NSDictionary(dictionary: parsed).isEqual(to: root) else { return whole }
    return Data(out)
}

// Backups sit next to the path the agent uses, not in a dotfiles repo a link may point into. Kept: the oldest
// (the file as it was before Agent Lumen) and the newest few.
func backUpSettings(_ realFile: String, settings: String, keepNewest: Int = 4) {
    let fm = FileManager.default
    try? fm.copyItem(atPath: realFile, toPath: settings + ".bak-agent-lumen-\(Int(Date().timeIntervalSince1970))")
    let dir = (settings as NSString).deletingLastPathComponent
    let prefix = (settings as NSString).lastPathComponent + ".bak-agent-lumen-"
    let backups = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix(prefix) }.sorted()
    guard backups.count > keepNewest + 1 else { return }
    for name in backups[1..<(backups.count - keepNewest)] { try? fm.removeItem(atPath: dir + "/" + name) }
}

private func isLumenEntry(_ entry: Any) -> Bool {
    ((entry as? [String: Any])?["hooks"] as? [[String: Any]] ?? [])
        .contains { c in ["lumen-hook", "claude-light"].contains { (c["command"] as? String ?? "").contains($0) } }
}

private func hookCommand(_ t: AgentTarget, state: String) -> String {
    "\"\(hookPath)\" \(state) \(t.arg)".trimmingCharacters(in: .whitespaces)
}

// whether a connected agent's hooks differ from what this version of the app would write
func hooksOutdated(_ t: AgentTarget) -> Bool {
    guard let data = FileManager.default.contents(atPath: t.settings), let root = parseSettings(data) else { return false }
    let container = root["hooks"] as? [String: Any] ?? [:]
    let hooks = t.nestedEvents ? container["events"] as? [String: Any] ?? [:] : container
    var found: [String] = []
    for (event, value) in hooks {
        for entry in value as? [Any] ?? [] where isLumenEntry(entry) {
            let e = entry as? [String: Any] ?? [:]
            for c in e["hooks"] as? [[String: Any]] ?? [] {
                found.append("\(event)|\(e["matcher"] as? String ?? "")|\(c["command"] as? String ?? "")")
            }
        }
    }
    let wanted = t.events.map { "\($0.event)|\($0.matcher ?? "")|\(hookCommand(t, state: $0.state))" }
    return found.sorted() != wanted.sorted()
}

// Rewrites one settings file: drops earlier Lumen entries and the older keyboard-light ones (this app drives
// the keyboard now, so one set of hooks serves both), then (when installing) puts ours first in
// each event so they never wait behind a slow hook. Backs the file up and keeps its permissions.
func setHooks(_ t: AgentTarget, install: Bool) throws {
    let fm = FileManager.default
    let path = followLinks(t.settings)
    let original = fm.contents(atPath: path)
    var root: [String: Any] = [:]
    var perms: Any?
    if let data = original, !data.isEmpty {
        guard let obj = parseSettings(data) else { throw HookError.unreadable(t.settings) }
        root = obj
        perms = try? fm.attributesOfItem(atPath: path)[.posixPermissions]
        backUpSettings(path, settings: t.settings)
    }
    var container = root["hooks"] as? [String: Any] ?? [:]
    var hooks = t.nestedEvents ? container["events"] as? [String: Any] ?? [:] : container
    // only event lists: "hooks" can also hold an agent's own settings, such as "enabled"
    for event in Array(hooks.keys) {
        guard let list = hooks[event] as? [Any] else { continue }
        let kept = list.filter { !isLumenEntry($0) }
        hooks[event] = kept.isEmpty ? nil : kept
    }
    if install {
        for e in t.events {
            var entry: [String: Any] = ["hooks": [["type": "command",
                                                   "command": hookCommand(t, state: e.state),
                                                   "timeout": t.timeout]]]
            if let m = e.matcher { entry["matcher"] = m }
            hooks[e.event] = [entry] + (hooks[e.event] as? [Any] ?? [])
        }
    }
    if t.nestedEvents {
        container["events"] = hooks
        if install { container["enabled"] = true }
    } else {
        container = hooks
    }
    root["hooks"] = container
    let data = try renderSettings(original: original, root: root)
    try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    if let perms { try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: path) }
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

// When a place's green light goes dark: once you have been back at the computer for the chosen time
// since the newest done state appeared. A session finishing later brings it back.
struct DoneWatch {
    var seenThrough = Date.distantPast               // done states written up to here have been seen
    private var shown: (stamp: Date, at: Date)?      // the newest done state and when it appeared
    private var backSince: Date?                     // first input after it appeared

    // delay in seconds; below zero means it never turns off on its own
    mutating func stillOn(newest: Date?, delay: Double, idleFor: TimeInterval, now: Date = Date()) -> Bool {
        guard let newest, newest > seenThrough else {
            shown = nil
            backSince = nil
            return false
        }
        if shown?.stamp != newest {
            shown = (newest, now)
            backSince = nil
        }
        if delay < 0 { return true }
        if backSince == nil, let shown, now.addingTimeInterval(-idleFor) > shown.at { backSince = now }
        if let backSince, now.timeIntervalSince(backSince) >= delay {
            seenThrough = newest
            return false
        }
        return true
    }
}

// MARK: - menu bar icon

// A black monitor with a glowing ring inside its screen: the app icon's three colours when idle, a state's colour when
// busy. The frame and stand are a template image, so macOS tints them for a light or dark bar and the monitor never
// melts into a dark one. The screen and ring sit on top in layers, so the ring can breathe without image redraws.
// Next to white icons (a dark or coloured bar) the screen is see-through, so it darkens the bar's colour instead of
// covering it. Next to black icons (a light bar) it stays solid: there a see-through screen only looks grey.
enum MenuBarIcon {
    static let size: CGFloat = 18
    // all on the 2x pixel grid once stroked
    private static let frameWidth: CGFloat = 1
    private static let framePath = CGPath(roundedRect: CGRect(x: 1, y: 5, width: 16, height: 11), cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
    private static let screen = CGPath(roundedRect: CGRect(x: 1.5, y: 5.5, width: 15, height: 10), cornerWidth: 2, cornerHeight: 2, transform: nil)
    private static let ring = CGPath(roundedRect: CGRect(x: 3, y: 7, width: 12, height: 7), cornerWidth: 1.25, cornerHeight: 1.25, transform: nil)
    private static let ringWidth: CGFloat = 1

    static let body: NSImage = {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            c.setStrokeColor(NSColor.black.cgColor)
            c.setFillColor(NSColor.black.cgColor)
            c.addPath(framePath)
            c.setLineWidth(frameWidth)
            c.strokePath()
            c.fill(CGRect(x: 8, y: 3.5, width: 2, height: 1))
            c.addPath(CGPath(roundedRect: CGRect(x: 5, y: 2.25, width: 8, height: 1.5), cornerWidth: 0.75, cornerHeight: 0.75, transform: nil))
            c.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }()

    private static func render(_ draw: (CGContext) -> Void) -> CGImage {
        let c = CGContext(data: nil, width: Int(size * 2), height: Int(size * 2), bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.scaleBy(x: 2, y: 2)
        draw(c)
        return c.makeImage()!
    }

    static let blackScreen = render { c in
        c.addPath(screen)
        c.setFillColor(NSColor(white: 0.04, alpha: 1).cgColor)
        c.fillPath()
    }

    private static func stroked(width: CGFloat, _ paint: (CGContext) -> Void) -> CGImage {
        render { c in
            c.addPath(ring)
            c.setLineWidth(width)
            c.replacePathWithStrokedPath()
            c.clip()
            paint(c)
        }
    }

    // a wider ring blurred, kept inside the screen
    private static func blurred(_ paint: (CGContext) -> Void) -> CGImage {
        let wide = CIImage(cgImage: stroked(width: 2, paint))
        let soft = wide.clampedToExtent().applyingGaussianBlur(sigma: 2.5).cropped(to: wide.extent)
        guard let image = CIContext().createCGImage(soft, from: soft.extent) else { return wide.cgImage ?? stroked(width: 2, paint) }
        return render { c in
            c.addPath(screen)
            c.clip()
            c.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        }
    }

    private static func solid(_ color: NSColor) -> (CGContext) -> Void {
        { c in c.setFillColor(color.cgColor); c.fill(CGRect(x: 0, y: 0, width: size, height: size)) }
    }

    // blue → green → orange, as in the app icon
    private static func threeColours(_ c: CGContext) {
        let colors = [Light.attention, .done, .working].map(\.color.cgColor)
        let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray, locations: [0, 0.5, 1])!
        c.drawLinearGradient(grad, start: CGPoint(x: 3, y: 14), end: CGPoint(x: 15, y: 7), options: [])
    }

    static func ring(_ light: Light) -> CGImage { stroked(width: ringWidth, light == .idle ? threeColours : solid(light.color)) }
    static func glow(_ light: Light) -> CGImage { blurred(light == .idle ? threeColours : solid(light.color)) }
}

// Sits on the status item's button and lets its clicks through.
final class MenuBarIconView: NSView {
    private let black = CALayer()
    private let glow = CALayer()
    private let ring = CALayer()
    private var onDarkBar: Bool?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // layer before wantsLayer = a layer-hosting view: AppKit leaves our layer tree alone
        layer = CALayer()
        wantsLayer = true
        black.contents = MenuBarIcon.blackScreen
        for l in [black, glow, ring] {
            l.contentsScale = 2
            l.contentsGravity = .resize
            l.frame = CGRect(x: 0, y: 0, width: MenuBarIcon.size, height: MenuBarIcon.size)
            layer!.addSublayer(l)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // Called from the app's timer, not viewDidChangeEffectiveAppearance: when the bar changes, macOS renders the item
    // in light and dark over and over, and that callback fires dozens of times with both. The timer reads it at rest.
    func followBar() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark]).map { [.darkAqua, .vibrantDark].contains($0) } ?? false
        guard dark != onDarkBar else { return }
        onDarkBar = dark
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        black.opacity = dark ? 0.4 : 1
        CATransaction.commit()
        lumenLog("menu bar: \(dark ? "dark, screen see-through" : "light, screen solid")")
    }

    func show(_ light: Light) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.contents = MenuBarIcon.ring(light)
        glow.contents = MenuBarIcon.glow(light)
        ring.opacity = 1
        glow.opacity = 1
        CATransaction.commit()
    }

    // level: 0...1, the breath's position
    func breathe(_ level: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.opacity = Float(0.35 + 0.65 * level)
        glow.opacity = Float(level)
        CATransaction.commit()
    }
}

// MARK: - keyboard

// which keyboards to drive: those whose name contains this
var keyboardNameMatch: String { UserDefaults.standard.string(forKey: "keyboardName") ?? "NuPhy" }

// NuPhy keyboards running the claude-light firmware (github.com/hongqi7/nuphy-air60-v2-claude-light) read the
// state from two indicator bits macOS never uses: Num Lock = working, Scroll Lock = done, both = needs you.
// The bits travel over USB, Bluetooth and 2.4G alike. A reconnecting keyboard starts with them cleared,
// so they are sent again when it shows up.

// Firmware before protocol 3 doesn't understand the Compose and Kana bits, and most of it drops the whole LED report
// when it sees them, which would freeze the status lights over Bluetooth. So they go only to keyboards whose
// USB reply proved they're new enough.
let liveKeysKey = "keyboardsWithLiveKeys"
func keyboardFamily(_ name: String) -> String {   // the same keyboard as "X", "X-1" and "X Dongle"
    name.replacingOccurrences(of: #"(-\d+| Dongle)$"#, with: "", options: .regularExpression)
}
// NuPhy's 2.4G receivers forward an LED report only while it holds nothing beyond Num/Caps/Scroll Lock: one with
// the Compose or Kana bit is dropped whole, state and all (Bluetooth passes them on). So a keyboard on its receiver
// gets the plain state, and its keys and halo follow the choices it stored over USB.
func isReceiver(_ name: String) -> Bool { name.hasSuffix(" Dongle") }
func hasLiveKeys(_ name: String) -> Bool {
    !isReceiver(name) && (UserDefaults.standard.stringArray(forKey: liveKeysKey) ?? []).contains(keyboardFamily(name))
}

// what a keyboard with protocol 3 is told: the state, and the live choices for its keys and top lights
struct KeyboardLive: Equatable {
    var light = Light.idle
    var compose = false       // keys and halo ring show the state
    var kana = false          // the top left strip shows the state
    var num: Bool { light == .working || light == .attention }
    var scroll: Bool { light == .done || light == .attention }
}

final class KeyboardLight {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var opened = false
    private var bits: (num: Bool, scroll: Bool) = (false, false)
    private var live = KeyboardLive()

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
    // another app (Karabiner-Elements and other key remappers) holds a keyboard exclusively, so its LEDs can't be set
    private(set) var seized = false

    private func name(_ d: IOHIDDevice) -> String {
        IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? ""
    }

    func matches(_ d: IOHIDDevice) -> Bool { name(d).localizedCaseInsensitiveContains(keyboardNameMatch) }

    private var devices: [IOHIDDevice] {
        guard let set = IOHIDManagerCopyDevices(manager) else { return [] }
        var refs = [UnsafeRawPointer?](repeating: nil, count: CFSetGetCount(set))
        CFSetGetValues(set, &refs)
        return refs.compactMap { $0 }.map { Unmanaged<IOHIDDevice>.fromOpaque($0).takeUnretainedValue() }.filter(matches)
    }

    var names: [String] { Array(Set(devices.map(name))).sorted() }

    func show(_ light: Light, live nextLive: KeyboardLive = KeyboardLive()) {
        let next = (num: light == .working || light == .attention, scroll: light == .done || light == .attention)
        guard next != bits || nextLive != live else { return }
        bits = next
        live = nextLive
        apply()
    }

    func apply() {
        guard openIfAllowed() else {
            let problem = access == kIOHIDAccessTypeGranted
                ? "keyboard: could not open the keyboards, lights not sent"
                : "keyboard: no Input Monitoring (access \(access.rawValue)), lights not sent"
            if problem != lastProblem { lumenLog(problem) }
            lastProblem = problem
            return
        }
        var results: [String] = []
        var heldElsewhere = false
        for d in devices {
            guard let els = IOHIDDeviceCopyMatchingElements(d, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else { continue }
            let isLive = hasLiveKeys(name(d))
            for e in els where IOHIDElementGetUsagePage(e) == UInt32(kHIDPage_LEDs) {
                let on: Bool
                switch Int(IOHIDElementGetUsage(e)) {
                case kHIDUsage_LED_NumLock:    on = isLive ? live.num : bits.num
                case kHIDUsage_LED_ScrollLock: on = isLive ? live.scroll : bits.scroll
                // cleared rather than skipped: a bit left set from before would keep a receiver dropping every report
                case kHIDUsage_LED_Compose:    on = isLive && live.compose
                case kHIDUsage_LED_Kana:       on = isLive && live.kana
                default:                       continue
                }
                let r = IOHIDDeviceSetValue(d, e, IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, e, 0, on ? 1 : 0))
                if r == kIOReturnExclusiveAccess { heldElsewhere = true }
                if r != kIOReturnSuccess { results.append("\(name(d)) led \(IOHIDElementGetUsage(e)) -> 0x\(String(r, radix: 16))") }
            }
        }
        seized = heldElsewhere
        if heldElsewhere { results.append("held exclusively by another app, such as Karabiner-Elements") }
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

// The firmware's version from a raw HID reply, 0 if it's too old to know our command. nil for anything else:
// VIA or Vial running alongside share this interface, and their replies reach us as well.
func firmwareVersion(reply r: UnsafePointer<UInt8>, length: Int) -> UInt8? {
    if length >= 8 && r[0] == 0x4C && r[1] == 0x4D { return r[7] }
    if length >= 3 && r[0] == 0xFF && r[1] == 0x4D && r[2] == 0x01 { return 0 }   // VIA's "unhandled" echo of our request
    return nil
}

final class KeyboardSettings {
    enum Sync { case noCable, synced, oldFirmware, pending }

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var opened = false
    private var listeners: [(device: IOHIDDevice, buffer: UnsafeMutablePointer<UInt8>)] = []
    private var pending: [UInt8]?
    private var lastSent = Date.distantPast
    private(set) var status = Sync.noCable
    var currentPayload: (() -> [UInt8])?     // levels and flags, read fresh each time
    var liveKeysChanged: (() -> Void)?

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
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            let s = Unmanaged<KeyboardSettings>.fromOpaque(ctx!).takeUnretainedValue()
            s.stopListening(device)
            DispatchQueue.main.async { if s.devices.isEmpty { s.status = .noCable } }
        }, me)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    func start() {
        guard !opened else { return }
        opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
    }

    private func matches(_ d: IOHIDDevice) -> Bool {
        (IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? "").localizedCaseInsensitiveContains(keyboardNameMatch)
    }

    private var devices: [IOHIDDevice] {
        guard let set = IOHIDManagerCopyDevices(manager) else { return [] }
        var refs = [UnsafeRawPointer?](repeating: nil, count: CFSetGetCount(set))
        CFSetGetValues(set, &refs)
        return refs.compactMap { $0 }.map { Unmanaged<IOHIDDevice>.fromOpaque($0).takeUnretainedValue() }.filter(matches)
    }

    // replies tell us whether the firmware understood: ours echoes 'L' 'M', older firmware answers as VIA would
    private func listen(_ device: IOHIDDevice) {
        guard !listeners.contains(where: { $0.device === device }) else { return }
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        listeners.append((device, buf))
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buf, 64, { ctx, _, _, _, _, report, length in
            let s = Unmanaged<KeyboardSettings>.fromOpaque(ctx!).takeUnretainedValue()
            guard let version = firmwareVersion(reply: report, length: length) else { return }
            DispatchQueue.main.async {
                s.status = version >= 1 ? .synced : .oldFirmware
                s.note(version: version)
            }
        }, me)
    }

    // both this and the report callback run on the main run loop, so no report can be landing in the buffer
    private func stopListening(_ device: IOHIDDevice) {
        guard let i = listeners.firstIndex(where: { $0.device === device }) else { return }
        IOHIDDeviceRegisterInputReportCallback(device, listeners[i].buffer, 64, nil, nil)
        listeners[i].buffer.deallocate()
        listeners.remove(at: i)
    }

    private func note(version: UInt8) {
        let defaults = UserDefaults.standard
        let before = Set(defaults.stringArray(forKey: liveKeysKey) ?? [])
        let here = Set(devices.map { keyboardFamily(IOHIDDeviceGetProperty($0, kIOHIDProductKey as CFString) as? String ?? "") })
        let after = version >= 3 ? before.union(here) : before.subtracting(here)
        guard after != before else { return }
        defaults.set(Array(after).sorted(), forKey: liveKeysKey)
        liveKeysChanged?()
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

struct DisplayRow: Identifiable, Equatable {
    let id: String
    let name: String
    let builtIn: Bool
    let on: Bool
}

struct AgentRow: Identifiable, Equatable {
    let id: Int
    let name: String
    let status: AgentTarget.Status
    let waitingForTrust: Bool
    let failed: Bool
    let note: String?
}

enum PanelAction { case dismissDone, dismissKeyboardDone, fitToContent, toggleAgent(Int), showAgents(Bool), toggleAbsentAgents, toggleDisplay(String), askKeyboardAccess, toggleLogin, quit }

// what the panel shows; the app delegate fills it in and carries out the actions
final class PanelModel: ObservableObject {
    @Published var isOpen = false
    @Published var doneOnScreen = false
    @Published var doneOnKeyboard = false
    @Published var keyboardName: String?
    @Published var keyboardSync = KeyboardSettings.Sync.noCable
    @Published var keyboardNeedsAccess = false
    @Published var keyboardSeized = false   // another app holds it exclusively
    @Published var keyboardLiveKeys = false   // its key lights can be switched over wireless
    @Published var agents: [AgentRow] = []
    @Published var onAgentsPage = false
    @Published var absentAgentsOpen = false
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

// a colour for light mode and one for dark mode; the panel follows the system unless the user picks one
private func dyn(_ light: UInt32, _ la: CGFloat = 1, _ dark: UInt32, _ da: CGFloat = 1) -> Color {
    func c(_ hex: UInt32, _ a: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
    }
    return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? c(dark, da) : c(light, la) })
}

// the panel's palette: light grey and white cards in light mode, near-black in dark mode
enum Ink {
    static let text = dyn(0x1D1D1F, 1, 0xF2EEE9, 1)
    static let muted = dyn(0x1D1D1F, 0.58, 0xF2EEE9, 0.55)
    static let faint = dyn(0x1D1D1F, 0.38, 0xF2EEE9, 0.35)
    static let card = dyn(0x000000, 0.04, 0xFFFFFF, 0.05)
    static let cardOn = dyn(0xFFFFFF, 1, 0xFFFFFF, 0.12)
    static let line = dyn(0x000000, 0.08, 0xFFFFFF, 0.08)
    static let list = dyn(0xFFFFFF, 1, 0xFFFFFF, 0.04)
    static let shadow = dyn(0x000000, 0.06, 0x000000, 0)
    static let back = dyn(0xF6F6F8, 1, 0x1D1C1F, 1)
    static let rim = dyn(0xC7C7CC, 1, 0x3A383D, 1)
    // the preview
    static let stageTop = dyn(0xECECF0, 1, 0x2A282C, 1)
    static let stageBottom = dyn(0xDCDCE2, 1, 0x161518, 1)
    static let screen = dyn(0x1C1C1E, 1, 0x0E0E10, 1)
    static let window = dyn(0xF2F2F5, 1, 0x1F1E22, 1)
    static let windowLine = dyn(0xD8D8DE, 1, 0x2E2C31, 1)
    static let keyboard = dyn(0xE4E4E9, 1, 0x2A282D, 1)
    static let key = dyn(0xC9C9CF, 1, 0x45434A, 1)
    // agent status lines
    static let warn = dyn(0xB26A00, 1, 0xF0B45A, 1)
    static let bad = dyn(0xC93A32, 1, 0xFF7B72, 1)
}

struct PanelView: View {
    @ObservedObject var model: PanelModel
    let styles: [GlowStyle]
    let delays: [(seconds: Double, title: String)]

    var body: some View {
        ScrollView(.vertical) { PanelContent(model: model, styles: styles, delays: delays) }
            .frame(width: panelWidth, height: model.height)
            .background(Ink.back)
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
    let liveKeyboard: Bool     // new firmware: the top lights and the keys with the ring are switched apart
    let animating: Bool        // a closed popover keeps its view: left running, the timeline costs a quarter of a core

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !animating)) { _ in
            let t = CACurrentMediaTime()   // the clock the screen glow and menu bar icon use, so all three breathe together
            let a = level * (0.35 + 0.65 * Double(wave(t, style.period)))
            let color = Color(nsColor: style.light.color)
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(RadialGradient(colors: [Ink.stageTop, Ink.stageBottom],
                                         center: .init(x: 0.5, y: 0.3), startRadius: 0, endRadius: 200))
                VStack(spacing: 0) {
                    // screen
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(Ink.screen)
                        RoundedRectangle(cornerRadius: 4).fill(Ink.window)
                            .padding(.horizontal, 16).padding(.vertical, 14)
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(0..<3) { i in
                                Capsule().fill(Ink.windowLine).frame(width: i == 2 ? 60 : 90, height: 5)
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
                    RoundedRectangle(cornerRadius: 3).fill(Ink.rim).frame(width: 40, height: 10)
                    // keyboard
                    if liveKeyboard { liveKeyboardView(color: color, a: a) } else { sideLightsKeyboardView(color: color, a: a) }
                }
            }
        }
        .frame(height: 178)
    }

    private func keyRows(_ lit: Bool, _ color: Color, _ a: Double) -> some View {
        VStack(spacing: 2) {
            ForEach(0..<3) { _ in
                HStack(spacing: 3) {
                    ForEach(0..<11) { _ in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(lit ? color.opacity(0.25 + 0.75 * a) : Ink.key)
                            .frame(width: 9, height: 3)
                    }
                }
            }
        }
    }

    // the keys and the ring around them
    private func liveKeyboardView(color: Color, a: Double) -> some View {
        keyRows(wholeKeyboard, color, a)
            .padding(3)
            .overlay(RoundedRectangle(cornerRadius: 3)
                .strokeBorder(wholeKeyboard ? color.opacity(0.3 + 0.7 * a) : Ink.rim, lineWidth: 1))
            .shadow(color: wholeKeyboard ? color.opacity(a) : .clear, radius: 4)
            .padding(5)
            .frame(width: 150)
            .background(RoundedRectangle(cornerRadius: 5).fill(Ink.keyboard))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Ink.rim, lineWidth: 1))
            .padding(.top, 10)
    }

    private func sideLightsKeyboardView(color: Color, a: Double) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(Ink.keyboard)
            keyRows(onKeyboard && wholeKeyboard, color, a)
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

// lays its children out left to right, wrapping to a new line when the row is full
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1] = (last.items + [i], last.width + spacing + size.width, max(last.height, size.height))
            } else {
                rows.append(([i], size.width, size.height))
            }
        }
        return rows
    }
}

struct PanelContent: View {
    @ObservedObject var model: PanelModel
    let styles: [GlowStyle]
    let delays: [(seconds: Double, title: String)]

    private var st: GlowStyle { styles.first { $0.light == model.selected } ?? styles[0] }
    // every control takes the colour of the state being edited
    private var accent: Color { Color(nsColor: st.light.color) }
    private func isOn(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.onAgentsPage {
                agentsPage
            } else {
                LightPreview(style: st, level: UserDefaults.standard.double(forKey: st.levelKey),
                             onScreen: isOn(st.onKey), onKeyboard: isOn(st.keyboardKey), wholeKeyboard: isOn("keyboardKeysBreathe"),
                             liveKeyboard: model.keyboardLiveKeys, animating: model.isOpen)
                tabs.padding(.top, 12)
                Text(st.help.replacingOccurrences(of: "\n", with: chinese ? "" : " "))
                    .font(.system(size: 12)).foregroundColor(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10).padding(.horizontal, 2)
                HStack(spacing: 8) {
                    tile(L("屏幕边缘", "Screen"), "display", st.onKey)
                    tile(L("键盘呼吸灯", "Top lights"), "keyboard", st.keyboardKey)
                    // new firmware: the keys and the ring, dark when off. Older firmware: the keys only, lit along
                    // with the side lights, and off leaves the keyboard's own key effect showing
                    tile(L("按键背光", "Key lights"), "square.grid.3x2", "keyboardKeysBreathe",
                         needs: model.keyboardLiveKeys || isOn(st.keyboardKey) ? nil : L("需开呼吸灯", "Top lights off"),
                         off: model.keyboardLiveKeys ? nil : L("不变色", "Own effect"))
                }
                .padding(.top, 10)
                brightness.padding(.top, 12)
                if st.light == .done { doneDelays.padding(.top, 10) }
                list.padding(.top, 14)
            }
        }
        .padding(16)
        .foregroundColor(Ink.text)
        .font(.system(size: 13))
        .tint(accent)
        .frame(width: panelWidth)
    }

    private var tabs: some View {
        HStack(spacing: 6) {
            ForEach(styles, id: \.onKey) { s in
                let sel = s.light == model.selected
                Button { model.selected = s.light; model.perform(.fitToContent) } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Color(nsColor: s.light.color)).frame(width: 8, height: 8)
                        Text(s.light.label).font(.system(size: 12))
                    }
                    .foregroundColor(sel ? Ink.text : Ink.muted)
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9).fill(sel ? Ink.cardOn : Ink.card))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(sel ? Color(nsColor: s.light.color).opacity(0.7) : .clear, lineWidth: 1))
                    .shadow(color: sel ? Ink.shadow : .clear, radius: 1, y: 0.5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // `needs`: why this switch can't take effect right now
    private func tile(_ title: String, _ symbol: String, _ key: String, needs: String? = nil, off: String? = nil) -> some View {
        let on = needs == nil && isOn(key)
        return Button { model.bool(key).wrappedValue.toggle() } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 16)).foregroundColor(on ? accent : Ink.muted)
                    .frame(height: 20)   // symbols differ in height; keep the titles on one line
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1).padding(.top, 2)
                Text(needs ?? (on ? L("发光", "On") : off ?? L("不发光", "Off"))).font(.system(size: 11)).lineLimit(1)
                    .foregroundColor(on ? Ink.text.opacity(0.75) : Ink.faint)
            }
            .foregroundColor(on ? Ink.text : Ink.muted)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(on ? Ink.cardOn : Ink.card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? accent.opacity(0.6) : Ink.line, lineWidth: on ? 1 : 0.5))
            .shadow(color: on ? Ink.shadow : .clear, radius: 1, y: 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(needs != nil)
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
                .controlSize(.small)
        }
    }

    private var doneDelays: some View {
        VStack(alignment: .leading, spacing: 10) {
            doneDelay(L("屏幕绿光自动关闭", "Turn off screen glow"),
                      info: L("你离开电脑期间，绿光保持显示。你回到电脑前、操作鼠标或键盘后，按所选时间关闭。\n仅作用于屏幕。菜单栏图标保持绿色，直到下一项任务开始。",
                              "While you are away the glow stays on. Once you use the mouse or keyboard again, it turns off after the chosen time.\nScreen only: the menu bar icon stays green until the next task starts."),
                      key: "doneScreenDelay", isOn: model.doneOnScreen, turnOff: .dismissDone)
            doneDelay(L("键盘绿光自动关闭", "Turn off keyboard light"),
                      info: L("你离开电脑期间，键盘绿光保持显示。你回到电脑前、操作鼠标或键盘后，按所选时间关闭。\n关闭后，键盘恢复未执行任务时的灯效。菜单栏图标保持绿色，直到下一项任务开始。",
                              "While you are away the keyboard stays green. Once you use the mouse or keyboard again, it turns off after the chosen time.\nThe keyboard then goes back to its look between tasks. The menu bar icon stays green until the next task starts."),
                      key: "doneKeyboardDelay", isOn: model.doneOnKeyboard, turnOff: .dismissKeyboardDone)
        }
    }

    private func doneDelay(_ title: String, info: String, key: String, isOn: Bool, turnOff: PanelAction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12)).foregroundColor(Ink.muted)
                InfoButton(text: info)
                Spacer(minLength: 6)
                // only while the green light is on
                if isOn {
                    Button(L("立即关闭", "Turn off now")) { model.perform(turnOff) }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundColor(accent)
                }
            }
            HStack(spacing: 6) {
                ForEach(delays, id: \.seconds) { d in
                    let sel = model.double(key).wrappedValue == d.seconds
                    Button { model.double(key).wrappedValue = d.seconds } label: {
                        Text(d.title).font(.system(size: 11, weight: sel ? .medium : .regular))
                            .foregroundColor(sel ? .white : Ink.muted)
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 8).fill(sel ? accent : Ink.card))
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
                if let detail { Text(detail).font(.system(size: 11)).foregroundColor(Ink.faint).lineLimit(1) }
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
        case .noCable:
            return model.keyboardLiveKeys ? L("无线连接 · 亮度插 USB 后写入", "wireless · brightness saves over USB")
                                          : L("无线连接 · 亮度和按键背光插 USB 后写入", "wireless · settings save over USB")
        }
    }

    private var connectedAgents: [AgentRow] { model.agents.filter { $0.status == .lumen } }

    private var agentsCount: String { L("\(connectedAgents.count) 个", "\(connectedAgents.count)") }

    private var appearancePicker: some View {
        let current = UserDefaults.standard.string(forKey: "appearance") ?? "system"
        return HStack(spacing: 2) {
            ForEach([("system", L("跟随系统", "System")), ("light", L("浅色", "Light")), ("dark", L("深色", "Dark"))], id: \.0) { key, title in
                let selected = current == key
                Button {
                    model.objectWillChange.send()
                    UserDefaults.standard.set(key, forKey: "appearance")
                    model.changed("appearance")
                } label: {
                    Text(title).font(.system(size: 12))
                        .foregroundColor(selected ? Ink.text : Ink.muted)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Ink.cardOn : .clear)
                            .shadow(color: selected ? Ink.shadow : .clear, radius: 1, y: 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Ink.card))
    }

    private func displayChip(_ d: DisplayRow) -> some View {
        Button { model.perform(.toggleDisplay(d.id)) } label: {
            Label(d.name, systemImage: d.builtIn ? "laptopcomputer" : "display")
                .font(.system(size: 12))
                .foregroundColor(d.on ? .white : Ink.muted)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8).fill(d.on ? accent : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(d.on ? Color.clear : Ink.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var list: some View {
        VStack(spacing: 0) {
            if model.displays.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    row("display", L("发光的显示器", "Displays that glow"),
                        info: L("选择在哪些显示器上显示屏幕边缘发光，对三种状态统一生效。\n未选的显示器不发光。拔掉再接上、重启电脑后，设置保持不变。",
                                "Choose which displays show the edge glow, for all three states.\nThe choice survives unplugging and restarts.")) { EmptyView() }
                        .padding(.bottom, -8)
                    FlowRow(spacing: 6) {
                        ForEach(model.displays) { d in displayChip(d) }
                    }
                    .padding(.leading, 40).padding(.trailing, 12).padding(.bottom, 10)
                }
                Divider().overlay(Ink.line)
            }
            if let name = model.keyboardName {
                row("keyboard", name, keyboardStatus,
                    info: model.keyboardLiveKeys
                        ? L("亮度需在 USB 有线连接时写入键盘，写入后改用蓝牙或 2.4G 连接仍然有效。键盘呼吸灯和按键背光在无线连接时也可立即切换。",
                            "Brightness is saved to the keyboard over USB and stays in effect over Bluetooth or 2.4G. Top lights and key lights switch right away over wireless too.")
                        : L("亮度与按键背光需在 USB 有线连接时写入键盘，写入后改用蓝牙或 2.4G 连接仍然有效。",
                            "Brightness and key lights are saved to the keyboard over USB, and stay in effect over Bluetooth or 2.4G.")) { EmptyView() }
                if model.keyboardNeedsAccess {
                    row("exclamationmark.triangle.fill", L("需要「输入监控」权限", "Needs Input Monitoring"),
                        info: L("macOS 要求此权限才能设置键盘指示灯。Agent Lumen 仅设置指示灯，不读取按键内容。",
                                "macOS requires it to set keyboard LEDs. Agent Lumen only sets the LEDs and never reads keys.")) {
                        Button(L("去开启", "Allow")) { model.perform(.askKeyboardAccess) }.controlSize(.small)
                    }
                }
                if model.keyboardSeized {
                    row("exclamationmark.triangle.fill", L("键盘被其他程序独占", "Held by another app"),
                        info: L("Karabiner-Elements 等改键工具会独占它所处理的键盘，Agent Lumen 就无法设置指示灯。在 Karabiner 的 Devices 里关掉这把键盘的 Modify events 即可。插线时它可能列出两项，都要关；不用改键的话，其他设置保持不变即可。",
                                "Key remappers such as Karabiner-Elements take the keyboards they handle for themselves, so Agent Lumen can't set the LEDs. Turn off Modify events for this keyboard under Devices in Karabiner. Over USB it may be listed twice: turn off both.")) { EmptyView() }
                }
            } else {
                row("keyboard", L("未连接 NuPhy 键盘", "No NuPhy keyboard"),
                    info: L("支持刷入本项目固件的 NuPhy Air60 V2、Halo65 V2。连接到这台 Mac 后在此显示。",
                            "NuPhy Air60 V2 and Halo65 V2 with this project's firmware show up here once connected.")) { EmptyView() }
            }
            Divider().overlay(Ink.line)
            Button { model.perform(.showAgents(true)) } label: {
                row("link", L("AI 助手", "AI agents"),
                    connectedAgents.isEmpty ? L("未接入", "None connected") : connectedAgents.map(\.name).joined(separator: L("、", ", "))) {
                    HStack(spacing: 4) {
                        Text(agentsCount).font(.system(size: 12)).foregroundColor(Ink.muted)
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundColor(Ink.faint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider().overlay(Ink.line)
            row("circle.lefthalf.filled", L("外观", "Appearance")) { appearancePicker }
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
        .background(RoundedRectangle(cornerRadius: 12).fill(Ink.list))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.line, lineWidth: 0.5))
        .shadow(color: Ink.shadow, radius: 1, y: 0.5)
    }

    // MARK: agents page

    private var agentsPage: some View {
        let present = model.agents.filter { $0.status != .absent }
        let absent = model.agents.filter { $0.status == .absent }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button { model.perform(.showAgents(false)) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .medium)).foregroundColor(accent)
                        .frame(width: 22, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("返回", "Back"))
                Text(L("AI 助手", "AI agents")).font(.system(size: 14, weight: .semibold))
                InfoButton(text: L("打开开关后，Agent Lumen 会在该工具的设置文件里加入钩子，用来获取执行状态。修改前自动备份原文件，关闭开关即移除。只记录状态，不保存对话内容。\n已打开的会话需重新打开后生效。",
                                   "Switching on adds hooks to that agent's settings file so Agent Lumen can tell its state. The file is backed up first, and switching off removes them. Only the state is recorded, never your conversation.\nSessions already open need reopening."))
                Spacer()
                Text(L("已接入 \(connectedAgents.count) 个", "\(connectedAgents.count) connected")).font(.system(size: 12)).foregroundColor(Ink.muted)
            }
            if !present.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(present.enumerated()), id: \.element.id) { i, a in
                        if i > 0 { Divider().overlay(Ink.line) }
                        agentRow(a)
                    }
                }
                .modifier(ListCard())
            }
            if !absent.isEmpty {
                VStack(spacing: 0) {
                    Button { model.perform(.toggleAbsentAgents) } label: {
                        HStack {
                            Text(L("未安装 \(absent.count) 个", "\(absent.count) not installed")).font(.system(size: 12)).foregroundColor(Ink.muted)
                            Spacer()
                            Image(systemName: model.absentAgentsOpen ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold)).foregroundColor(Ink.faint)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if model.absentAgentsOpen {
                        ForEach(absent) { a in
                            Divider().overlay(Ink.line)
                            HStack(spacing: 10) {
                                agentBadge(a.name, on: false)
                                Text(a.name).foregroundColor(Ink.muted)
                                Spacer(minLength: 6)
                                Text(L("安装后可接入", "Connect once installed")).font(.system(size: 11)).foregroundColor(Ink.faint)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                        }
                    }
                }
                .modifier(ListCard())
            }
        }
    }

    private func agentBadge(_ name: String, on: Bool) -> some View {
        Text(String(name.prefix(1)))
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(on ? accent : Ink.muted)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(on ? accent.opacity(0.14) : Ink.card))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(on ? accent.opacity(0.35) : Ink.line, lineWidth: 0.5))
    }

    private func agentStatus(_ a: AgentRow) -> (text: String, color: Color) {
        if a.failed { return (L("写入失败，未作修改", "Couldn't save; nothing changed"), Ink.bad) }
        switch a.status {
        case .broken: return (L("设置文件格式有误，未作修改", "Settings file is invalid; not changed"), Ink.bad)
        case .legacy: return (L("检测到旧版钩子", "Older hooks found"), Ink.warn)
        case .lumen:
            return a.waitingForTrust ? (L("还需在 \(a.name) 中信任一次", "Trust the hooks once in \(a.name)"), Ink.warn)
                                     : (L("已接入", "Connected"), Ink.muted)
        default: return (L("未接入", "Not connected"), Ink.faint)
        }
    }

    private func agentRow(_ a: AgentRow) -> some View {
        let status = agentStatus(a)
        return HStack(spacing: 10) {
            agentBadge(a.name, on: a.status == .lumen)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(a.name)
                    if let note = a.note { InfoButton(text: note) }
                }
                Text(status.text).font(.system(size: 11)).foregroundColor(status.color)
            }
            Spacer(minLength: 6)
            if a.status == .legacy {
                Button(L("更新", "Update")) { model.perform(.toggleAgent(a.id)) }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundColor(accent)
            } else {
                Toggle("", isOn: Binding(get: { a.status == .lumen }, set: { _ in model.perform(.toggleAgent(a.id)) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .disabled(a.status == .broken)
                    .accessibilityLabel(a.name)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

// the white rounded card that groups settings rows
struct ListCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 12).fill(Ink.list))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.line, lineWidth: 0.5))
            .shadow(color: Ink.shadow, radius: 1, y: 0.5)
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let iconView = MenuBarIconView()
    private var windows: [GlowWindow] = []
    private var sessions: [Session] = []
    private var state = Light.idle
    private var shownState: Light?
    private var glow: Light?            // the colour currently breathing on the screen edges
    private var fadeStart: CFTimeInterval?   // the screen glow is fading out
    private var keyboardState: Light?   // what the keyboard was last told
    private var keyboardLive = KeyboardLive()
    // green on the screen and on the keyboard each go dark on their own timer; the menu bar keeps it
    private var screenDone = DoneWatch()
    private var keyboardDone = DoneWatch()
    private var sliderPreview: (light: Light, until: Date)?
    private var animTimer: Timer?
    private let defaults = UserDefaults.standard
    private let keyboard = KeyboardLight()
    private let keyboardSettings = KeyboardSettings()
    private let popover = NSPopover()
    private let panel = PanelModel()
    private var failedAgents = Set<Int>()   // indexes into targets whose last switch couldn't be saved
    private var statusCache: (stamps: [Date?], at: Date, statuses: [AgentTarget.Status])?
    private var terminateSignal: DispatchSourceSignal?

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
                                      "keyboardAttention": true, "keyboardDone": true, "keyboardWorking": true, "doneScreenDelay": 8.0, "doneKeyboardDelay": -1.0,
                                      "levelAttention": 1.0, "levelDone": 0.35, "levelWorking": 0.35])
        // the old menu had one switch for the whole keyboard; it is now a switch per state
        if defaults.object(forKey: "keyboardSync") as? Bool == false {
            styles.forEach { defaults.set(false, forKey: $0.keyboardKey) }
            defaults.removeObject(forKey: "keyboardSync")
        }
        // pkill and launchd send SIGTERM: quit properly, so the keyboard gets its lights back
        signal(SIGTERM, SIG_IGN)
        terminateSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminateSignal?.setEventHandler { NSApp.terminate(nil) }
        terminateSignal?.resume()
        panel.changed = { [weak self] key in self?.settingChanged(key) }
        panel.perform = { [weak self] action in self?.perform(action) }
        popover.behavior = .transient
        popover.delegate = self
        // opens, closes and resizes at once, like other menu bar apps (an animated resize also stalls the main thread)
        popover.animates = false
        applyAppearance()
        popover.contentViewController = NSHostingController(rootView: PanelView(model: panel, styles: styles, delays: doneDelays))
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        buildWindows()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.buildWindows() }
        setUpIcon()
        keyboardSettings.liveKeysChanged = { [weak self] in self?.keyboard.apply(); self?.refreshPanel() }
        keyboardSettings.currentPayload = { [weak self] in self?.keyboardPayload() ?? [] }
        keyboardSettings.start()
        refreshLoginItem()
        try? installHookScript()   // keep the installed hook in step with this version of the app
        // and the hooks of connected agents, so an update's new ones reach people who connected earlier
        for t in targets where t.status == .lumen && hooksOutdated(t) {
            do {
                try setHooks(t, install: true)
                lumenLog("\(t.name): hooks updated")
            } catch {
                lumenLog("\(t.name): hooks not updated, \(error)")
            }
        }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.togglePanel()
                if ProcessInfo.processInfo.environment["AGENT_LUMEN_OPEN_PANEL"] == "agents" { self?.perform(.showAgents(true)) }
            }
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
        keyboard.show(.idle)   // hand the lights back to the keyboard's own effects
        lumenLog("quit: keyboard lights handed back")
    }

    // Reading and parsing every agent's settings is too much for a twice-a-second timer. They're read again when
    // a file changes, and every 30 s because installing an agent touches no settings file.
    private func agentStatuses() -> [AgentTarget.Status] {
        let stamps = targets.map { fileModified($0.settings) }
        if let c = statusCache, c.stamps == stamps, Date().timeIntervalSince(c.at) < 30 { return c.statuses }
        let statuses = targets.map(\.status)
        statusCache = (stamps, Date(), statuses)
        return statuses
    }

    private var legacyHooksInUse: Bool { agentStatuses().contains(.legacy) }

    // the most urgent state among those switched on for a place (screen or keyboard)
    private func strongest(_ allowed: (GlowStyle) -> Bool) -> Light? {
        sessions.map(\.light).filter { l in style(l).map(allowed) ?? false }.max()
    }

    private func syncKeyboard(force: Bool = false) {
        let doneOn = doneOnKeyboard()
        let want = strongest { self.defaults.bool(forKey: $0.keyboardKey) && ($0.light != .done || doneOn) } ?? .idle
        var live = KeyboardLive(light: want, compose: false, kana: true)   // keys and ring dark
        if defaults.bool(forKey: "keyboardKeysBreathe") {
            // they show the most urgent state even when its top lights are off
            let top = strongest { $0.light != .done || doneOn } ?? .idle
            live = KeyboardLive(light: top, compose: true, kana: style(top).map { defaults.bool(forKey: $0.keyboardKey) } ?? true)
        }
        guard force || want != keyboardState || live != keyboardLive else { return }
        keyboardState = want
        keyboardLive = live
        if want != .idle, !keyboard.names.isEmpty, keyboard.access == kIOHIDAccessTypeUnknown, !defaults.bool(forKey: "askedKeyboardAccess") {
            defaults.set(true, forKey: "askedKeyboardAccess")
            keyboard.requestAccess()
        }
        keyboard.show(want, live: live)
        if force { keyboard.apply() }
    }

    private var newestDone: Date? { sessions.filter { $0.light == .done }.map(\.changed).max() }

    private func doneOnScreen() -> Bool {
        let before = screenDone.seenThrough
        let on = screenDone.stillOn(newest: newestDone, delay: defaults.double(forKey: "doneScreenDelay"), idleFor: secondsSinceInput())
        if screenDone.seenThrough != before { lumenLog("screen: done seen, green glow off") }
        return on
    }

    private func doneOnKeyboard() -> Bool {
        let before = keyboardDone.seenThrough
        let on = keyboardDone.stillOn(newest: newestDone, delay: defaults.double(forKey: "doneKeyboardDelay"), idleFor: secondsSinceInput())
        if keyboardDone.seenThrough != before { lumenLog("keyboard: done seen, green light off") }
        return on
    }

    private func buildWindows() {
        windows.forEach { $0.orderOut(nil) }
        let off = glowOffDisplays
        windows = Display.all.filter { !off.contains($0.id) }.map { GlowWindow(screen: $0.screen) }
        glow = nil
    }

    private func setUpIcon() {
        guard let button = item.button else { return }
        button.image = MenuBarIcon.body
        iconView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(iconView)
        NSLayoutConstraint.activate([iconView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                                     iconView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                                     iconView.widthAnchor.constraint(equalToConstant: MenuBarIcon.size),
                                     iconView.heightAnchor.constraint(equalToConstant: MenuBarIcon.size)])
    }

    private func tick() {
        iconView.followBar()
        sessions = readSessions(includeLegacy: legacyHooksInUse)
        // the first report from an agent proves the user has approved its hooks there
        for t in targets where t.needsTrust && sessions.contains(where: { $0.agent == t.name }) {
            defaults.set(true, forKey: "hooksReported.\(t.arg)")
        }
        state = sessions.map(\.light).max() ?? .idle
        if state != shownState {
            shownState = state
            iconView.show(state)
        }
        syncKeyboard()
        updateGlow()
        updateAnimating()
        if popover.isShown { refreshPanel() }
    }

    private func updateGlow() {
        var want: Light?
        if let p = sliderPreview, Date() >= p.until { sliderPreview = nil }
        if let p = sliderPreview {
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

    // fast frames only while something moves: 30 fps for the screen glow, 10 fps for the menu bar icon
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
            iconView.show(state)   // settle the icon
        }
    }

    // Core Animation's own animations never draw in the background glow window, so the app drives every frame
    private func animate() {
        let t = CACurrentMediaTime()
        if let st = style(state) { iconView.breathe(wave(t, st.period)) }
        guard let glow, let st = style(glow) else { return }
        let top = CGFloat(defaults.double(forKey: st.levelKey))
        var level = top * (0.35 + 0.65 * wave(t, st.period))
        if let f = fadeStart { level *= CGFloat(max(0, 1 - (t - f) / fadeSeconds)) }
        windows.forEach { $0.glow.setLevel(level) }
        if let f = fadeStart, t - f >= fadeSeconds { updateGlow() }
    }

    // MARK: panel

    @objc private func togglePanel() {
        if popover.isShown { return popover.performClose(nil) }
        guard let button = item.button else { return }
        statusCache = nil
        tick()
        refreshPanel()
        panel.selected = state == .idle ? .working : state   // open on what is lit now
        panel.onAgentsPage = false
        panel.absentAgentsOpen = false
        panel.isOpen = true
        fitPanel()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        // the ⓘ popovers inside the panel have their own delegates, so this is only ever the panel
        panel.isOpen = false
    }

    // as tall as the content, but never taller than the screen; beyond that the panel scrolls
    private func fitPanel() {
        let natural = NSHostingView(rootView: PanelContent(model: panel, styles: styles, delays: doneDelays)).fittingSize.height
        let room = (item.button?.window?.screen ?? NSScreen.main).map { $0.visibleFrame.height - 24 } ?? natural
        panel.height = min(natural, room)
        popover.contentSize = NSSize(width: panelWidth, height: panel.height)
    }

    // @Published announces every assignment, even of the same value, and each announcement redraws the whole panel
    private func show<T: Equatable>(_ key: ReferenceWritableKeyPath<PanelModel, T>, _ value: T) {
        if panel[keyPath: key] != value { panel[keyPath: key] = value }
    }

    private func refreshPanel() {
        show(\.doneOnScreen, glow == .done && fadeStart == nil && sliderPreview == nil)
        show(\.doneOnKeyboard, keyboardLive.light == .done && !keyboard.names.isEmpty)
        // macOS numbers keyboards with the same name ("NuPhy Air60 V2-1"); the number means nothing to people
        show(\.keyboardName, keyboard.names.first.map { $0.replacingOccurrences(of: #"-\d+$"#, with: "", options: .regularExpression) })
        show(\.keyboardSync, keyboardSettings.status)
        show(\.keyboardLiveKeys, keyboard.names.first.map(hasLiveKeys) ?? false)
        show(\.keyboardNeedsAccess, !keyboard.names.isEmpty && keyboard.access != kIOHIDAccessTypeGranted)
        show(\.keyboardSeized, !keyboard.names.isEmpty && keyboard.seized)
        let statuses = agentStatuses()
        show(\.agents, targets.enumerated().map { i, t in
            let waiting = t.needsTrust && statuses[i] == .lumen && !defaults.bool(forKey: "hooksReported.\(t.arg)")
            return AgentRow(id: i, name: t.name, status: statuses[i], waitingForTrust: waiting, failed: failedAgents.contains(i),
                            note: t.needsTrust && !waiting ? nil : t.note)   // a trust reminder only while it applies
        })
        show(\.openAtLogin, FileManager.default.fileExists(atPath: loginAgentPath))
        let off = glowOffDisplays
        show(\.displays, Display.all.map { DisplayRow(id: $0.id, name: $0.name, builtIn: $0.builtIn, on: !off.contains($0.id)) })
    }

    // nil follows the system's light or dark appearance
    private func applyAppearance() {
        switch UserDefaults.standard.string(forKey: "appearance") {
        case "light": popover.appearance = NSAppearance(named: .aqua)
        case "dark":  popover.appearance = NSAppearance(named: .darkAqua)
        default:      popover.appearance = nil
        }
    }

    private func settingChanged(_ key: String) {
        if key == "appearance" { return applyAppearance() }
        if let st = styles.first(where: { $0.levelKey == key }) {
            // dragging shows that colour breathing at the new strength for a moment
            sliderPreview = (st.light, Date().addingTimeInterval(1.5))
            updateGlow()
            updateAnimating()
            keyboardSettings.send()
        } else if key == "keyboardKeysBreathe" {
            keyboardSettings.send(force: true)
            syncKeyboard(force: true)
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
            if let newest = newestDone { screenDone.seenThrough = newest }
            tick()
        case .dismissKeyboardDone:
            if let newest = newestDone { keyboardDone.seenThrough = newest }
            tick()
        case .fitToContent:
            fitPanel()
        case .toggleAgent(let i):
            let t = targets[i]
            let install = t.status != .lumen
            do {
                try installHookScript()
                try setHooks(t, install: install)
                failedAgents.remove(i)
                if install { defaults.removeObject(forKey: "hooksReported.\(t.arg)") }
            } catch {
                failedAgents.insert(i)
                lumenLog("\(t.name): \(error)")
            }
            statusCache = nil
            refreshPanel()
        case .showAgents(let open):
            panel.onAgentsPage = open
            refreshPanel()
            fitPanel()
        case .toggleAbsentAgents:
            panel.absentAgentsOpen.toggle()
            fitPanel()
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
            + L("\n\n修改前会自动备份原文件；以后可以在设置面板的“AI 助手”里随时断开。",
                "\n\nEach file is backed up first; you can disconnect any time under AI agents in the settings panel.")
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
