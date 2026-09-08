// AgentMeter — a menu-bar app showing how much of your Claude and Codex rate
// limits you have burned, and when each window resets.
//
// Codex is read entirely from files Codex itself writes, so it costs nothing.
// Claude's local cache is refreshed on its own schedule and is often days
// behind, so the Claude figures come from the same account endpoint the Claude
// Code client calls, using the token already in your login Keychain. That
// endpoint reports numbers rather than generating text: no model runs, so no
// tokens are consumed by looking.

import AppKit
import ServiceManagement

// MARK: - Formatting

/// "seven_day_opus" -> "Seven Day Opus". Used for limits we have no nicer name
/// for, so a plan returning an unfamiliar window still renders sensibly.
func titleCase(_ raw: String) -> String {
    raw.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
        .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
        .joined(separator: " ")
}

private let clock: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
}()
private let dayClock: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "EEE HH:mm"; return f
}()
private let pastStamp: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "d MMM, HH:mm"; return f
}()

/// One reset grammar for both providers:
///   "Resets 14:30 · In 53m"          reset is later today
///   "Resets Tue 09:00 · In 2d 4h"    reset is further out
///   "Reset 3 Sep, 12:39 · Elapsed"   the time has already passed
func resetLine(_ at: Date?) -> String {
    guard let at else { return "No Reset Time Reported" }
    let left = at.timeIntervalSinceNow
    if left <= 0 { return "Reset \(pastStamp.string(from: at)) · Elapsed" }

    let mins = Int(left / 60)
    let span: String
    if mins < 60 {
        span = "\(mins)m"
    } else if mins < 60 * 24 {
        span = "\(mins / 60)h \(mins % 60)m"
    } else {
        span = "\(mins / 1440)d \((mins % 1440) / 60)h"
    }
    let sameDay = Calendar.current.isDate(at, inSameDayAs: Date())
    let when = sameDay ? clock.string(from: at) : dayClock.string(from: at)
    return "Resets \(when) · In \(span)"
}

// MARK: - Reading model

enum Severity {
    case ok, warn, crit, unknown

    /// The server tells us the severity where it can; otherwise derive it.
    static func from(_ label: String?, percent: Double?) -> Severity {
        switch label?.lowercased() {
        case "normal", "ok", "low":     return .ok
        case "warning", "warn", "medium", "high": return .warn
        case "critical", "crit", "exceeded", "reached": return .crit
        default: break
        }
        guard let p = percent else { return .unknown }
        if p >= 85 { return .crit }
        if p >= 60 { return .warn }
        return .ok
    }

    var color: NSColor {
        switch self {
        case .ok:      return NSColor(srgbRed: 0.23, green: 0.55, blue: 0.35, alpha: 1)
        case .warn:    return NSColor(srgbRed: 0.72, green: 0.49, blue: 0.13, alpha: 1)
        case .crit:    return NSColor(srgbRed: 0.71, green: 0.24, blue: 0.19, alpha: 1)
        case .unknown: return NSColor.tertiaryLabelColor
        }
    }
}

struct Gauge {
    let label: String
    let percent: Double?        // nil when the window is unreadable or elapsed
    let resetsAt: Date?
    let severity: Severity
}

struct Reading {
    let provider: String
    var plan: String?
    var gauges: [Gauge] = []
    var problem: String?        // shown in place of gauges when nothing parsed
}

// MARK: - JSON helpers

private func obj(_ any: Any?) -> [String: Any]? { any as? [String: Any] }
private func num(_ any: Any?) -> Double? {
    if let d = any as? Double { return d }
    if let i = any as? Int { return Double(i) }
    if let s = any as? String { return Double(s) }
    return nil
}

private let iso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoPlain = ISO8601DateFormatter()

private func date(_ any: Any?) -> Date? {
    if let s = any as? String {
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }
    if let secs = num(any) { return Date(timeIntervalSince1970: secs) }
    return nil
}

// MARK: - Codex

