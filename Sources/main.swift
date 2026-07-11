import AppKit
import Foundation
import Security
import ServiceManagement
import UserNotifications

// MARK: - Configuration

enum Config {
    static let keychainService = "Claude Code-credentials"
    // ClaudeQuota's OWN credential store. The app owns this item outright
    // (created under our signing identity), so reads and writes never prompt
    // and never touch Claude Code's item.
    static let ownKeychainService = "ClaudeQuota-credentials"
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    // Claude Code's public OAuth client ID (same one the CLI uses for refresh)
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let pollInterval: TimeInterval = 180 // 3 minutes
    static let maxBackoff: TimeInterval = 180 * 8
    static let warnThreshold = 75.0
    static let dangerThreshold = 90.0
    static let notifyThresholds: [Double] = [80, 95]
}

// MARK: - Models

struct UsageWindow {
    let key: String
    let label: String
    let utilization: Double
    let resetsAt: Date?
    var detail: String? = nil // extra text shown in place of a reset time
}

struct Credentials {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Double // ms since epoch
    var raw: [String: Any]   // full keychain JSON, preserved on write-back
    var wrapped: Bool        // true if nested under "claudeAiOauth"

    var isExpired: Bool {
        Date().timeIntervalSince1970 * 1000 > expiresAt - 60_000
    }
}

// MARK: - Keychain

enum KeychainError: Error, CustomStringConvertible {
    case status(OSStatus)
    case badData
    var description: String {
        switch self {
        case .status(let s): return "Keychain error \(s)"
        case .badData: return "Keychain data unreadable"
        }
    }
}

