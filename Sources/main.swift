// CCUsageBar — 菜单栏实时显示 cc-switch 本地代理用量与金额 + sub2api 额度百分比/重置时间
// 数据源: ~/.cc-switch/cc-switch.db (只读) + 当前供应商的 /v1/usage 接口

import AppKit
import SQLite3

let dbPath = NSHomeDirectory() + "/.cc-switch/cc-switch.db"

// MARK: - 数据模型

struct Totals {
    var requests = 0
    var cost = 0.0
    var outTokens = 0
    var inTokens = 0  // 输入(含缓存)
}

struct NamedRow {
    var name: String
    var requests: Int
    var cost: Double
    var outTokens: Int
    var inTokens: Int
}

struct RecentReq {
    var time: String
    var model: String
    var cost: Double
    var outTokens: Int
    var failed: Bool
}

struct Snapshot {
    var day: Totals = Totals()
    var week: Totals = Totals()
    var month: Totals = Totals()
    var byApp: [NamedRow] = []
    var byProvider: [NamedRow] = []
    var byModel: [NamedRow] = []
    var recent: [RecentReq] = []
    var dbError: String? = nil
    var fetchedAt = Date()
}

// sub2api 一个限流窗口(额度)
struct QuotaWindow {
    var label: String      // 如 "7天"
    var limit: Double
    var used: Double
    var percent: Double
    var resetDate: Date?
    var startDateStr: String?  // 窗口起始日 "yyyy-MM-dd"
}

struct DayUsage {
    var date: String       // "yyyy-MM-dd"
    var requests: Int
    var cost: Double
    var outTokens: Int
    var inTokens: Int      // 输入(含缓存)
}

struct QuotaInfo {
    var providerName: String
    var windows: [QuotaWindow]
    var todayCost: Double
    var todayRequests: Int
    var todayOutTokens: Int
    var days: [DayUsage]
    var fetchedAt = Date()
}

// 菜单栏标题显示模式(单选)
enum TitleMode: String, CaseIterable {
    case quotaPercent = "额度百分比"
    case quotaMoney = "额度金额"
    case cost = "今日金额"
    case costTokens = "金额 + 生成令牌"
    case tokens = "生成令牌"
    case requests = "请求数"
}

// MARK: - 格式化

func fmtTokens(_ n: Int) -> String {
    switch abs(n) {
    case 0..<1_000: return "\(n)"
    case 1_000..<1_000_000: return String(format: "%.1fK", Double(n) / 1_000)
    default: return String(format: "%.2fM", Double(n) / 1_000_000)
    }
}

func fmtCost(_ v: Double) -> String {
    if v >= 100 { return String(format: "$%.1f", v) }
    return String(format: "$%.2f", v)
}

func fmtMoney2(_ v: Double) -> String { String(format: "$%.2f", v) }

func fmtPercent(_ p: Double) -> String {
    if p < 1 { return String(format: "%.2f%%", p) }
    if p < 10 { return String(format: "%.1f%%", p) }
    return String(format: "%.0f%%", p)
}

func fmtProgressBar(_ p: Double, cells: Int = 16) -> String {
    let filled = max(0, min(cells, Int(p / 100.0 * Double(cells))))
    return String(repeating: "▓", count: filled) + String(repeating: "░", count: cells - filled)
}

func fmtCountdown(_ to: Date?) -> String {
    guard let to else { return "" }
    let iv = Int(to.timeIntervalSinceNow)
    if iv <= 0 { return "即将重置" }
    let d = iv / 86400, h = iv % 86400 / 3600, m = iv % 3600 / 60
    if d > 0 { return "\(d)天\(h)小时后" }
    if h > 0 { return "\(h)小时\(m)分后" }
    return "\(m)分钟后"
}

let resetDateFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "M月d日 HH:mm"
    return f
}()