enum CodexSource {
    private static var root: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    }

    /// One directory walk, newest first, with the mtimes we also need as an
    /// activity signal — so a poll tick costs a single traversal rather than one
    /// per caller.
    private static func scan() -> [(url: URL, mtime: Date)] {
        guard let walk = FileManager.default
            .enumerator(at: root,
                        includingPropertiesForKeys: [.contentModificationDateKey],
                        options: [.skipsHiddenFiles])
        else { return [] }
        var found: [(URL, Date)] = []
        for case let u as URL in walk where u.pathExtension == "jsonl" {
            let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            found.append((u, m))
        }
        return found.sorted { $0.1 > $1.1 }.map { (url: $0.0, mtime: $0.1) }
    }

    /// Newest log mtime seen by the last read(), so the poll loop can detect
    /// activity without walking the tree a second time.
    private(set) static var newestMtime: Date = .distantPast

    /// Parsed result per file, keyed on the mtime it was parsed at. Sessions are
    /// append-only and most are dormant, so an unchanged file is never re-read.
    /// Main-thread only, like every other call into this type.
    private static var memo: [URL: (mtime: Date, hit: (Date, [String: Any])?)] = [:]

    /// The last 512 KB of a file. rate_limits lines sit at the end of a session,
    /// and a long transcript can run to many megabytes. Slicing mid-line leaves
    /// one unparseable fragment at the front, which the JSON guard discards.
    private static func tail(_ url: URL, limit: UInt64 = 512 * 1024) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let end = try? fh.seekToEnd() else { return nil }
        if end > limit { try? fh.seek(toOffset: end - limit) }
        guard let d = try? fh.readToEnd() else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Newest usable rate_limits payload in one file, or nil.
    private static func parse(_ url: URL) -> (Date, [String: Any])? {
        guard let text = tail(url) else { return nil }
        var newest: (Date, [String: Any])?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("\"rate_limits\"") else { continue }
            guard let d = line.data(using: .utf8),
                  let row = obj(try? JSONSerialization.jsonObject(with: d)),
                  let rl = obj(obj(row["payload"])?["rate_limits"]),
                  obj(rl["primary"]) != nil          // the "premium" bucket
            else { continue }
            let ts = date(row["timestamp"]) ?? .distantPast
            if newest == nil || ts > newest!.0 { newest = (ts, rl) }
        }
        return newest
    }

    /// The newest usable rate_limits payload across recent sessions. Two traps:
    ///
    /// - Entries tagged limit_id "premium" carry null windows and must be
    ///   skipped, or we read a blank on a perfectly healthy account.
    /// - File mtime is not reading age. A log can be appended to long after its
    ///   last rate_limits line, so compare payload timestamps across every
    ///   recent file and take the newest of those, not the first file that
    ///   happens to yield something.
    static func read() -> Reading {
        var out = Reading(provider: "ChatGPT")
        var newest: (Date, [String: Any])?

        let logs = scan()
        newestMtime = logs.first?.mtime ?? .distantPast

        let recent = Array(logs.prefix(8))
        for (url, mtime) in recent {
            let hit: (Date, [String: Any])?
            if let c = memo[url], c.mtime == mtime {
                hit = c.hit                       // unchanged since last parse
            } else {
                hit = parse(url)
                memo[url] = (mtime: mtime, hit: hit)
            }
            if let h = hit, newest == nil || h.0 > newest!.0 { newest = h }
        }
        // Keep the memo bounded to the window we actually consult.
        let keep = Set(recent.map(\.url))
        memo = memo.filter { keep.contains($0.key) }

        if let (_, rl) = newest {

            if let plan = rl["plan_type"] as? String, !plan.isEmpty {
                out.plan = titleCase(plan)
            } else {
                out.plan = "Unknown Plan"
            }

            // Name the window by its length rather than by a hardcoded key, so a
            // plan with different windows still labels them correctly.
            for key in ["primary", "secondary"] {
                guard let w = obj(rl[key]) else { continue }
                let mins = num(w["window_minutes"]) ?? 0
                let label: String
                switch mins {
                case 0:            label = titleCase(key)
                case ..<120:       label = "\(Int(mins / 60))-Hour Window"
                case ..<(60 * 48): label = "\(Int(mins / 60))-Hour Window"
                default:           label = mins >= 10000 ? "Weekly Window"
                                                         : "\(Int(mins / 1440))-Day Window"
                }
                // Same rule as Claude: a percentage only describes the window it
                // was measured in. Once the reset has passed that window has
                // rolled over, and the old number is not a smaller number — it
                // is an unknown one. ChatGPT only writes a fresh reading when it
                // takes a turn, so this greys out whenever you have been away.
                let at = date(w["resets_at"])
                let elapsed = (at?.timeIntervalSinceNow ?? 1) <= 0
                let pct = num(w["used_percent"])
                out.gauges.append(Gauge(label: label,
                                        percent: elapsed ? nil : pct,
                                        resetsAt: at,
                                        severity: elapsed ? .unknown
                                                          : .from(nil, percent: pct)))
            }
            return out
        }

        out.problem = "No Session Log Found"
        return out
    }
}

