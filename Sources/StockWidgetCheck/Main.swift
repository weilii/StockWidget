import Foundation
import MarketCore

enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case .failed(let text): return text } }
}

@main
struct Checks {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckFailure.failed(message) }
    }
    static func json(_ string: String) -> Data { Data(string.utf8) }
    static func main() async {
        setbuf(stdout, nil)
        do { try await run() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }
    static func run() async throws {
        let us = Asset(market: .us, symbol: "AAPL", name: "Apple")
        let cn = Asset(market: .cn, symbol: "600519", name: "茅台", lookup: "sh600519")
        let hk = Asset(market: .hk, symbol: "00700", name: "腾讯", lookup: "hk00700")
        let btc = Asset(market: .crypto, symbol: "BTC", name: "Bitcoin")
        try expect(Asset(market: .cn, symbol: "688836", name: "宇树科技W").displayName == "宇树科技-W", "Chinese listing suffix should display consistently")
        try expect(Asset(market: .hk, symbol: "01879", name: "曦智科技p").displayName == "曦智科技-P", "HK suffix casing should display consistently")
        try expect(Asset(market: .us, symbol: "SNAP", name: "Snap").displayName == "Snap", "English company names must not be rewritten as listing suffixes")
        let now = FeedParsing.isoDate("2026-11-19T04:00:00Z")!
        var f = Array(repeating: "", count: 35)
        f[1] = "茅台"; f[3] = "1450.99"; f[4] = "1442.66"; f[5] = "1442"; f[30] = "20261119120000"; f[33] = "1459.74"; f[34] = "1432.10"
        let cq = try FeedParsing.tencentQuote(json("v_sh600519=\"" + f.joined(separator: "~") + "\";"), asset: cn, now: now)
        try expect(cq.price == 1450.99 && cq.currency == "CNY", "CN quote currency/price")
        try expect(cq.quotedAt == now, "CN source timestamp must use exchange timezone")
        try expect(abs(cq.percent! - 0.5774) < 0.001, "CN change must use previous close")
        f[30] = "2026/11/19 12:00:00"
        let hq = try FeedParsing.tencentQuote(json("v_r_hk00700=\"" + f.joined(separator: "~") + "\";"), asset: hk, now: now)
        try expect(hq.currency == "HKD" && hq.quotedAt == now, "HK timestamp and currency")
        do { _ = try FeedParsing.tencentQuote(json("v_sh600519=\"\";"), asset: cn); throw CheckFailure.failed("Empty quote accepted") }
        catch is FeedError {}
        let points = try FeedParsing.tencentPoints(json("""
        {"data":{"sh600519":{"data":{"date":"20261119","data":["0931 12.0 1","0930 11.0 1","0931 13.0 1","0932 0 1","bad"]}}}}
        """), asset: cn)
        try expect(points.count == 2 && points[1].value == 13, "History must sort, de-duplicate and reject zero prices")
        let yq = try FeedParsing.yahoo(json("""
        {"chart":{"result":[{"meta":{"currency":"USD","regularMarketPrice":105,"chartPreviousClose":100,"regularMarketTime":1795035600,"regularMarketDayHigh":106,"regularMarketDayLow":99},"timestamp":[100,200,300],"indicators":{"quote":[{"close":[100,null,105],"open":[null,102,104]}]}}]}}
        """), asset: us, now: now)
        try expect(yq.percent == 5 && yq.points.count == 2 && yq.open == 102, "Yahoo sparse history and previous-close basis")
        try expect(yq.quotedAt != yq.fetchedAt, "Fetching must never manufacture quote freshness")
        do {
            _ = try FeedParsing.yahoo(json("{\"chart\":{\"result\":[{\"meta\":{\"currency\":\"EUR\",\"regularMarketPrice\":12}}]}}"), asset: us)
            throw CheckFailure.failed("Currency mismatch accepted")
        } catch is FeedError {}
        let bq = try FeedParsing.binance(json("""
        {"lastPrice":"110","openPrice":"100","highPrice":"112","lowPrice":"95","closeTime":1795060800000}
        """), asset: btc, now: now)
        try expect(bq.currency == "USDT" && bq.pair == "BTCUSDT" && bq.percent == 10, "Binance must retain USDT and rolling reference")
        let okb = Asset(market: .crypto, symbol: "OKB", name: "OKB")
        let okxTicker = json("""
        {"code":"0","data":[{"instType":"SPOT","instId":"OKB-USDT","last":"110","open24h":"100","high24h":"115","low24h":"95","sodUtc0":"99","sodUtc8":"98","ts":"1795060800000"}]}
        """)
        let oq = try FeedParsing.okx(okxTicker, asset: okb, now: now)
        try expect(oq.currency == "USDT" && oq.pair == "OKB-USDT" && oq.source == "OKX" && oq.percent == 10 && oq.open == 100 && oq.quotedAt == now, "OKX must use rolling open24h, USDT and the source timestamp")
        for bad in [String(decoding: okxTicker, as: UTF8.self).replacingOccurrences(of: "OKB-USDT", with: "BTC-USDT"), String(decoding: okxTicker, as: UTF8.self).replacingOccurrences(of: "SPOT", with: "SWAP"), #"{"code":"51001","msg":"Instrument does not exist","data":[]}"#] {
            do {
                _ = try FeedParsing.okx(json(bad), asset: okb, now: now)
                throw CheckFailure.failed("Wrong OKX pair/type or API error accepted")
            } catch is FeedError {}
        }
        let okxCatalog = try FeedParsing.okxInstruments(json("""
        {"code":"0","data":[
          {"instType":"SPOT","instId":"OKB-USDT","baseCcy":"OKB","quoteCcy":"USDT","state":"live"},
          {"instType":"SPOT","instId":"OKB-USDT","baseCcy":"OKB","quoteCcy":"USDT","state":"live"},
          {"instType":"SPOT","instId":"OKB-USD","baseCcy":"OKB","quoteCcy":"USD","state":"live"},
          {"instType":"SWAP","instId":"OKB-USDT-SWAP","baseCcy":"OKB","quoteCcy":"USDT","state":"live"},
          {"instType":"SPOT","instId":"HALT-USDT","baseCcy":"HALT","quoteCcy":"USDT","state":"suspend"},
          {"instType":"SPOT","instId":"BTC-USDT","baseCcy":"OKB","quoteCcy":"USDT","state":"live"}
        ]}
        """))
        try expect(okxCatalog == [okb], "OKX search must retain only live matching USDT spot pairs and de-duplicate")
        let okxHistory = try FeedParsing.okxPoints(json("""
        {"code":"0","data":[["1795060500000","100","120","90","110"],["1795060200000","99","115","89","105"],["1","1","2","1","2"],["1795060890000","1","2","1","2"],["1795060400000","1","2","1","0"]]}
        """), now: now)
        try expect(okxHistory.count == 2 && okxHistory[0].value == 105 && okxHistory[1].value == 110, "OKX candles must use close values, sort and crop invalid/old/future samples")
        try expect(CryptoSource.automatic.providers(previousSource: "OKX") == [.okx, .coinbase, .binance] && CryptoSource.binance.providers(previousSource: "OKX") == [.binance], "Automatic sources must remember OKX; explicit choices must never silently switch")
        let oldSource = try JSONDecoder().decode(CryptoSource.self, from: json("\"coinbase\""))
        try expect(oldSource == .coinbase, "Old source preferences must remain readable")
        let cb = try FeedParsing.coinbase(ticker: json("{\"price\":\"120\",\"time\":\"2026-11-19T04:00:00.123456789Z\"}"), stats: json("{\"open\":\"100\",\"high\":\"125\",\"low\":\"90\"}"), asset: btc, now: now)
        try expect(cb.currency == "USD" && cb.percent == 20 && cb.quotedAt != nil, "Coinbase ISO timestamp and 24h reference")
        let candles = try FeedParsing.coinbasePoints(json("[[1795060500,95,120,100,110,1],[1795060200,94,115,99,105,1],[1,1,2,1,2,1]]"), now: now)
        try expect(candles.count == 2 && candles[0].value == 105 && candles[1].value == 110, "24h chart must use close column, chronological order and crop old points")
        try expect(FeedParsing.number("NaN") == nil && FeedParsing.number(true) == nil, "Invalid numeric values must be rejected")
        let search = try FeedParsing.tencentSearch(json("v_hint=\"us~aapl.oq~Apple~pg~GP^hk~00700~Tencent~tx~GP^sh~600519~Moutai~mt~GP-A^sh~000001~Index~idx~ZS\""))
        try expect(search.count == 4 && search[0].lookup == "AAPL" && search[1].lookup == "hk00700" && search[3].instrumentKind == .index, "Search must map exchanges and include supported mainland indices")
        let starSearch = try FeedParsing.tencentSearch(json(#"v_hint="sh~688836~\u5b87\u6811\u79d1\u6280W~yskjw~GP-A-KCB""#))
        try expect(starSearch.count == 1 && starSearch[0].lookup == "sh688836" && starSearch[0].name == "宇树科技W", "STAR Market stock and escaped Chinese name must survive search filtering")
        let boardSearch = try FeedParsing.tencentSearch(json("v_hint=\"sh~688836~Unitree~ys~GP-A-KCB^sz~300001~Growth stock~gs~GP-A-CYB^sh~688836~Unitree duplicate~ys~GP-A-KCB^sh~000001~Index~idx~ZS^sh~510300~ETF~etf~ETF^sz~000999~Unrelated type~u~GP-ALIEN\""))
        try expect(boardSearch.count == 3 && boardSearch.map(\.market) == [.cn, .cn, .cn], "Board variants and indices must be accepted and de-duplicated; funds and unrelated types stay filtered")
        let overlappingCodes = try FeedParsing.tencentSearch(json("v_hint=\"sh~000001~上证指数~szzs~ZS^sz~000001~平安银行~payh~GP-A^jj~000001~基金~jj~KJ\""))
        try expect(overlappingCodes.count == 2 && Set(overlappingCodes.map(\.id)).count == 2, "Exchange-qualified IDs must retain both 000001 results")
        try expect(overlappingCodes[0].displayCode == "SH000001" && overlappingCodes[0].instrumentKind == .index && overlappingCodes[1].displayCode == "SZ000001", "Search must distinguish SSE index from SZSE stock")
        let indexQuote = try FeedParsing.tencentQuote(json("v_sh000001=\"" + f.joined(separator: "~") + "\";"), asset: overlappingCodes[0], now: now)
        try expect(indexQuote.currency == "PTS", "Index levels must be displayed as points, not currency")
        let legacy = try JSONDecoder().decode(Asset.self, from: json("{\"market\":\"cn\",\"symbol\":\"000001\",\"name\":\"平安银行\",\"lookup\":\"sz000001\"}"))
        try expect(legacy.instrumentKind == .stock && legacy.id == overlappingCodes[1].id, "Existing watchlists must remain readable when instrument kinds are added")
        let composite = USIndexCatalog.exactMatch("IXIC")!
        let nasdaq100 = USIndexCatalog.exactMatch("NDX")!
        for alias in ["ixic", "^IXIC", ".IXIC", "INDEXNASDAQ: .IXIC", ".IXIC:INDEXNASDAQ", "纳斯达克综合指数", "Nasdaq Composite"] {
            try expect(USIndexCatalog.exactMatch(alias) == composite, "Composite alias must resolve to the same index: \(alias)")
        }
        try expect(composite.lookup == "^IXIC" && composite.instrumentKind == .index && composite.priceUnit == "PTS", "Composite must use Yahoo's index symbol and points")
        try expect(nasdaq100.lookup == "^NDX" && nasdaq100.id != composite.id, "Nasdaq-100 must remain distinct from the Nasdaq Composite")
        try expect(USIndexCatalog.matches("纳斯达克").map(\.lookup) == ["^IXIC", "^NDX"], "Broad Nasdaq search must distinguish the two indices")
        try expect(USIndexCatalog.exactMatch("NDAQ") == nil && USIndexCatalog.matches("").isEmpty, "The listed company must not be aliased to an index")
        let nasdaqSearch = try FeedParsing.tencentSearch(json("v_hint=\"us~ixic~纳斯达克~nsdk~ZS^us~ndaq.oq~纳斯达克~nsdk~GP^us~ndx~纳斯达克100~nsdk100~ZS^us~ixic~重复指数~nsdk~ZS^us~unknown~Unsupported index~u~ZS\""))
        try expect(nasdaqSearch.map(\.lookup) == ["^IXIC", "NDAQ", "^NDX"] && nasdaqSearch.map(\.instrumentKind) == [.index, .stock, .index], "US search must map supported indices, keep NDAQ as stock, de-duplicate and exclude unmapped indices")
        let indexData = json("""
        {"chart":{"result":[{"meta":{"symbol":"^IXIC","instrumentType":"INDEX","currency":"USD","regularMarketPrice":105,"chartPreviousClose":100,"regularMarketTime":1795035600},"timestamp":[100,200],"indicators":{"quote":[{"close":[100,105],"open":[101,104]}]}}]}}
        """)
        let compositeQuote = try FeedParsing.yahoo(indexData, asset: composite, now: now)
        try expect(compositeQuote.currency == "PTS" && compositeQuote.percent == 5 && compositeQuote.points.count == 2 && compositeQuote.quotedAt != nil, "Yahoo index parsing must preserve points, previous close, source time and history")
        for (data, asset) in [(indexData, nasdaq100), (json(String(decoding: indexData, as: UTF8.self).replacingOccurrences(of: "INDEX", with: "EQUITY")), composite)] {
            do {
                _ = try FeedParsing.yahoo(data, asset: asset, now: now)
                throw CheckFailure.failed("Incorrect index identity or stock response accepted")
            } catch is FeedError {}
        }
        var old = cb; old.quotedAt = now.addingTimeInterval(-600)
        try expect(old.isStale(now: now), "Old active-session quote must be marked stale")
        old.session = .closed
        try expect(!old.isStale(now: now), "An ordinary closed session is not a quote failure")
        try expect(old.isStale(now: now.addingTimeInterval(1800)), "Old cached requests must remain visibly old even off-hours")
        var prefs = Preferences(); prefs.refreshMinutes = 15
        try expect(prefs.interval(visible: false) == 900, "Hiding must not increase a slower user's refresh frequency")
        prefs.refreshMinutes = 1
        try expect(prefs.interval(visible: true) == 60 && prefs.interval(visible: false) == 300, "Visible/hidden refresh policy")
        let beforeOpen = FeedParsing.isoDate("2026-11-19T14:29:00Z")!
        try expect(TradingHours.nextOpen(.us, after: beforeOpen)?.timeIntervalSince(beforeOpen) == 60, "Off-hours scheduling must wake for the next regular open")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("StockWidgetCheck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = StateFile(url: tmp.appendingPathComponent("state.json"))
        let initial = try file.load()
        try expect(initial.assets.isEmpty, "First launch must be empty")
        prefs.language = .zh
        try file.save(SavedState(assets: [btc, us, hk, cn], preferences: prefs, quotes: [btc.id: bq]))
        let loaded = try file.load()
        try expect(loaded.assets == [btc, us, hk, cn] && loaded.preferences.language == .zh && loaded.quotes[btc.id]?.currency == "USDT", "Persistence must preserve ordering, preferences, quote source and units")
        var pointer = PointerIntent()
        pointer.begin(at: .zero); pointer.move(to: CGPoint(x: 2, y: 1))
        try expect(pointer.end(at: CGPoint(x: 2, y: 1)), "A small click jitter must still open details")
        pointer.begin(at: .zero)
        try expect(pointer.move(to: CGPoint(x: 20, y: 0)), "A drag must cross the click threshold")
        pointer.move(to: .zero)
        try expect(!pointer.end(at: .zero), "Dragging out and back must never turn into a click on release")
        pointer.begin(at: .zero)
        try expect(!pointer.end(at: CGPoint(x: 40, y: 0)) && !pointer.end(at: .zero), "A fast drag release or an orphan mouse-up must not open details")
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let neighbor = CGRect(x: 16, y: 700, width: 344, height: 164)
        let below = WindowSnapping.frame(CGRect(x: 22, y: 450, width: 360, height: 232), in: screen, neighbors: [neighbor])
        try expect(below.minX == neighbor.minX && neighbor.minY - below.maxY == 16, "A nearby widget must align to the same column and a consistent 16pt gap")
        let free = CGRect(x: 512, y: 400, width: 360, height: 232)
        try expect(WindowSnapping.frame(free, in: screen, neighbors: []) == free, "A release away from guides must stay where the user placed it")
        let corner = WindowSnapping.frame(CGRect(x: 1060, y: 650, width: 360, height: 232), in: screen, neighbors: [])
        try expect(corner.maxX == 1424 && corner.maxY == 884, "Screen-edge snaps must respect the usable area and inset")
        let secondary = WindowSnapping.frame(CGRect(x: -1910, y: 400, width: 360, height: 232), in: CGRect(x: -1920, y: 0, width: 1920, height: 1080), neighbors: [])
        try expect(secondary.minX == -1904, "Snapping must support displays with negative global coordinates")
        let spring = (0...100).map { WindowSnapping.springProgress(Double($0) / 100) }
        try expect(spring.first == 0 && spring.last == 1 && spring.allSatisfy { $0.isFinite && $0 >= 0 && $0 < 1.2 } && spring.contains { $0 > 1 }, "The spring must have a bounded overshoot and settle exactly")
        print("PASS: offline parsing, units, timestamps, sparse charts, search mapping, refresh policy and persistence")
        print("PASS: index/stock identity, backward-compatible assets, drag-versus-click, screen/widget snapping and spring response")
        print("PASS: Nasdaq Composite aliases, Nasdaq-100 distinction, index quote identity and points")
        print("PASS: OKX spot catalog, pair/type validation, 24h reference, USDT, history and source selection")

        if CommandLine.arguments.contains("--live-okb") {
            let service = MarketService()
            for query in ["OKB", "OKB-USDT", "OKX", "okx", "欧易"] {
                let results = try await service.search(query, market: .crypto, cryptoSource: .automatic)
                try expect(results.filter { $0.id == okb.id }.count == 1, "Automatic OKB search failed: \(query)")
                print("PASS LIVE OKB SEARCH: \(query)")
            }
            let allMarkets = try await service.search("OKB", market: nil, cryptoSource: .automatic)
            try expect(allMarkets.contains { $0.id == okb.id }, "OKB must be found in all markets")
            let explicit = try await service.search("OKB", market: .crypto, cryptoSource: .okx)
            try expect(explicit.contains { $0.id == okb.id }, "Explicit OKX search")
            for source: CryptoSource in [.automatic, .okx] {
                let quote = try await service.quote(for: okb, crypto: source, forceChart: true)
                try expect(quote.price > 0 && quote.source == "OKX" && quote.currency == "USDT" && quote.pair == "OKB-USDT" && quote.reference != nil && quote.quotedAt != nil && quote.points.count > 1 && quote.chartError == nil, "Live OKB price/time/24h chart: \(source.rawValue)")
                print("PASS LIVE OKB QUOTE: \(source.rawValue) · \(quote.price) USDT · \(quote.points.count) points")
            }
        }

        if CommandLine.arguments.contains("--live-nasdaq-search") {
            let service = MarketService()
            for query in ["纳斯达克综合指数", "IXIC", "^IXIC", ".IXIC", "INDEXNASDAQ: .IXIC", ".IXIC:INDEXNASDAQ", "Nasdaq Composite"] {
                for market: Market? in [nil, .us] {
                    let results = try await service.search(query, market: market, cryptoSource: .automatic)
                    try expect(results == [composite], "Live Composite lookup must resolve unambiguously: \(query)")
                }
                print("PASS LIVE NASDAQ ALIAS: \(query) · ^IXIC")
            }
            let broad = try await service.search("纳斯达克", market: .us, cryptoSource: .automatic)
            try expect(broad.filter { $0.id == composite.id }.count == 1 && broad.filter { $0.id == nasdaq100.id }.count == 1, "Broad search must retain both distinct indices without duplicates")
            try expect(broad.contains { $0.lookup == "NDAQ" && $0.instrumentKind == .stock }, "Nasdaq the company must remain a stock")
            print("PASS LIVE NASDAQ SEARCH: Composite, Nasdaq-100 and NDAQ have distinct identities")
            for asset in [composite, nasdaq100] {
                let quote = try await service.quote(for: asset, crypto: .automatic, forceChart: true)
                try expect(quote.price > 0 && quote.currency == "PTS" && quote.reference != nil && quote.percent != nil && quote.quotedAt != nil && quote.points.count > 1, "Live Nasdaq index price/change/time/history failed: \(asset.symbol)")
                print("PASS LIVE NASDAQ QUOTE: \(asset.lookup) · \(quote.price) PTS · \(quote.points.count) points · \(quote.quotedAt!.ISO8601Format())")
            }
        }

        if CommandLine.arguments.contains("--live-index-search") {
            let service = MarketService()
            for query in ["000001", "上证指数"] {
                let results = try await service.search(query, market: .cn, cryptoSource: .automatic)
                try expect(results.contains { $0.lookup == "sh000001" && $0.instrumentKind == .index }, "SSE index search: \(query)")
                if query == "000001" { try expect(results.contains { $0.lookup == "sz000001" && $0.instrumentKind == .stock }, "SZSE stock must remain separately available") }
                print("PASS LIVE INDEX SEARCH: \(query) · SSE index retained")
            }
            for (query, lookup) in [("SH000001", "sh000001"), ("sz000001", "sz000001")] {
                let exact = try await service.search(query, market: nil, cryptoSource: .automatic)
                try expect(exact.count == 1 && exact[0].lookup == lookup, "Explicit exchange prefix must select the intended 000001")
                print("PASS LIVE QUALIFIED SEARCH: \(query) · \(lookup)")
            }
            let index = Asset(market: .cn, symbol: "000001", name: "上证指数", lookup: "sh000001", kind: .index)
            let quote = try await service.quote(for: index, crypto: .automatic, forceChart: true)
            try expect(quote.price > 0 && quote.currency == "PTS" && quote.quotedAt != nil && quote.points.count > 1, "SSE index quote/time/history in points")
            print("PASS LIVE INDEX QUOTE: SH000001 · PTS · \(quote.points.count) points")
        }

        if CommandLine.arguments.contains("--live-search-regression") {
            let service = MarketService()
            for query in ["宇树", "688836"] {
                for market: Market? in [nil, .cn] {
                    let results = try await service.search(query, market: market, cryptoSource: .automatic)
                    try expect(results.contains { $0.lookup == "sh688836" && $0.market == .cn }, "Live STAR search failed for \(query), \(market?.rawValue ?? "all")")
                    print("PASS LIVE STAR SEARCH: \(query) · \(market?.rawValue ?? "all") · sh688836")
                }
            }
            let unitree = Asset(market: .cn, symbol: "688836", name: "宇树科技W", lookup: "sh688836")
            let quote = try await service.quote(for: unitree, crypto: .automatic, forceChart: true)
            try expect(quote.price > 0 && quote.currency == "CNY" && quote.quotedAt != nil && !quote.points.isEmpty, "Unitree quote and intraday history")
            print("PASS LIVE STAR QUOTE: sh688836 · \(quote.currency) · \(quote.points.count) history points")
        }

        if CommandLine.arguments.contains("--live") {
            let service = MarketService()
            for asset in [us, cn, hk, btc] {
                let quote = try await service.quote(for: asset, crypto: .coinbase, forceChart: true)
                try expect(quote.price > 0 && quote.quotedAt != nil && quote.points.count > 1, "Live quote/history failed: \(asset.symbol)")
                print("PASS LIVE: \(asset.market.label) \(asset.symbol) · \(quote.source) \(quote.price) \(quote.currency) · \(quote.points.count) points · quote time \(quote.quotedAt!.ISO8601Format())")
            }
            let binance = try await service.quote(for: btc, crypto: .binance, forceChart: true)
            try expect(binance.currency == "USDT" && binance.points.count > 1, "Live Binance chart")
            print("PASS LIVE: Binance · \(binance.price) USDT · \(binance.points.count) points")
            for (query, market) in [("aapl", Market.us), ("600519", .cn), ("00700", .hk), ("BTC", .crypto)] {
                let results = try await service.search(query, market: market, cryptoSource: .automatic)
                try expect(!results.isEmpty, "Live search: \(query)")
                print("PASS LIVE SEARCH: \(query) · \(results.count) results")
            }
            print("Network results apply only to the current connection; Mainland China connectivity remains unverified.")
        }
    }
}