func fmtWindowLabel(_ raw: String?) -> String {
    switch raw {
    case "5h": return "5小时"
    case "1d": return "1天"
    case "7d": return "7天"
    case "30d": return "30天"
    case .some(let s): return s
    case nil: return "窗口"
    }
}

// MARK: - SQLite 只读读取

final class DBReader {
    private var handle: OpaquePointer?
    private var lastGood = Snapshot()

    private static let transient = unsafeBitCast(
        OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

    private func open() -> Bool {
        if handle != nil { return true }
        var db: OpaquePointer?
        let uri = "file:" + dbPath + "?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, db != nil else {
            sqlite3_close(db)
            return false
        }
        sqlite3_busy_timeout(db, 300)
        handle = db
        return true
    }

    func close() {
        if let h = handle { sqlite3_close(h) }
        handle = nil
    }

    @discardableResult
    private func query(_ sql: String, bind: [(Int, Any)] = [],
                       row: (OpaquePointer) -> Void) -> Bool {
        guard open() else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in bind {
            switch v {
            case let n as Int: sqlite3_bind_int64(stmt, Int32(i), Int64(n))
            case let d as Double: sqlite3_bind_double(stmt, Int32(i), d)
            case let s as String: sqlite3_bind_text(stmt, Int32(i), s, -1, Self.transient)
            default: break
            }
        }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt!) }
        return true
    }

    private func totals(since: Int) -> Totals? {
        var t = Totals()
        let ok = query(
            """
            SELECT COUNT(*),
                   COALESCE(SUM(CAST(total_cost_usd AS REAL)),0),
                   COALESCE(SUM(output_tokens),0),
                   COALESCE(SUM(input_tokens+cache_read_tokens+cache_creation_tokens),0)
            FROM proxy_request_logs WHERE created_at >= ?
            """, bind: [(1, since)]) { r in
            t.requests = Int(sqlite3_column_int64(r, 0))
            t.cost = sqlite3_column_double(r, 1)
            t.outTokens = Int(sqlite3_column_int64(r, 2))
            t.inTokens = Int(sqlite3_column_int64(r, 3))
        }
        return ok ? t : nil
    }

    private func named(_ sql: String, since: Int, nameIndex: Int32 = 0) -> [NamedRow] {
        var out: [NamedRow] = []
        query(sql, bind: [(1, since)]) { r in
            out.append(NamedRow(
                name: (sqlite3_column_text(r, nameIndex).map {
                    String(cString: $0)
                } ?? "(未知)"),
                requests: Int(sqlite3_column_int64(r, nameIndex + 1)),
                cost: sqlite3_column_double(r, nameIndex + 2),
                outTokens: Int(sqlite3_column_int64(r, nameIndex + 3)),
                inTokens: Int(sqlite3_column_int64(r, nameIndex + 4))))
        }
        return out
    }

    func fetch() -> Snapshot {
        let cal = Calendar.current
        let now = Date()
        let dayStart = Int(cal.startOfDay(for: now).timeIntervalSince1970)
        let weekStart = Int(cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!.timeIntervalSince1970)
        let monthStart = Int(cal.date(from: cal.dateComponents([.year, .month], from: now))!.timeIntervalSince1970)

        var snap = Snapshot()
        var failed = false
        if let t = totals(since: dayStart) { snap.day = t } else { failed = true }
        snap.week = totals(since: weekStart) ?? Totals()
        snap.month = totals(since: monthStart) ?? Totals()

        snap.byApp = named(
            """
            SELECT app_type, COUNT(*), COALESCE(SUM(CAST(total_cost_usd AS REAL)),0),
                   COALESCE(SUM(output_tokens),0),
                   COALESCE(SUM(input_tokens+cache_read_tokens+cache_creation_tokens),0)
            FROM proxy_request_logs WHERE created_at >= ? GROUP BY app_type ORDER BY cost DESC
            """, since: dayStart)

        snap.byProvider = named(
            """
            SELECT COALESCE((SELECT name FROM providers WHERE id = l.provider_id LIMIT 1),'(未知)'),
                   COUNT(*), COALESCE(SUM(CAST(l.total_cost_usd AS REAL)),0),
                   COALESCE(SUM(l.output_tokens),0),
                   COALESCE(SUM(l.input_tokens+l.cache_read_tokens+l.cache_creation_tokens),0)
            FROM proxy_request_logs l WHERE l.created_at >= ? GROUP BY 1 ORDER BY cost DESC
            """, since: dayStart)

        snap.byModel = named(
            """
            SELECT model, COUNT(*), COALESCE(SUM(CAST(total_cost_usd AS REAL)),0),
                   COALESCE(SUM(output_tokens),0),
                   COALESCE(SUM(input_tokens+cache_read_tokens+cache_creation_tokens),0)
            FROM proxy_request_logs WHERE created_at >= ? GROUP BY model ORDER BY cost DESC LIMIT 6
            """, since: dayStart)

        query(
            """
            SELECT strftime('%H:%M', created_at, 'unixepoch', 'localtime'), model,
                   COALESCE(CAST(total_cost_usd AS REAL),0), COALESCE(output_tokens,0), status_code
            FROM proxy_request_logs ORDER BY created_at DESC LIMIT 5
            """) { r in
            snap.recent.append(RecentReq(
                time: String(cString: sqlite3_column_text(r, 0)),
                model: sqlite3_column_text(r, 1).map { String(cString: $0) } ?? "?",
                cost: sqlite3_column_double(r, 2),
                outTokens: Int(sqlite3_column_int64(r, 3)),
                failed: sqlite3_column_int64(r, 4) >= 400))
        }

        // 当日查询失败(如数据库被 cc-switch 短暂锁住)时沿用上次快照
        if failed {
            let fresh = Date().timeIntervalSince(lastGood.fetchedAt) < 86400
            if fresh && lastGood.day.requests + lastGood.week.requests > 0 { return lastGood }
            snap.dbError = "读取 ~/.cc-switch/cc-switch.db 失败(cc-switch 未运行?)"
        }
        lastGood = snap
        return snap
    }

    /// 当前 Claude Desktop 代理指向的供应商(name + base URL + 密钥)
    func proxyProvider() -> (name: String, baseURL: String, token: String)? {
        var result: (String, String, String)?
        query(
            """
            SELECT name, settings_config FROM providers
            WHERE app_type = 'claude-desktop' AND is_current = 1 LIMIT 1
            """) { r in
            guard let nameC = sqlite3_column_text(r, 0),
                  let cfgC = sqlite3_column_text(r, 1) else { return }
            let name = String(cString: nameC)
            let cfg = String(cString: cfgC)
            guard let data = cfg.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let env = obj["env"] as? [String: Any],
                  let token = env["ANTHROPIC_AUTH_TOKEN"] as? String else { return }
            var base = env["ANTHROPIC_BASE_URL"] as? String ?? ""
            while base.hasSuffix("/") { base.removeLast() }
            guard !base.isEmpty else { return }
            result = (name, base, token)
        }
        return result.map { (name: $0.0, baseURL: $0.1, token: $0.2) }
    }
}