// MARK: - Claude

enum ClaudeSource {
    struct Creds {
        let token: String
        let expiresAt: Date?
        let subscription: String?
        var expired: Bool { (expiresAt.map { $0 <= Date() }) ?? false }
    }

    /// Read one generic-password item. Read-only, fixed argv, no shell, so
    /// nothing is interpolated into a command line. The value is returned to the
    /// caller and never stored.
    private static func keychain(_ service: String) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }

    /// Claude Code's credential. It lapses within hours of a login and is only
    /// renewed when the CLI itself makes a request.
    ///
    /// A long-lived token from `claude setup-token` cannot substitute: it is
    /// scoped for inference only, and /api/oauth/usage answers such a token with
    /// "does not meet scope requirement user:profile". Verified, not assumed.
    ///
    /// Nothing is stored: this runs at the moment of the call and the value is
    /// discarded after.
    private static func creds() -> Creds? {
        guard let data = keychain("Claude Code-credentials"),
              let root = obj(try? JSONSerialization.jsonObject(with: data)),
              let oauth = obj(root["claudeAiOauth"]),
              let tok = oauth["accessToken"] as? String, !tok.isEmpty
        else { return nil }
        // expiresAt is milliseconds since the epoch.
        let exp = num(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Creds(token: tok, expiresAt: exp,
                     subscription: oauth["subscriptionType"] as? String)
    }

    private static func planLabel(_ c: Creds? = nil) -> String? {
        if let s = c?.subscription, !s.isEmpty { return titleCase(s) }
        let path = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
        guard let d = try? Data(contentsOf: path),
              let root = obj(try? JSONSerialization.jsonObject(with: d)),
              let acct = obj(root["oauthAccount"])
        else { return nil }
        // organizationType is the readable one. The rate-limit tier that sits
        // beside it is an internal codename and is deliberately never shown.
        if let t = acct["organizationType"] as? String, !t.isEmpty {
            return titleCase(t.replacingOccurrences(of: "claude_", with: ""))
        }
        return nil
    }

    /// Turn a utilization payload into gauges by walking its self-describing
    /// limits[] array — one gauge per entry the account actually has.
    private static func gauges(from util: [String: Any]) -> [Gauge] {
        guard let limits = util["limits"] as? [[String: Any]] else {
            return namedGauges(from: util)
        }
        var out: [Gauge] = []
        for l in limits {
            if let active = l["is_active"] as? Bool, active == false { continue }
            let kind = (l["kind"] as? String) ?? (l["group"] as? String) ?? "limit"
            let pct = num(l["percent"])
            let at = date(l["resets_at"])
            let elapsed = (at?.timeIntervalSinceNow ?? 1) <= 0

            let label: String
            switch kind.lowercased() {
            case "session":         label = "5-Hour Session"
            case "seven_day", "week", "weekly": label = "Weekly Window"
            case "seven_day_opus", "opus":      label = "Weekly Opus"
            default:               label = titleCase(kind)
            }
            // A percentage only describes the window it was measured in. Once the
            // reset time has passed that window is gone, so print no number.
            out.append(Gauge(label: label,
                             percent: elapsed ? nil : pct,
                             resetsAt: at,
                             severity: elapsed ? .unknown : .from(l["severity"] as? String,
                                                                  percent: pct)))
        }
        return out.isEmpty ? namedGauges(from: util) : out
    }

    /// Older shape: one object per named window rather than a limits[] array.
    /// Kept because the cache file proves these keys exist, so a response
    /// without limits[] should still render.
    private static func namedGauges(from util: [String: Any]) -> [Gauge] {
        let known: [(String, String)] = [
            ("five_hour", "5-Hour Session"),
            ("seven_day", "Weekly Window"),
            ("seven_day_opus", "Weekly Opus"),
        ]
        var out: [Gauge] = []
        for (key, label) in known {
            guard let w = obj(util[key]), let pct = num(w["utilization"]) else { continue }
            let at = date(w["resets_at"])
            let elapsed = (at?.timeIntervalSinceNow ?? 1) <= 0
            out.append(Gauge(label: label,
                             percent: elapsed ? nil : pct,
                             resetsAt: at,
                             severity: elapsed ? .unknown : .from(nil, percent: pct)))
        }
        return out
    }

    /// The local cache, used only as a fallback when the fetch fails.
    static func cached() -> Reading {
        var out = Reading(provider: "Claude", plan: planLabel())
        let path = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
        guard let d = try? Data(contentsOf: path),
              let root = obj(try? JSONSerialization.jsonObject(with: d)),
              let util = obj(obj(root["cachedUsageUtilization"])?["utilization"])
        else {
            out.problem = "No Local Reading"
            return out
        }
        out.gauges = gauges(from: util)
        if out.gauges.isEmpty { out.problem = "No Windows Reported" }
        return out
    }

    /// GET /api/oauth/usage — the same call the Claude Code client makes to fill
    /// its cache. No model is invoked, so this consumes no tokens.
    static func fetch(_ done: @escaping (Reading) -> Void) {
        guard let c = creds() else {
            var r = cached(); r.problem = "Keychain Unavailable"
            done(r); return
        }
        // Refreshing the token is Claude Code's job, not ours: doing the refresh
        // grant here would mean writing to a credential another app owns. So
        // when it has lapsed we say so instead of sending a doomed request.
        if c.expired {
            var r = cached()
            r.plan = planLabel(c)
            r.problem = "Sign-In Stale · Run: claude, then /usage"
            done(r); return
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.httpMethod = "GET"
        req.timeoutInterval = 12
        req.setValue("Bearer \(c.token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("AgentMeter/1.0", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { data, resp, _ in
            var out = Reading(provider: "Claude", plan: planLabel(c))
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let data,
                  let root = obj(try? JSONSerialization.jsonObject(with: data))
            else {
                // Fall back to the cache rather than showing nothing, but keep
                // the failure visible so a broken endpoint is never silent.
                var r = cached()
                r.plan = planLabel(c)
                r.problem = code == 401 ? "Sign-In Rejected · Run: claude auth login"
                     : code == 403 ? "Token Lacks Usage Scope"
                     : "Fetch Failed (\(code))"
                DispatchQueue.main.async { done(r) }
                return
            }
            let util = obj(root["utilization"]) ?? root
            out.gauges = gauges(from: util)
            if out.gauges.isEmpty { out.problem = "No Windows Reported" }
            DispatchQueue.main.async { done(out) }
        }.resume()
    }
}

// MARK: - Menu-bar glyph

enum Glyph {
    /// The app icon's mark — a 240-degree dial with a needle at 72% of sweep —
    /// drawn flat as a template image so macOS tints it for the light or dark
    /// menu bar the way every other status item is tinted.
    static func mark(size: CGFloat = 21) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.setAllowsAntialiasing(true)

            let c = CGPoint(x: size / 2, y: size / 2 - size * 0.05)
            let r = size * 0.375
            let lw = size * 0.115
            let a0 = CGFloat.pi * 210 / 180
            let a1 = CGFloat.pi * -30 / 180
            let frac: CGFloat = 0.72
            let na = a0 - (a0 - a1) * frac
            let black = NSColor.black.cgColor

            ctx.setLineCap(.round)

            // Track at partial alpha, live sweep solid — the same two-tone arc
            // as the app icon, which a template image renders as one tint at
            // two opacities.
            ctx.setLineWidth(lw)
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.32).cgColor)
            ctx.addArc(center: c, radius: r, startAngle: a0, endAngle: a1, clockwise: true)
            ctx.strokePath()

            ctx.setStrokeColor(black)
            ctx.addArc(center: c, radius: r, startAngle: a0, endAngle: na, clockwise: true)
            ctx.strokePath()

            // Needle and hub.
            ctx.setLineWidth(lw * 0.72)
            ctx.setStrokeColor(black)
            ctx.move(to: c)
            ctx.addLine(to: CGPoint(x: c.x + cos(na) * r * 0.64,
                                    y: c.y + sin(na) * r * 0.64))
            ctx.strokePath()

            ctx.setFillColor(black)
            ctx.addArc(center: c, radius: lw * 0.52, startAngle: 0, endAngle: .pi * 2,
                       clockwise: false)
            ctx.fillPath()
        }
        img.unlockFocus()
        img.isTemplate = true
        return img
    }
}

