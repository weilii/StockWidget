import AppKit
import Combine
import MarketCore

@MainActor
final class AppStore: ObservableObject {
    @Published var assets: [Asset] = []
    @Published var quotes: [String: Quote] = [:]
    @Published var errors: [String: String] = [:]
    @Published var preferences = Preferences() {
        didSet {
            guard ready else { return }
            let timingChanged = preferences.cryptoSource != oldValue.cryptoSource || preferences.refreshMinutes != oldValue.refreshMinutes
            if timingChanged {
                nextDue = [:]
                // Old data remains visibly old until a complete response from the new source arrives.
            }
            persist(); onPreferencesChanged?()
            if timingChanged { restartLoop() }
        }
    }
    @Published var isRefreshing = false
    @Published var selectedAsset: Asset?
    @Published var showingSearch = false
    @Published var showingSettings = false
    @Published var storageError: String?
    @Published var connectionResults: [ConnectionResult] = []
    @Published var isDiagnosing = false
    @Published var lastRefresh: Date?
    var draggedAsset: String?
    var onPreferencesChanged: (() -> Void)?
    var onWatchlistChanged: (() -> Void)?
    var onReturnToWatchlist: (() -> Void)?
    var onPrepareWindowDrag: (() -> Void)?
    var onBeginWindowDrag: ((NSEvent) -> Void)?
    var onFinishWindowDrag: (() -> Void)?
    var windowVisible = true {
        didSet {
            if oldValue != windowVisible {
                if windowVisible { nextDue = [:] }
                restartLoop()
            }
        }
    }
    var suspended = false {
        didSet { if oldValue != suspended { if !suspended { nextDue = [:] }; restartLoop() } }
    }
    let service = MarketService()
    private let file: StateFile
    private var ready = false
    private var running = false
    private var nextDue: [String: Date] = [:]
    private var loop: Task<Void, Never>?
    private var diagnosedAt: Date?

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("StockWidget", isDirectory: true)
        file = StateFile(url: base.appendingPathComponent("state.json"))
        do {
            let state = try file.load()
            assets = state.assets; quotes = state.quotes; preferences = state.preferences
            if ![1, 5, 15].contains(preferences.refreshMinutes) { preferences.refreshMinutes = 1 }
        } catch {
            storageError = "Saved data could not be read: \(error.localizedDescription)"
            if FileManager.default.fileExists(atPath: file.url.path) {
                do {
                    let backup = file.url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
                    try FileManager.default.copyItem(at: file.url, to: backup)
                } catch { storageError = "Saved data could not be backed up. Changes will not be saved: \(error.localizedDescription)"; return }
            }
        }
        ready = true
    }
    var isChinese: Bool { preferences.language == .zh }
    func t(_ english: String) -> String { isChinese ? (translations[english] ?? english) : english }
    var stateLocation: String { file.url.path }

    func start() { running = true; restartLoop() }
    func restartLoop() {
        loop?.cancel()
        guard ready, running, !suspended else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.isRefreshing {
                    do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                    continue
                }
                await self.refresh(force: false)
                if Task.isCancelled { return }
                let soonest = self.assets.compactMap { self.nextDue[$0.id] }.min() ?? Date().addingTimeInterval(300)
                let wait = max(5, min(900, soonest.timeIntervalSinceNow))
                do { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) } catch { return }
            }
        }
    }
    func add(_ asset: Asset) {
        guard !assets.contains(where: { $0.id == asset.id }) else { return }
        assets.append(asset); persist(); onWatchlistChanged?(); restartLoop()
    }
    func remove(_ asset: Asset) {
        assets.removeAll { $0.id == asset.id }; quotes.removeValue(forKey: asset.id)
        errors.removeValue(forKey: asset.id); nextDue.removeValue(forKey: asset.id)
        if selectedAsset?.id == asset.id { selectedAsset = nil }
        persist(); onWatchlistChanged?()
    }
    func move(_ id: String, before other: String) {
        guard let source = assets.firstIndex(where: { $0.id == id }), let target = assets.firstIndex(where: { $0.id == other }), source != target else { return }
        let item = assets.remove(at: source); assets.insert(item, at: target); persist()
    }
    func step(_ asset: Asset, by offset: Int) {
        guard let index = assets.firstIndex(of: asset), assets.indices.contains(index + offset) else { return }
        assets.swapAt(index, index + offset); persist()
    }
    func persist() {
        guard ready else { return }
        do { try file.save(SavedState(assets: assets, preferences: preferences, quotes: quotes)); storageError = nil }
        catch { storageError = error.localizedDescription }
    }
    func refresh(force: Bool) async {
        guard !isRefreshing, !suspended else { return }
        let now = Date()
        let due = assets.filter { force || (nextDue[$0.id] ?? .distantPast) <= now }
        guard !due.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false; persist() }
        let source = preferences.cryptoSource
        let snapshots = quotes
        // Bound concurrent symbols; HTTPClient also spaces requests to each service.
        await withTaskGroup(of: (Asset, Result<Quote, Error>).self) { group in
            var iterator = due.makeIterator()
            func submit(_ asset: Asset) {
                group.addTask { [service] in
                    do { return (asset, .success(try await service.quote(for: asset, crypto: source, previous: snapshots[asset.id], forceChart: force))) }
                    catch { return (asset, .failure(error)) }
                }
            }
            for _ in 0..<min(3, due.count) { if let asset = iterator.next() { submit(asset) } }
            for await (asset, result) in group {
                if assets.contains(where: { $0.id == asset.id }), source == preferences.cryptoSource || asset.market != .crypto {
                    switch result {
                    case .success(let quote): quotes[asset.id] = quote; errors.removeValue(forKey: asset.id)
                    case .failure(let error):
                        if !(error is CancellationError) { errors[asset.id] = error.localizedDescription }
                    }
                    let session = TradingHours.estimated(asset.market)
                    let normal = preferences.interval(visible: windowVisible)
                    var interval = session == .closed ? max(900, normal) : (session == .breakTime ? max(300, normal) : normal)
                    if session == .closed || session == .breakTime, let open = TradingHours.nextOpen(asset.market, after: Date()) {
                        interval = min(interval, max(5, open.timeIntervalSinceNow + 2))
                    }
                    nextDue[asset.id] = Date().addingTimeInterval(interval)
                }
                if let asset = iterator.next() { submit(asset) }
            }
        }
        lastRefresh = Date()
    }
    func refreshNow() { Task { await refresh(force: true); restartLoop() } }
    func diagnose() {
        guard !isDiagnosing else { return }
        isDiagnosing = true; connectionResults = []
        Task {
            connectionResults = await service.diagnose(); diagnosedAt = Date(); isDiagnosing = false
        }
    }
    func diagnosticsText() -> String {
        var lines = ["StockWidget connection report", "Tested: \((diagnosedAt ?? Date()).ISO8601Format())", "Only the current network was tested. Mainland China availability is not certified.", ""]
        lines += connectionResults.map { "\($0.success ? "PASS" : "FAIL") \($0.name): \($0.detail)" }
        return lines.joined(separator: "\n")
    }
}