// MARK: - sub2api 额度接口

private struct UsageResp: Decodable {
    struct RL: Decodable {
        let limit: Double
        let used: Double
        let remaining: Double?
        let window: String?
        let reset_at: String?
        let window_start: String?
    }
    struct Day: Decodable {
        let cost: Double?
        let requests: Int?
        let output_tokens: Int?
    }
    struct Usage: Decodable {
        let today: Day?
    }
    struct DailyUsage: Decodable {
        let date: String
        let requests: Int?
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_read_tokens: Int?
        let cache_write_tokens: Int?
        let cost: Double?
    }
    let rate_limits: [RL]?
    let usage: Usage?
    let daily_usage: [DailyUsage]?
}

enum QuotaFetcher {
    private static let iso = ISO8601DateFormatter()

    static func fetch(provider: (name: String, baseURL: String, token: String)) -> QuotaInfo? {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let today = df.string(from: Date())

        var comps = URLComponents(string: provider.baseURL + "/v1/usage")
        comps?.queryItems = [
            URLQueryItem(name: "start_date", value: today),
            URLQueryItem(name: "end_date", value: today),
            URLQueryItem(name: "days", value: "30"),
            URLQueryItem(name: "timezone", value: TimeZone.current.identifier),
        ]
        guard let url = comps?.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer " + provider.token, forHTTPHeaderField: "Authorization")

        let sem = DispatchSemaphore(value: 0)
        var data: Data?
        var err: Error?
        URLSession.shared.dataTask(with: req) { d, _, e in
            data = d; err = e; sem.signal()
        }.resume()
        sem.wait()
        if let e = err {
            FileHandle.standardError.write("quota fetch error: \(e.localizedDescription)\n".data(using: .utf8)!)
            return nil
        }
        guard let d = data else { return nil }

        // 非成功状态码直接放弃
        if let s = String(data: d, encoding: .utf8), s.contains("\"code\""), s.contains("error") {
            FileHandle.standardError.write("quota fetch rejected: \(s.prefix(120))\n".data(using: .utf8)!)
            return nil
        }
        guard let resp = try? JSONDecoder().decode(UsageResp.self, from: d),
              let rls = resp.rate_limits else {
            FileHandle.standardError.write("quota parse failed\n".data(using: .utf8)!)
            return nil
        }

        var wins: [QuotaWindow] = []
        for rl in rls {
            let pct = rl.limit > 0 ? rl.used / rl.limit * 100 : 0
            var reset: Date?
            if let s = rl.reset_at { reset = iso.date(from: s) }
            wins.append(QuotaWindow(
                label: fmtWindowLabel(rl.window),
                limit: rl.limit, used: rl.used, percent: pct, resetDate: reset,
                startDateStr: rl.window_start.map { String($0.prefix(10)) }))
        }
        var days: [DayUsage] = []
        for d in resp.daily_usage ?? [] {
            days.append(DayUsage(
                date: d.date,
                requests: d.requests ?? 0,
                cost: d.cost ?? 0,
                outTokens: d.output_tokens ?? 0,
                inTokens: (d.input_tokens ?? 0) + (d.cache_read_tokens ?? 0) + (d.cache_write_tokens ?? 0)))
        }
        days.sort { $0.date > $1.date } // 新的在前
        let todayCost = resp.usage?.today?.cost ?? 0
        let todayReq = resp.usage?.today?.requests ?? 0
        let todayOut = resp.usage?.today?.output_tokens ?? 0
        if wins.isEmpty && todayCost == 0 && days.isEmpty { return nil }
        return QuotaInfo(providerName: provider.name, windows: wins,
                         todayCost: todayCost, todayRequests: todayReq,
                         todayOutTokens: todayOut, days: days)
    }
}