// MARK: - Panel

/// Draws the whole reading panel in one view. Hand-drawn rather than assembled
/// from subviews so the layout matches the design exactly at 11-13pt.
final class PanelView: NSView {
    var readings: [Reading] = []
    var refreshedAt: Date?
    var note: String?

    private let W: CGFloat = 320
    private let pad: CGFloat = 14

    private func attrs(_ size: CGFloat, _ weight: NSFont.Weight,
                       _ color: NSColor, mono: Bool = false) -> [NSAttributedString.Key: Any] {
        let f = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                     : NSFont.systemFont(ofSize: size, weight: weight)
        return [.font: f, .foregroundColor: color]
    }

    private let gaugeBlock: CGFloat = 50   // includes the gap between windows
    private let providerGap: CGFloat = 10
    private let headerRule: CGFloat = 10   // rule plus the gap beneath it

    /// Content height, computed the same way draw() lays it out. Kept in step
    /// with draw() deliberately: any slack here shows up as dead space between
    /// the last gauge and the Refresh Now item below the panel.
    func fittingHeight() -> CGFloat {
        var h = pad + 26 + headerRule                     // top margin, header, rule
        for (i, r) in readings.enumerated() {
            h += 22                                       // provider name row
            if r.problem != nil { h += 18 }
            h += r.gauges.isEmpty ? 18 : CGFloat(r.gauges.count) * gaugeBlock
            if i < readings.count - 1 { h += providerGap }
        }
        if note != nil { h += 22 }
        return h + 2
    }