enum Keychain {
    static func readCredentials() throws -> Credentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Config.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.status(status)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KeychainError.badData
        }
        let wrapped = json["claudeAiOauth"] != nil
        let oauth = (json["claudeAiOauth"] as? [String: Any]) ?? json
        guard let access = oauth["accessToken"] as? String,
              let refresh = oauth["refreshToken"] as? String else {
            throw KeychainError.badData
        }
        let expires = (oauth["expiresAt"] as? Double) ?? 0
        return Credentials(accessToken: access, refreshToken: refresh,
                           expiresAt: expires, raw: json, wrapped: wrapped)
    }

    // Deliberately NO write support for the item above: ClaudeQuota is
    // read-only toward the shared Claude Code credential. Writing to it
    // resets the item's access controls, which breaks Claude Code's own
    // Keychain grants and triggers repeated password prompts. Claude Code
    // alone maintains that item. Refreshed tokens go to our own item below.

    static func readOwnCredentials() -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Config.ownKeychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["accessToken"] as? String,
              let refresh = json["refreshToken"] as? String else { return nil }
        return Credentials(accessToken: access, refreshToken: refresh,
                           expiresAt: (json["expiresAt"] as? Double) ?? 0,
                           raw: json, wrapped: false)
    }

    static func writeOwnCredentials(_ creds: Credentials) {
        let payload: [String: Any] = [
            "accessToken": creds.accessToken,
            "refreshToken": creds.refreshToken,
            "expiresAt": creds.expiresAt,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Config.ownKeychainService,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

// MARK: - API client (synchronous helpers, called off the main thread)

enum APIError: Error, CustomStringConvertible {
    case network(String)
    case http(Int, String)
    case parse

    var description: String {
        switch self {
        case .network(let m): return "Network: \(m)"
        case .http(let c, _): return "HTTP \(c)"
        case .parse: return "Unexpected response format"
        }
    }
}

enum API {
    private static func send(_ request: URLRequest) throws -> (Int, Data) {
        var result: (Int, Data)?
        var netError: String?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, resp, err in
            if let err = err { netError = err.localizedDescription }
            else if let http = resp as? HTTPURLResponse { result = (http.statusCode, data ?? Data()) }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 30)
        if let netError = netError { throw APIError.network(netError) }
        guard let result = result else { throw APIError.network("timeout") }
        return result
    }

    /// Exchange a refresh token for a fresh access token. Called only when
    /// no stored token (Claude Code's or our own) is still valid, so it can
    /// never race an active Claude Code session's credentials.
    static func refreshToken(_ creds: Credentials) throws -> Credentials {
        var req = URLRequest(url: Config.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": creds.refreshToken,
            "client_id": Config.clientID,
        ])
        let (code, data) = try send(req)
        guard code == 200 else {
            throw APIError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw APIError.parse
        }
        var updated = creds
        updated.accessToken = access
        if let refresh = json["refresh_token"] as? String { updated.refreshToken = refresh }
        let expiresIn = (json["expires_in"] as? Double) ?? 28800
        updated.expiresAt = (Date().timeIntervalSince1970 + expiresIn) * 1000
        return updated
    }

    static func fetchUsage(accessToken: String) throws -> [UsageWindow] {
        var req = URLRequest(url: Config.usageURL)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (code, data) = try send(req)
        guard code == 200 else {
            throw APIError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.parse
        }
        return parseWindows(json)
    }

    /// Live plan name from /api/oauth/profile, e.g. "Max (5x)" or "Pro".
    /// Returns nil on any failure so callers can fall back to the cached value.
    static func fetchProfile(accessToken: String) -> String? {
        var req = URLRequest(url: Config.profileURL)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (code, data) = try? send(req), code == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let org = json["organization"] as? [String: Any] else { return nil }
        let type = (org["organization_type"] as? String) ?? ""
        var plan: String
        if type.contains("max") { plan = "Max" }
        else if type.contains("pro") { plan = "Pro" }
        else if type.contains("free") { plan = "Free" }
        else if !type.isEmpty { plan = type.replacingOccurrences(of: "claude_", with: "").capitalized }
        else { return nil }
        // rate_limit_tier like "default_claude_max_5x" → "Max (5x)"
        if let tier = org["rate_limit_tier"] as? String, tier.hasSuffix("x"),
           let multiplier = tier.split(separator: "_").last, multiplier.count <= 4 {
            plan += " (\(multiplier))"
        }
        return plan
    }

    // Known window keys with friendly labels, in display order. Any other
    // object that looks like {utilization, resets_at} is appended afterward
    // so new fields from Anthropic still show up.
    private static let knownKeys: [(String, String)] = [
        ("five_hour", "Session (5-hr)"),
        ("seven_day", "Weekly (All)"),
        ("seven_day_sonnet", "Weekly (Sonnet)"),
        ("seven_day_opus", "Weekly (Opus)"),
        ("seven_day_oauth_apps", "Weekly (Apps)"),
    ]

    private static func parseWindows(_ json: [String: Any]) -> [UsageWindow] {
        let iso = ISO8601DateFormatter()
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        func parseDate(_ s: String?) -> Date? {
            guard let s = s else { return nil }
            return isoFrac.date(from: s) ?? iso.date(from: s)
        }

        // Extra Usage (paid monthly overage credits): shown only when enabled.
        var extraRows: [UsageWindow] = []
        if let extra = json["extra_usage"] as? [String: Any],
           extra["is_enabled"] as? Bool == true,
           let util = extra["utilization"] as? Double {
            var detail: String?
            if let used = extra["used_credits"] as? Double,
               let limit = extra["monthly_limit"] as? Double {
                let divisor = pow(10.0, (extra["decimal_places"] as? Double) ?? 2)
                detail = String(format: "$%.2f of $%.2f/mo", used / divisor, limit / divisor)
            }
            extraRows.append(UsageWindow(key: "extra_usage", label: "Extra Usage",
                                         utilization: util, resetsAt: nil, detail: detail))
        }

        // Preferred: the modern `limits` array (kind/percent/resets_at/scope),
        // which includes model-scoped weekly limits the legacy keys omit.
        if let limits = json["limits"] as? [[String: Any]], !limits.isEmpty {
            var out: [UsageWindow] = []
            for limit in limits {
                guard let kind = limit["kind"] as? String,
                      let percent = limit["percent"] as? Double else { continue }
                var label: String
                switch kind {
                case "session": label = "Session (5-hr)"
                case "weekly_all": label = "Weekly (All)"
                case "weekly_scoped":
                    let scope = limit["scope"] as? [String: Any]
                    let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
                    let surface = scope?["surface"] as? String
                    label = "Weekly (\(model ?? surface ?? "Scoped"))"
                default:
                    label = kind.replacingOccurrences(of: "_", with: " ").capitalized
                }
                let key = kind == "session" ? "five_hour" : kind + ((limit["scope"] as? [String: Any]).map { _ in "_scoped" } ?? "")
                out.append(UsageWindow(key: key, label: label,
                                       utilization: percent,
                                       resetsAt: parseDate(limit["resets_at"] as? String)))
            }
            if !out.isEmpty { return out + extraRows }
        }

        func window(key: String, label: String, dict: [String: Any]) -> UsageWindow? {
            guard let util = dict["utilization"] as? Double else { return nil }
            var resets: Date?
            if let s = dict["resets_at"] as? String {
                resets = isoFrac.date(from: s) ?? iso.date(from: s)
            }
            return UsageWindow(key: key, label: label, utilization: util, resetsAt: resets)
        }

        var out: [UsageWindow] = []
        for (key, label) in knownKeys {
            if let dict = json[key] as? [String: Any], let w = window(key: key, label: label, dict: dict) {
                out.append(w)
            }
        }
        let known = Set(knownKeys.map { $0.0 }).union(["extra_usage", "limits", "spend"])
        for (key, value) in json.sorted(by: { $0.key < $1.key }) where !known.contains(key) {
            if let dict = value as? [String: Any],
               let w = window(key: key, label: key.replacingOccurrences(of: "_", with: " ").capitalized, dict: dict) {
                out.append(w)
            }
        }
        return out + extraRows
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var currentInterval = Config.pollInterval
    private var windows: [UsageWindow] = []
    private var lastUpdated: Date?
    private var lastError: String?
    private var notifiedThresholds: Set<Double> = []
    private var notificationsAvailable = false
    private var planName: String?
    private var isStale = false
    private let queue = DispatchQueue(label: "usage-poller", qos: .utility)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◔ …"
        statusItem.menu = buildMenu()

        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                self.notificationsAvailable = granted
            }
        }

        scheduleTimer(interval: currentInterval)
        refresh()
    }

    // MARK: Polling

    private func scheduleTimer(interval: TimeInterval) {
        timer?.invalidate()
        currentInterval = interval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc func refreshNow() {
        // Manual refresh also resets any backoff
        if currentInterval != Config.pollInterval { scheduleTimer(interval: Config.pollInterval) }
        refresh()
    }

    /// Credential strategy (v1.1.1): our own chain first, Claude Code's item
    /// only as seed/recovery. Once ClaudeQuota holds its own refresh token the
    /// chain is self-sustaining, and every avoided read of Claude Code's item
    /// is an avoided Keychain prompt — Claude Code wipes our read grant each
    /// time it rewrites that item. Claude Code's item is never written.
    private func obtainCredentials() throws -> Credentials {
        if let own = Keychain.readOwnCredentials() {
            if !own.isExpired { return own }
            do {
                let refreshed = try API.refreshToken(own)
                Keychain.writeOwnCredentials(refreshed)
                return refreshed
            } catch {
                // Recovery: our refresh token may have been revoked — Claude
                // Code's item might hold a newer chain. One read (and possible
                // prompt) beats a dead gauge.
                if let cc = try? Keychain.readCredentials() {
                    if !cc.isExpired { return cc }
                    if cc.refreshToken != own.refreshToken,
                       let refreshed = try? API.refreshToken(cc) {
                        Keychain.writeOwnCredentials(refreshed)
                        return refreshed
                    }
                }
                throw error
            }
        }
        // First run (or own item deleted): seed from Claude Code's item.
        let cc = try Keychain.readCredentials()
        if !cc.isExpired { return cc }
        let refreshed = try API.refreshToken(cc)
        Keychain.writeOwnCredentials(refreshed)
        return refreshed
    }

    private func refresh() {
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                let creds: Credentials
                do {
                    creds = try self.obtainCredentials()
                } catch let err as KeychainError {
                    DispatchQueue.main.async { self.applyError("\(err)", backoff: false) }
                    return
                } catch APIError.http(429, _) {
                    DispatchQueue.main.async { self.applyError("Rate limited — backing off", backoff: true) }
                    return
                } catch {
                    // Token refresh failed (offline, or refresh token rejected):
                    // hold last-known data and retry on the normal poll cycle.
                    DispatchQueue.main.async { self.applyStale() }
                    return
                }
                let windows: [UsageWindow]
                do {
                    windows = try API.fetchUsage(accessToken: creds.accessToken)
                } catch APIError.http(401, _) {
                    // Token rejected despite unexpired timestamp — force one
                    // refresh and retry; if that also fails, hold last data.
                    do {
                        let refreshed = try API.refreshToken(creds)
                        Keychain.writeOwnCredentials(refreshed)
                        windows = try API.fetchUsage(accessToken: refreshed.accessToken)
                    } catch {
                        DispatchQueue.main.async { self.applyStale() }
                        return
                    }
                }
                // Fetch the live plan name once per launch (About panel)
                var plan: String?
                DispatchQueue.main.sync { plan = self.planName }
                if plan == nil, let fetched = API.fetchProfile(accessToken: creds.accessToken) {
                    DispatchQueue.main.async { self.planName = fetched }
                }
                DispatchQueue.main.async { self.applySuccess(windows) }
            } catch APIError.http(429, _) {
                DispatchQueue.main.async { self.applyError("Rate limited — backing off", backoff: true) }
            } catch {
                DispatchQueue.main.async { self.applyError("\(error)", backoff: false) }
            }
        }
    }

    private func applySuccess(_ windows: [UsageWindow], resetInterval: Bool = true) {
        self.windows = windows
        lastUpdated = Date()
        lastError = nil
        isStale = false
        if currentInterval != Config.pollInterval { scheduleTimer(interval: Config.pollInterval) }
        maybeNotify()
        updateUI()
    }

    private func applyError(_ message: String, backoff: Bool) {
        lastError = message
        isStale = false
        if backoff {
            let next = min(currentInterval * 2, Config.maxBackoff)
            scheduleTimer(interval: next)
        }
        updateUI()
    }

    /// No usable token right now (refresh failed or offline). Hold last-known
    /// data; keep the normal 3-min poll — each cycle retries the refresh and
    /// also picks up any newer token Claude Code has stored.
    private func applyStale() {
        isStale = true
        lastError = nil
        if currentInterval != Config.pollInterval { scheduleTimer(interval: Config.pollInterval) }
        updateUI()
    }

    /// Utilization adjusted for windows whose reset time has already passed
    /// while our data was stale — locally we know they're back to 0%.
    private func effectiveUtilization(_ w: UsageWindow) -> Double {
        if isStale, let resets = w.resetsAt, resets < Date() { return 0 }
        return w.utilization
    }

    // MARK: UI

    private var sessionWindow: UsageWindow? {
        windows.first { $0.key == "five_hour" } ?? windows.first
    }

    private func updateUI() {
        guard let button = statusItem.button else { return }
        if let session = sessionWindow {
            button.image = Self.gaugeIcon(percent: effectiveUtilization(session),
                                          stale: isStale || lastError != nil)
            button.title = ""
            button.imagePosition = .imageOnly
        } else {
            button.image = nil
            button.imagePosition = .noImage
            button.title = (isStale || lastError != nil) ? "◔ ⚠︎" : "◔ …"
        }
        statusItem.menu = buildMenu()
    }

    /// Ring gauge: circular progress ring (fills clockwise from 12 o'clock)
    /// with the session percentage centered inside.
    private static func gaugeIcon(percent: Double, stale: Bool) -> NSImage {
        let side: CGFloat = 21
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let lineWidth: CGFloat = 2.6
            let circleRect = rect.insetBy(dx: lineWidth / 2 + 0.5, dy: lineWidth / 2 + 0.5)
            var ringColor: NSColor = .systemGreen
            if percent >= Config.dangerThreshold { ringColor = .systemRed }
            else if percent >= Config.warnThreshold { ringColor = .systemOrange }
            if stale { ringColor = .systemGray }

            let track = NSBezierPath(ovalIn: circleRect)
            track.lineWidth = lineWidth
            NSColor.tertiaryLabelColor.setStroke()
            track.stroke()

            let clamped = min(max(percent, 0), 100)
            if clamped > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY),
                              radius: circleRect.width / 2,
                              startAngle: 90,
                              endAngle: 90 - 360 * CGFloat(clamped) / 100,
                              clockwise: true)
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                ringColor.setStroke()
                arc.stroke()
            }

            let text = "\(Int(percent.rounded()))" as NSString
            let fontSize: CGFloat = percent >= 99.5 && !stale ? 7 : 8.5
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: NSColor.labelColor,
            ]
            let ts = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: rect.midX - ts.width / 2, y: rect.midY - ts.height / 2),
                      withAttributes: attrs)
            return true
        }
        image.isTemplate = false
        return image
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        // Control enabled-state ourselves: macOS force-dims disabled items
        // (even with attributed titles), so info rows are kept "enabled"
        // with no action to render at full strength.
        menu.autoenablesItems = false
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "EEE h:mm a"

        if windows.isEmpty && lastError == nil {
            menu.addItem(disabledItem("Loading usage…"))
        }
        for w in windows {
            let value = effectiveUtilization(w)
            let didReset = isStale && value == 0 && w.utilization != 0
            var color = NSColor.labelColor
            if value >= Config.dangerThreshold { color = .systemRed }
            else if value >= Config.warnThreshold { color = .systemOrange }

            let regular = NSFont.systemFont(ofSize: 13)
            let bold = NSFont.boldSystemFont(ofSize: 13)
            let line = NSMutableAttributedString()
            line.append(NSAttributedString(string: "\(w.label): ",
                                           attributes: [.font: regular, .foregroundColor: color]))
            line.append(NSAttributedString(string: String(format: "%.0f%%", value),
                                           attributes: [.font: bold, .foregroundColor: color]))
            if didReset {
                line.append(NSAttributedString(string: " (Window reset)",
                                               attributes: [.font: regular, .foregroundColor: color]))
            } else if let resets = w.resetsAt {
                line.append(NSAttributedString(string: " (Resets \(timeFmt.string(from: resets)))",
                                               attributes: [.font: regular, .foregroundColor: color]))
            } else if let detail = w.detail {
                line.append(NSAttributedString(string: " (\(detail))",
                                               attributes: [.font: regular, .foregroundColor: color]))
            }
            menu.addItem(infoRow(line))
        }
        menu.addItem(.separator())
        if let err = lastError {
            menu.addItem(disabledItem("⚠︎ \(err)"))
        }
        if let updated = lastUpdated {
            let fmt = DateFormatter()
            fmt.timeStyle = .short
            if isStale {
                menu.addItem(disabledItem("As of \(fmt.string(from: updated)) — reconnecting…"))
            } else {
                menu.addItem(disabledItem("Updated \(fmt.string(from: updated)) · every \(Int(currentInterval / 60)) min"))
            }
        } else if isStale {
            menu.addItem(disabledItem("Reconnecting to Claude…"))
        }
        menu.addItem(.separator())
        menu.addItem(makeItem("Refresh Now", action: #selector(refreshNow), key: "r"))
        let login = makeItem("Start at Login", action: #selector(toggleLogin), key: "")
        if #available(macOS 13.0, *) {
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            login.isEnabled = false
        }
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(makeItem("About ClaudeQuota", action: #selector(showAbout), key: ""))
        menu.addItem(makeItem("Quit", action: #selector(quit), key: "q"))
        return menu
    }

    @objc func showAbout() {
        // Prefer the live plan from /api/oauth/profile; fall back to the
        // (possibly stale) snapshot Claude Code cached in the Keychain.
        let plan = planName ?? (try? Keychain.readCredentials().raw)
            .flatMap { ($0["claudeAiOauth"] as? [String: Any]) ?? $0 }
            .flatMap { $0["subscriptionType"] as? String }?.capitalized ?? "—"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let alert = NSAlert()
        alert.messageText = "ClaudeQuota v\(version)"
        alert.informativeText = "Live Claude usage tracking\nin your macOS menu bar."

        // Detail block as a text view so "Michael Dickerson" can be a live link.
        // Left-aligned to match NSAlert's fixed title/description alignment.
        let para = NSMutableParagraphStyle()
        para.alignment = .left
        para.lineSpacing = 2
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para,
        ]
        var linkAttrs = base
        linkAttrs[.link] = URL(string: "https://michaeldickerson.dev/")!
        let body = NSMutableAttributedString(string: "Developer: ", attributes: base)
        body.append(NSAttributedString(string: "Michael Dickerson", attributes: linkAttrs))
        body.append(NSAttributedString(string: """

        Created: July 2026
        Build: Swift (AppKit)
        Claude Plan: \(plan)
        Data: Anthropic Usage API
        Quota Updated: Every \(Int(Config.pollInterval / 60)) Mins
        """, attributes: base))

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 100))
        textView.textStorage?.setAttributedString(body)
        textView.isEditable = false
        textView.isSelectable = true // required for the link to be clickable
        textView.drawsBackground = false
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        alert.accessoryView = textView
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Non-interactive info row rendered at full strength — a custom-view
    /// menu item (like Apple's Wi-Fi/Battery info rows): no dimming, no
    /// hover highlight, not clickable.
    private func infoRow(_ text: NSAttributedString) -> NSMenuItem {
        let label = NSTextField(labelWithAttributedString: text)
        label.sizeToFit()
        let size = label.frame.size
        // Menu-item views need explicit frames — Auto Layout alone yields a
        // zero-height row.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: size.width + 28, height: size.height + 6))
        label.setFrameOrigin(NSPoint(x: 14, y: 3))
        container.addSubview(label)
        let item = NSMenuItem()
        item.view = container
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func makeItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: Notifications

    private func maybeNotify() {
        guard notificationsAvailable, let session = sessionWindow else { return }
        for threshold in Config.notifyThresholds {
            if session.utilization >= threshold && !notifiedThresholds.contains(threshold) {
                notifiedThresholds.insert(threshold)
                let content = UNMutableNotificationContent()
                content.title = "Claude usage at \(Int(session.utilization))%"
                content.body = "Your 5-hour session window is above \(Int(threshold))%."
                let req = UNNotificationRequest(identifier: "usage-\(Int(threshold))", content: content, trigger: nil)
                UNUserNotificationCenter.current().add(req)
            }
            // Re-arm once usage drops back below the threshold (window reset)
            if session.utilization < threshold { notifiedThresholds.remove(threshold) }
        }
    }

    // MARK: Actions

    @objc func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change login item"
            alert.informativeText = "\(error.localizedDescription)\n\nTip: the app must be in /Applications for Start at Login to work."
            alert.runModal()
        }
        statusItem.menu = buildMenu()
    }

    @objc func quit() { NSApp.terminate(nil) }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