// MARK: - 菜单栏应用

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let reader = DBReader()
    private var snapshot = Snapshot()
    private var quota: QuotaInfo?
    private var lastQuotaAttempt = Date.distantPast
    private var timer: Timer?

    private var titleMode: TitleMode {
        get { TitleMode(rawValue: UserDefaults.standard.string(forKey: "titleMode") ?? "") ?? .quotaPercent }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "titleMode") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusItem.button?.toolTip = "CC Usage Bar — cc-switch 用量 + 供应商额度"
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        reader.close()
    }

    private func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let snap = self.reader.fetch()

            var q = self.quota
            let stale = Date().timeIntervalSince(self.lastQuotaAttempt) > 60
            if stale, let p = self.reader.proxyProvider() {
                self.lastQuotaAttempt = Date()
                if let fetched = QuotaFetcher.fetch(provider: p) { q = fetched }
            }

            DispatchQueue.main.async {
                self.snapshot = snap
                self.quota = q
                self.updateTitle()
            }
        }
    }

    private func titleFallback() -> String { fmtCost(snapshot.day.cost) }

    private func currentTitleText(fallback: Bool = true) -> String {
        switch titleMode {
        case .cost: return fmtCost(snapshot.day.cost)
        case .costTokens: return "\(fmtCost(snapshot.day.cost)) ↑\(fmtTokens(snapshot.day.outTokens))"
        case .tokens: return "↑\(fmtTokens(snapshot.day.outTokens))"
        case .requests: return "\(snapshot.day.requests) 请求"
        case .quotaPercent:
            if let w = bestWindow() { return fmtPercent(w.percent) }
            return fallback ? titleFallback() : fmtCost(snapshot.day.cost)
        case .quotaMoney:
            if let w = bestWindow() { return "\(fmtMoney2(w.used))/\(fmtMoney2(w.limit))" }
            return fallback ? titleFallback() : fmtCost(snapshot.day.cost)
        }
    }

    /// 最紧迫(百分比最高)的窗口
    private func bestWindow() -> QuotaWindow? {
        quota?.windows.max { $0.percent < $1.percent }
    }

    private func updateTitle() {
        if let err = snapshot.dbError {
            statusItem.button?.title = "⚠️"
            statusItem.button?.toolTip = err
            return
        }
        statusItem.button?.title = currentTitleText()
        var tip = "今日 \(fmtCost(snapshot.day.cost)) · \(snapshot.day.requests) 请求"
        if let w = bestWindow() {
            tip += "\n额度 \(fmtPercent(w.percent)) · 重置 \(fmtCountdown(w.resetDate))"
        }
        statusItem.button?.toolTip = tip
    }

    // MARK: 菜单构建(每次打开菜单时重建)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let d = snapshot.day
        let appTitle: [String: String] = [
            "claude-desktop": "Claude Desktop", "claude": "Claude CLI",
            "codex": "Codex", "gemini": "Gemini", "dsh": "DSH", "grokbuild": "Grok Build",
        ]

        @discardableResult
        func line(_ text: String, indent: Int = 0) -> NSMenuItem {
            let it = NSMenuItem(title: String(repeating: "  ", count: indent) + text,
                                action: nil, keyEquivalent: "")
            it.isEnabled = false
            menu.addItem(it)
            return it
        }

        if let err = snapshot.dbError {
            line("数据库读取失败: \(err)")
            menu.addItem(.separator())
        }

        // 额度(供应商 /v1/usage)
        if let q = quota {
            let dayParse = DateFormatter(); dayParse.dateFormat = "yyyy-MM-dd"
            let dayShow = DateFormatter(); dayShow.dateFormat = "M月d日"
            for w in q.windows {
                line("🔌 \(q.providerName) 额度 · \(w.label)窗口")
                line("\(fmtProgressBar(w.percent))  \(fmtPercent(w.percent))", indent: 1)
                line("\(fmtMoney2(w.used)) / \(fmtMoney2(w.limit)) · 剩 \(fmtMoney2(max(0, w.limit - w.used)))", indent: 1)
                // 周期内总用量(窗口起始日至今,按天合计)
                let inPeriod = w.startDateStr.map { s in q.days.filter { $0.date >= s } } ?? q.days
                if !inPeriod.isEmpty {
                    let pcost = inPeriod.reduce(0.0) { $0 + $1.cost }
                    let preq = inPeriod.reduce(0) { $0 + $1.requests }
                    let pout = inPeriod.reduce(0) { $0 + $1.outTokens }
                    let pin = inPeriod.reduce(0) { $0 + $1.inTokens }
                    var startTxt = ""
                    if let s = w.startDateStr, let sd = dayParse.date(from: s) {
                        startTxt = "(\(dayShow.string(from: sd))起)"
                    }
                    line("周期内总用量\(startTxt):\(fmtMoney2(pcost)) · \(preq) 请求", indent: 1)
                    line("↑ 生成 \(fmtTokens(pout))   ↓ 输入(含缓存) \(fmtTokens(pin))", indent: 2)
                }
                if let r = w.resetDate {
                    line("重置于 \(resetDateFmt.string(from: r))(\(fmtCountdown(r)))", indent: 1)
                }
                menu.addItem(.separator())
            }
            line("今日用量  \(fmtMoney2(q.todayCost)) · \(q.todayRequests) 请求 · ↑\(fmtTokens(q.todayOutTokens)) 生成", indent: 1)
            let recentDays = q.days.prefix(5)
            if recentDays.count > 1 {
                line("每日明细", indent: 1)
                for d in recentDays {
                    if let dd = dayParse.date(from: d.date) {
                        line("\(dayShow.string(from: dd))  \(fmtMoney2(d.cost)) · \(d.requests) 请求 · ↑\(fmtTokens(d.outTokens))", indent: 2)
                    }
                }
            }
            menu.addItem(.separator())
        }

        line("📅 今日  \(fmtCost(d.cost)) · \(d.requests) 请求")
        line("   ↑ 生成 \(fmtTokens(d.outTokens))   ↓ 输入(含缓存) \(fmtTokens(d.inTokens))")
        line("🗓 本周  \(fmtCost(snapshot.week.cost)) · \(snapshot.week.requests) 请求")
        line("🗓 本月  \(fmtCost(snapshot.month.cost)) · \(snapshot.month.requests) 请求")
        menu.addItem(.separator())

        if !snapshot.byApp.isEmpty {
            line("今日 · 按应用")
            for r in snapshot.byApp {
                line("\(appTitle[r.name] ?? r.name)  \(fmtCost(r.cost)) · \(r.requests) 次", indent: 1)
            }
        }
        if !snapshot.byProvider.isEmpty {
            menu.addItem(.separator())
            line("今日 · 按供应商")
            for r in snapshot.byProvider {
                line("\(r.name)  \(fmtCost(r.cost)) · \(r.requests) 次", indent: 1)
            }
        }
        if !snapshot.byModel.isEmpty {
            menu.addItem(.separator())
            line("今日 · 模型 Top")
            for r in snapshot.byModel {
                line("\(r.name)  \(fmtCost(r.cost)) · ↑\(fmtTokens(r.outTokens))", indent: 1)
            }
        }
        if !snapshot.recent.isEmpty {
            menu.addItem(.separator())
            line("最近请求")
            for r in snapshot.recent {
                let flag = r.failed ? "⚠️" : "✓"
                line("\(r.time)  \(flag) \(r.model)  ↑\(fmtTokens(r.outTokens)) \(fmtCost(r.cost))", indent: 1)
            }
        }

        menu.addItem(.separator())

        // 显示模式子菜单(单选)
        let display = NSMenu()
        for m in TitleMode.allCases {
            let it = NSMenuItem(title: m.rawValue, action: #selector(switchTitleMode(_:)),
                                keyEquivalent: "")
            it.target = self
            it.state = (m == titleMode) ? .on : .off
            it.representedObject = m.rawValue
            display.addItem(it)
        }
        let displayItem = NSMenuItem(title: "菜单栏显示", action: nil, keyEquivalent: "")
        displayItem.submenu = display
        menu.addItem(displayItem)

        let refreshIt = NSMenuItem(title: "立即刷新", action: #selector(doRefresh), keyEquivalent: "r")
        refreshIt.target = self
        refreshIt.keyEquivalentModifierMask = []
        menu.addItem(refreshIt)

        let quit = NSMenuItem(title: "退出 CCUsageBar", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        menu.addItem(quit)
    }

    @objc func switchTitleMode(_ sender: NSMenuItem) {
        titleMode = TitleMode(rawValue: sender.representedObject as? String ?? "") ?? .quotaPercent
        updateTitle()
    }

    @objc func doRefresh() {
        lastQuotaAttempt = .distantPast // 强制重新拉额度
        refresh()
    }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // 不占 Dock
app.run()