private let translations: [String: String] = [
    "Watchlist": "自选行情", "Your markets, at a glance.": "一眼掌握，市场动态。", "Add symbol": "添加标的",
    "Refresh": "刷新", "Settings": "设置", "No symbols yet": "还没有自选标的", "A little window into your markets.": "用一个小窗口，关注你的市场。",
    "Search stocks and crypto to start your watchlist.": "搜索股票或加密货币，开始建立自选列表。", "Add your first symbol": "添加第一个标的",
    "SYMBOL": "标的", "TODAY / 24H": "当日 / 24 小时", "PRICE / CHANGE": "价格 / 涨跌幅",
    "symbols": "个标的", "Updating…": "更新中…", "Waiting for data": "等待行情", "Not updated yet": "尚未更新",
    "Session estimate": "交易时段估计", "Market hours": "交易时段", "Outside regular hours": "常规交易时段外", "Trading break": "午间休市", "24h market": "全天市场",
    "Stale": "数据较旧", "Offline": "获取失败", "Cached": "缓存", "History unavailable": "走势暂不可用", "Remove": "删除",
    "Move up": "上移", "Move down": "下移", "Done": "完成", "Cancel": "取消", "Search": "搜索", "All markets": "全部市场",
    "Reorder symbols": "调整自选顺序", "Done reordering": "完成排序", "Drag to reorder": "拖动手柄调整顺序",
    "China": "沪深", "Stock": "股票", "Index": "指数",
    "US markets": "美股", "US stocks": "美股", "A-shares": "A 股", "HK stocks": "港股", "Crypto": "加密货币", "Name or symbol": "名称或代码",
    "Search by name or ticker": "输入名称或代码搜索", "Try AAPL, 600519, 00700, or BTC.": "试试 AAPL、600519、00700 或 BTC。",
    "No matching symbols": "没有匹配的标的", "Try another symbol or select a market.": "尝试其他代码，或指定市场。", "Added": "已添加", "Add": "添加",
    "Searching…": "搜索中…", "Search failed": "搜索失败", "Try again": "重试", "General": "通用", "Language": "界面语言",
    "Appearance follows your Mac.": "外观跟随 Mac 的深浅色设置。", "Refresh interval": "刷新间隔", "1 minute": "1 分钟", "5 minutes": "5 分钟", "15 minutes": "15 分钟",
    "Always on top": "始终置顶", "Red up, green down": "红涨绿跌", "Launch at login": "登录后自动启动", "Open Login Items": "打开登录项设置",
    "Stays on one desktop. Always on top floats above apps on that desktop.": "固定于所在桌面；开启始终置顶后，浮于该桌面的其他应用窗口上方。",
    "Data & connection": "数据与网络", "Crypto source": "加密货币数据源", "Automatic · USD / USDT": "自动 · USD / USDT",
    "Uses your Mac’s network and proxy settings. A VPN may be needed for crypto.": "使用 Mac 的网络与代理设置；加密货币行情可能需要 VPN。",
    "Stock feeds are unofficial. Availability and delays can change.": "股票行情使用非正式接口，可用性与延迟可能变化。",
    "Mainland connectivity has not been verified.": "尚未验证中国大陆网络可达性。", "Test connections": "检测连接", "Testing…": "检测中…",
    "Copy report": "复制报告", "Connectivity tests use this network only; successful HTTP responses do not certify data freshness.": "检测仅代表当前网络；HTTP 成功不等于报价及时。",
    "Data is saved locally on this Mac.": "数据保存在当前 Mac。", "Show data folder": "显示数据文件夹", "Could not save changes": "无法保存更改",
    "Source": "来源", "Pair": "代码 / 交易对", "Currency": "计价单位", "Quote time": "报价时间", "Last successful request": "最近成功获取",
    "Chart updated": "历史曲线获取时间", "Previous close": "前收盘价", "24h reference": "24 小时基准价", "Open": "开盘价", "24h high": "24 小时最高",
    "24h low": "24 小时最低", "High": "最高价", "Low": "最低价", "Change": "涨跌额", "Intraday": "当日分时", "Last 24 hours": "最近 24 小时",
    "No chart data": "暂无走势数据", "Quote unavailable": "暂无行情", "Refresh to try again. Previous data stays visible when a feed fails.": "刷新以重试。数据源失败时会保留之前的行情。",
    "Quote age exceeds 5 minutes during expected trading hours.": "在预计交易时段内，报价已超过 5 分钟。",
    "Hours are a weekday estimate, not an exchange holiday calendar.": "时段按工作日估计，未包含完整交易所节假日日历。",
    "Show Watchlist": "显示自选行情", "Hide Watchlist": "隐藏自选行情", "Quit StockWidget": "退出 StockWidget", "Saved data issue": "本地数据问题",
    "Unavailable": "不可用", "Unknown": "未知", "Last checked": "最近检查", "Source changed": "数据源已切换"
]