    override var intrinsicContentSize: NSSize { NSSize(width: W, height: fittingHeight()) }

    override func draw(_ dirty: NSRect) {
        var y = bounds.height - pad

        func line(_ s: String, _ a: [NSAttributedString.Key: Any],
                  x: CGFloat, dy: CGFloat, right: Bool = false) {
            let str = NSAttributedString(string: s, attributes: a)
            let w = str.size().width
            str.draw(at: NSPoint(x: right ? bounds.width - pad - w : x, y: y - dy))
        }

        // Header
        line("AgentMeter", attrs(13, .semibold, .labelColor), x: pad, dy: 14)
        if let at = refreshedAt {
            line("Refreshed \(clock.string(from: at))",
                 attrs(10, .regular, .tertiaryLabelColor, mono: true), x: 0, dy: 13, right: true)
        }
        y -= 26

        // Divider in the same colour AppKit uses for the menu's own separators,
        // so the header reads as a section the way Refresh Now and Quit do.
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: y - 1, width: bounds.width, height: 1).fill()
        y -= headerRule

        for (i, r) in readings.enumerated() {
            // Rail in the provider's own colour, drawn beside the block.
            let blockTop = y
            let rail = r.provider == "Claude"
                ? NSColor(srgbRed: 0.76, green: 0.39, blue: 0.24, alpha: 1)
                : NSColor(srgbRed: 0.06, green: 0.56, blue: 0.44, alpha: 1)

            line(r.provider, attrs(12.5, .semibold, .labelColor), x: pad + 8, dy: 13)
            if let plan = r.plan {
                line(plan, attrs(10, .regular, .secondaryLabelColor, mono: true),
                     x: 0, dy: 12, right: true)
            }
            y -= 22

            if let problem = r.problem {
                line(problem, attrs(10.5, .medium,
                                    NSColor(srgbRed: 0.72, green: 0.49, blue: 0.13, alpha: 1)),
                     x: pad + 8, dy: 12)
                y -= 18
            }

            for g in r.gauges {
                line(g.label, attrs(11.5, .regular, .secondaryLabelColor), x: pad + 8, dy: 12)
                let shown = g.percent.map { "\(Int($0.rounded()))%" } ?? "—"
                line(shown, attrs(11.5, .semibold, g.severity.color), x: 0, dy: 12, right: true)

                // Track, then fill.
                let bar = NSRect(x: pad + 8, y: y - 24, width: bounds.width - pad * 2 - 8, height: 5)
                NSColor.quaternaryLabelColor.setFill()
                NSBezierPath(roundedRect: bar, xRadius: 2.5, yRadius: 2.5).fill()
                if let p = g.percent, p > 0 {
                    let w = bar.width * CGFloat(max(0, min(100, p)) / 100)
                    g.severity.color.setFill()
                    NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY,
                                                     width: max(w, 3), height: bar.height),
                                 xRadius: 2.5, yRadius: 2.5).fill()
                }

                line(resetLine(g.resetsAt),
                     attrs(10, .regular, .tertiaryLabelColor, mono: true), x: pad + 8, dy: 39)
                y -= gaugeBlock
            }

            rail.setFill()
            NSBezierPath(roundedRect: NSRect(x: pad, y: y + 6, width: 3,
                                             height: blockTop - y - 8),
                         xRadius: 1.5, yRadius: 1.5).fill()
            if i < readings.count - 1 { y -= providerGap }
        }

        if let note {
            line(note, attrs(10, .regular, .tertiaryLabelColor, mono: true), x: pad, dy: 12)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let panel = PanelView()

    private var codex = Reading(provider: "Codex")
    private var claude = Reading(provider: "Claude")

    /// Guards the one network call: activity in either tool asks for a Claude
    /// refresh, but never more than once a minute however busy the session is.
    private var lastClaudeFetch = Date.distantPast
    private let fetchCooldown: TimeInterval = 60

    private var lastActivity: Date?
    private var watchTimer: Timer?
    private var hourlyTimer: Timer?

    private let agentBundles: Set<String> = ["com.anthropic.claudefordesktop", "com.openai.codex"]

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu

        // Trigger 1 — you launch or switch to Claude or Codex.
        let wc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            wc.addObserver(self, selector: #selector(agentAppEvent(_:)), name: name, object: nil)
        }

        // Trigger 2 — either tool writes a log line. Polling the newest file's
        // stamp is cheaper and far less code than an FSEvents stream, and the
        // local Codex re-read it drives costs nothing.
        watchTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.pollLogs()
        }

        // Trigger 3 — hourly floor, so an idle panel is never badly stale.
        hourlyTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.refresh(force: true)
        }

        refresh(force: true)
    }

    // MARK: Refresh

    @objc private func agentAppEvent(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let id = app.bundleIdentifier, agentBundles.contains(id)
        else { return }
        refresh(force: false)
    }

    /// Newest mtime under ~/.claude/projects. The ChatGPT side reports its own
    /// newest mtime from the read it already performed, so only this one tree
    /// needs a walk of its own.
    private func newestClaudeStamp() -> Date {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects")
        guard let walk = FileManager.default
            .enumerator(at: root,
                        includingPropertiesForKeys: [.contentModificationDateKey],
                        options: [.skipsHiddenFiles])
        else { return .distantPast }
        var newest = Date.distantPast
        for case let u as URL in walk where u.pathExtension == "jsonl" {
            if let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate, m > newest { newest = m }
        }
        return newest
    }

    private func pollLogs() {
        // One ChatGPT read per tick — it walks its own tree and reports the
        // newest mtime it saw, so nothing here reads or walks twice.
        codex = CodexSource.read()
        let stamp = max(CodexSource.newestMtime, newestClaudeStamp())
        let moved = lastActivity.map { stamp > $0 } ?? true
        lastActivity = stamp
        updateBar()
        if moved { requestClaudeFetch(force: false) }
    }

    /// Re-read ChatGPT from disk and ask for a Claude fetch. Kept separate from
    /// requestClaudeFetch so callers that have just read ChatGPT do not read it
    /// again.
    private func refresh(force: Bool) {
        codex = CodexSource.read()
        updateBar()
        requestClaudeFetch(force: force)
    }

    /// The single guard on the one network call in this app.
    private func requestClaudeFetch(force: Bool) {
        let due = force || Date().timeIntervalSince(lastClaudeFetch) >= fetchCooldown
        guard due else { return }
        lastClaudeFetch = Date()
        ClaudeSource.fetch { [weak self] r in
            guard let self else { return }
            self.claude = r
            self.panel.refreshedAt = Date()
            self.updateBar()
            self.rebuild()
        }
    }

    // MARK: UI

    /// The bar shows the single window closest to its ceiling, across both
    /// providers — the only number worth a glance.
    private func worst() -> Gauge? {
        (codex.gauges + claude.gauges)
            .filter { $0.percent != nil }
            .max { ($0.percent ?? 0) < ($1.percent ?? 0) }
    }

    private func updateBar() {
        guard let button = statusItem.button else { return }
        button.image = Glyph.mark()
        button.imagePosition = .imageOnly
        button.attributedTitle = NSAttributedString(string: "")

        // The figures live in the panel now, so carry the summary in the tooltip.
        if let g = worst(), let p = g.percent {
            button.toolTip = "AgentMeter — \(g.label) at \(Int(p.rounded()))%"
        } else {
            button.toolTip = "AgentMeter — open for readings"
        }
    }

    private func rebuild() {
        menu.removeAllItems()

        panel.readings = [codex, claude]
        panel.note = nil
        panel.frame = NSRect(x: 0, y: 0, width: 320, height: panel.fittingHeight())
        panel.needsDisplay = true

        let host = NSMenuItem()
        host.view = panel
        menu.addItem(host)
        menu.addItem(.separator())

        let r = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        r.target = self
        menu.addItem(r)

        let login = NSMenuItem(title: "Open At Login", action: #selector(toggleLogin),
                               keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let q = NSMenuItem(title: "Quit AgentMeter", action: #selector(NSApplication.terminate(_:)),
                           keyEquivalent: "q")
        menu.addItem(q)
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    func menuWillOpen(_ menu: NSMenu) {
        refresh(force: false)     // reads ChatGPT once; menuNeedsUpdate rebuilds
    }

    @objc private func refreshNow() { refresh(force: true) }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("AgentMeter: login item toggle failed — %@", error.localizedDescription)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
