import Foundation

public actor HTTPClient {
    private let session: URLSession
    private var nextRequest: [String: Date] = [:]
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 20
        config.httpMaximumConnectionsPerHost = 3
        config.httpAdditionalHeaders = ["User-Agent": "StockWidget/0.1 (macOS; personal market monitor)", "Accept": "application/json,text/plain,*/*"]
        session = URLSession(configuration: config)
    }
    public func get(_ raw: String, query: [String: String] = [:], referer: String? = nil) async throws -> Data {
        guard var c = URLComponents(string: raw) else { throw FeedError.invalid("URL") }
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = c.url else { throw FeedError.invalid("URL parameters") }
        let host = url.host ?? "", now = Date()
        let slot = max(now, nextRequest[host] ?? now)
        nextRequest[host] = slot.addingTimeInterval(host.contains("coinbase") ? 0.25 : 0.15)
        let delay = slot.timeIntervalSince(now)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw FeedError.invalid("HTTP response") }
        guard (200..<300).contains(response.statusCode) else { throw FeedError.http(response.statusCode) }
        return data
    }
}

public struct ConnectionResult: Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var success: Bool
    public var detail: String
    public init(name: String, success: Bool, detail: String) { self.name = name; self.success = success; self.detail = detail }
}

public actor MarketService {
    private let http = HTTPClient()
    private var cryptoCatalogs: [CryptoSource: (Date, [Asset])] = [:]
    private var currencyNames: [String: String] = ["BTC": "Bitcoin", "ETH": "Ethereum", "SOL": "Solana", "DOGE": "Dogecoin", "XRP": "XRP", "ADA": "Cardano", "BNB": "BNB", "OKB": "OKB", "XAUT": "Tether Gold", "PAXG": "PAX Gold"]
    private let cryptoAliases: [String: [String]] = ["BTC": ["比特币"], "ETH": ["以太坊", "以太币"], "SOL": ["索拉纳"], "DOGE": ["狗狗币"], "ADA": ["艾达币"], "XRP": ["瑞波币"], "OKB": ["OKX", "欧易", "欧易币"], "XAUT": ["泰达黄金", "泰达金", "Tether Gold"], "PAXG": ["PAX Gold"]]
    private static let goldTokenSymbols = ["XAUT", "PAXG"]
    private static let spotGold = Asset(market: .metals, symbol: "XAU/USD", name: "Spot Gold", lookup: "XAU", kind: .metal)
    private static let goldAliases = ["黄金", "黄金价格", "现货黄金", "伦敦金", "国际金价", "金价", "GOLD", "GOLDPRICE", "SPOTGOLD", "XAU", "XAUUSD"]

    public init() {}

    public func quote(for asset: Asset, crypto: CryptoSource, previous: Quote? = nil, forceChart: Bool = false) async throws -> Quote {
        if asset.market == .metals {
            let data = try await http.get("https://api.gold-api.com/price/\(asset.lookup)")
            return try FeedParsing.spotGold(data, asset: asset)
        }
        if asset.market == .us {
            // The Composite's 5m feed can omit most of a session. Its 1m
            // series retains the available intraday samples without filling gaps.
            let interval = asset.instrumentKind == .index ? "1m" : "5m"
            let data = try await http.get("https://query1.finance.yahoo.com/v8/finance/chart/\(asset.lookup)", query: ["interval": interval, "range": "1d"])
            return try FeedParsing.yahoo(data, asset: asset)
        }
        if asset.market == .cn || asset.market == .hk {
            let code = asset.market == .hk ? "r_" + asset.lookup : asset.lookup
            let data = try await http.get("https://qt.gtimg.cn/", query: ["q": code], referer: "https://gu.qq.com/")
            var quote = try FeedParsing.tencentQuote(data, asset: asset)
            if !needsChart(previous, source: "Tencent", force: forceChart || !sameExchangeDay(previous?.quotedAt, quote.quotedAt, market: asset.market)) {
                quote.points = previous?.points ?? []; quote.chartFetchedAt = previous?.chartFetchedAt
            } else {
                do {
                    let history = try await http.get("https://web.ifzq.gtimg.cn/appstock/app/minute/query", query: ["code": asset.lookup])
                    quote.points = try FeedParsing.tencentPoints(history, asset: asset); quote.chartFetchedAt = Date()
                } catch {
                    quote.chartError = error.localizedDescription
                    // Only reuse a chart for this exchange day, never yesterday's curve as today's.
                    if let previous, previous.source == quote.source, sameExchangeDay(previous.quotedAt, quote.quotedAt, market: asset.market) {
                        quote.points = previous.points; quote.chartFetchedAt = previous.chartFetchedAt
                    }
                }
            }
            return quote
        }
        var sources = crypto.providers(previousSource: previous?.source)
        if crypto == .automatic && previous == nil {
            // A search already learned which exchanges list the token. Prefer
            // them for its first quote instead of trying known missing pairs.
            let listed = sources.filter { source in
                guard let (date, catalog) = cryptoCatalogs[source], Date().timeIntervalSince(date) < 21600 else { return false }
                return catalog.contains { $0.id == asset.id }
            }
            sources = listed + sources.filter { !listed.contains($0) }
        }
        var errors: [String] = []
        var partial: Quote?
        for source in sources {
            do {
                let quote = try await cryptoQuote(asset, source: source, previous: previous, forceChart: forceChart)
                if crypto == .automatic && (quote.points.isEmpty || quote.chartError != nil) {
                    if partial == nil { partial = quote }
                    continue
                }
                return quote
            }
            catch is CancellationError { throw CancellationError() }
            catch { errors.append("\(source.rawValue): \(error.localizedDescription)") }
        }
        if let partial { return partial }
        throw FeedError.unavailable(errors.joined(separator: " · "))
    }
    private func sameExchangeDay(_ a: Date?, _ b: Date?, market: Market) -> Bool {
        guard let a, let b else { return false }
        var c = Calendar(identifier: .gregorian); c.timeZone = market.timeZone
        return c.isDate(a, inSameDayAs: b)
    }
    private func needsChart(_ previous: Quote?, source: String, force: Bool) -> Bool {
        force || previous?.source != source || previous?.chartFetchedAt == nil || Date().timeIntervalSince(previous!.chartFetchedAt!) >= 300
    }
    private func cryptoQuote(_ asset: Asset, source: CryptoSource, previous: Quote?, forceChart: Bool) async throws -> Quote {
        var quote: Quote
        if source == .coinbase {
            let prefix = "https://api.exchange.coinbase.com/products/\(asset.symbol)-USD"
            async let ticker = http.get(prefix + "/ticker")
            async let stats = http.get(prefix + "/stats")
            quote = try await FeedParsing.coinbase(ticker: ticker, stats: stats, asset: asset)
        } else if source == .binance {
            let data = try await http.get("https://data-api.binance.vision/api/v3/ticker/24hr", query: ["symbol": asset.symbol + "USDT"])
            quote = try FeedParsing.binance(data, asset: asset)
        } else if source == .okx {
            let data = try await http.get("https://www.okx.com/api/v5/market/ticker", query: ["instId": asset.symbol + "-USDT"])
            quote = try FeedParsing.okx(data, asset: asset)
        } else {
            throw FeedError.invalid("Select a concrete crypto source")
        }
        if !needsChart(previous, source: quote.source, force: forceChart) {
            quote.points = previous?.points ?? []; quote.chartFetchedAt = previous?.chartFetchedAt
        } else {
            do {
                if source == .coinbase {
                    let end = Date(), start = end.addingTimeInterval(-86400)
                    let formatter = ISO8601DateFormatter()
                    let data = try await http.get("https://api.exchange.coinbase.com/products/\(asset.symbol)-USD/candles", query: ["granularity": "300", "start": formatter.string(from: start), "end": formatter.string(from: end)])
                    quote.points = try FeedParsing.coinbasePoints(data)
                } else if source == .binance {
                    let data = try await http.get("https://data-api.binance.vision/api/v3/klines", query: ["symbol": asset.symbol + "USDT", "interval": "5m", "limit": "288"])
                    quote.points = try FeedParsing.binancePoints(data)
                } else {
                    let data = try await http.get("https://www.okx.com/api/v5/market/candles", query: ["instId": asset.symbol + "-USDT", "bar": "5m", "limit": "300"])
                    quote.points = try FeedParsing.okxPoints(data)
                }
                if quote.points.isEmpty { throw FeedError.invalid("Empty 24h history") }
                quote.chartFetchedAt = Date()
            } catch {
                quote.chartError = error.localizedDescription
                if let previous, previous.source == quote.source && previous.pair == quote.pair {
                    quote.points = previous.points; quote.chartFetchedAt = previous.chartFetchedAt
                }
            }
        }
        quote.points = quote.points.filter { $0.date >= Date().addingTimeInterval(-86400) }
        return quote
    }
    public func search(_ query: String, market: Market?, cryptoSource: CryptoSource) async throws -> [Asset] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        try Task.checkCancellation()
        if market == .crypto { return try await cryptoSearch(query, source: cryptoSource) }
        if market == nil || market == .metals {
            let key = query.uppercased().filter { !$0.isWhitespace && $0 != "/" && $0 != "-" }
            if Self.goldAliases.contains(key) { return [Self.spotGold] }
            if market == .metals { return [] }
        }
        let includesUS = market == nil || market == .us
        // Known names/codes, including Google's .IXIC notation, resolve even
        // when an overseas product catalog or the search endpoint is offline.
        if includesUS, let index = USIndexCatalog.exactMatch(query) { return [index] }
        let indices = includesUS ? USIndexCatalog.matches(query) : []
        let q = query.uppercased()
        let qualifiedChinaCode = q.range(of: "^(SH|SZ)[0-9]{6}$", options: .regularExpression) != nil ? q.lowercased() : nil
        let stockQuery = qualifiedChinaCode == nil ? query : String(query.dropFirst(2))
        if market == nil, Self.goldTokenSymbols.contains(where: { symbol in
            q == symbol || (cryptoAliases[symbol] ?? []).contains { $0.caseInsensitiveCompare(query) == .orderedSame }
        }) {
            return try await cryptoSearch(query, source: cryptoSource)
        }
        var stocks = indices
        var stockError: Error?
        do {
            let data = try await http.get("https://smartbox.gtimg.cn/s3/", query: ["v": "2", "q": stockQuery, "t": "all", "c": "30"], referer: "https://gu.qq.com/")
            let found = try FeedParsing.tencentSearch(data).filter { (market == nil || $0.market == market) && (qualifiedChinaCode == nil || $0.lookup == qualifiedChinaCode) }
            var seen = Set(stocks.map(\.id))
            stocks.append(contentsOf: found.filter { seen.insert($0.id).inserted })
        } catch is CancellationError { throw CancellationError() }
        catch { stockError = error }
        // Explicit codes remain usable when the unofficial search service is unavailable.
        if indices.isEmpty, q.range(of: "^[A-Z][A-Z0-9.\\-]{0,9}$", options: .regularExpression) != nil, market == .us {
            let direct = Asset(market: .us, symbol: q, name: q, lookup: q.replacingOccurrences(of: ".", with: "-"))
            if !stocks.contains(where: { $0.id == direct.id }) { stocks.append(direct) }
        }
        // Chinese stock names and numeric stock codes should not wait for
        // overseas crypto catalogs. Explicit Crypto searches still query them.
        let hasLatinLetters = query.range(of: "[A-Za-z]", options: .regularExpression) != nil
        let matchesCryptoAlias = cryptoAliases.values.joined().contains { $0.contains(query) || query.contains($0) }
        if market == nil && qualifiedChinaCode == nil && indices.isEmpty && (hasLatinLetters || matchesCryptoAlias) {
            let crypto = (try? await cryptoSearch(query, source: cryptoSource)) ?? []
            stocks.append(contentsOf: crypto)
        }
        if stocks.isEmpty, let stockError { throw stockError }
        return stocks
    }
    private func cryptoCatalog(_ source: CryptoSource) async throws -> [Asset] {
        if let cached = cryptoCatalogs[source], Date().timeIntervalSince(cached.0) < 21600 { return cached.1 }
        let catalog: [Asset]
        switch source {
        case .coinbase:
            let data = try await http.get("https://api.exchange.coinbase.com/products")
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw FeedError.invalid("Crypto products") }
            if let namesData = try? await http.get("https://api.exchange.coinbase.com/currencies"),
               let names = try? JSONSerialization.jsonObject(with: namesData) as? [[String: Any]] {
                for entry in names {
                    if let id = entry["id"] as? String, let name = entry["name"] as? String { currencyNames[id] = name }
                }
            }
            catalog = rows.compactMap { row in
                guard row["quote_currency"] as? String == "USD", row["status"] as? String == "online", row["trading_disabled"] as? Bool != true, let base = row["base_currency"] as? String else { return nil }
                return Asset(market: .crypto, symbol: base, name: currencyNames[base] ?? base)
            }
        case .binance:
            let data = try await http.get("https://data-api.binance.vision/api/v3/exchangeInfo")
            let root = try FeedParsing.object(data)
            catalog = (root["symbols"] as? [[String: Any]] ?? []).compactMap { row in
                guard row["quoteAsset"] as? String == "USDT", row["status"] as? String == "TRADING", row["isSpotTradingAllowed"] as? Bool != false, let base = row["baseAsset"] as? String else { return nil }
                return Asset(market: .crypto, symbol: base, name: currencyNames[base] ?? base)
            }
        case .okx:
            let data = try await http.get("https://www.okx.com/api/v5/public/instruments", query: ["instType": "SPOT"])
            catalog = try FeedParsing.okxInstruments(data).map { asset in
                var named = asset; named.name = currencyNames[asset.symbol] ?? asset.name; return named
            }
        case .automatic: throw FeedError.invalid("Select a concrete crypto catalog")
        }
        try Task.checkCancellation()
        cryptoCatalogs[source] = (Date(), catalog)
        return catalog
    }
    private func cryptoSearch(_ query: String, source: CryptoSource) async throws -> [Asset] {
        let order = source.providers()
        var key = query.uppercased().filter { !$0.isWhitespace }
        for suffix in ["/USDT", "-USDT", "/USD", "-USD"] where key.hasSuffix(suffix) { key = String(key.dropLast(suffix.count)); break }
        if key.hasSuffix("USDT") && key.count > 4 { key = String(key.dropLast(4)) }
        if let alias = cryptoAliases.first(where: { $0.value.contains { $0.caseInsensitiveCompare(query) == .orderedSame } }) { key = alias.key }
        var catalogs: [CryptoSource: [Asset]] = [:]
        var errors: [String] = []
        var exact: Asset?
        // Independent catalogs load concurrently; a slow exchange does not
        // make the others wait before their own request can even start.
        await withTaskGroup(of: (CryptoSource, Result<[Asset], Error>).self) { group in
            for item in order {
                group.addTask {
                    do { return (item, .success(try await self.cryptoCatalog(item))) }
                    catch { return (item, .failure(error)) }
                }
            }
            for await (item, result) in group {
                switch result {
                case .success(let catalog):
                    catalogs[item] = catalog
                    if let asset = catalog.first(where: { $0.symbol == key }) {
                        exact = asset
                        group.cancelAll()
                    }
                case .failure(let error): errors.append("\(item.rawValue): \(error.localizedDescription)")
                }
                if exact != nil { break }
            }
        }
        try Task.checkCancellation()
        if let exact { return [exact] }
        let all = order.flatMap { catalogs[$0] ?? [] }
        if all.isEmpty && !errors.isEmpty { throw FeedError.unavailable(errors.joined(separator: " · ")) }
        var seen = Set<String>()
        return all.filter { ($0.symbol.localizedCaseInsensitiveContains(key) || $0.name.localizedCaseInsensitiveContains(query) || (cryptoAliases[$0.symbol]?.contains(where: { $0.localizedCaseInsensitiveContains(query) }) ?? false)) && seen.insert($0.id).inserted }.sorted {
            if ($0.symbol == key) != ($1.symbol == key) { return $0.symbol == key }
            return $0.symbol < $1.symbol
        }.prefix(30).map { $0 }
    }
    public func diagnose() async -> [ConnectionResult] {
        let checks: [(String, String, [String: String])] = [
            ("Tencent · stock search", "https://smartbox.gtimg.cn/s3/", ["q": "aapl", "t": "all", "v": "2", "c": "5"]),
            ("Tencent · CN price", "https://qt.gtimg.cn/", ["q": "sh600519"]),
            ("Tencent · HK price", "https://qt.gtimg.cn/", ["q": "r_hk00700"]),
            ("Tencent · intraday", "https://web.ifzq.gtimg.cn/appstock/app/minute/query", ["code": "sh600519"]),
            ("Tencent · HK intraday", "https://web.ifzq.gtimg.cn/appstock/app/minute/query", ["code": "hk00700"]),
            ("Yahoo · US price & chart", "https://query1.finance.yahoo.com/v8/finance/chart/AAPL", ["interval": "5m", "range": "1d"]),
            ("Coinbase · products", "https://api.exchange.coinbase.com/products", [:]),
            ("Coinbase · names", "https://api.exchange.coinbase.com/currencies", [:]),
            ("Coinbase · price", "https://api.exchange.coinbase.com/products/BTC-USD/ticker", [:]),
            ("Coinbase · 24h statistics", "https://api.exchange.coinbase.com/products/BTC-USD/stats", [:]),
            ("Coinbase · chart", "https://api.exchange.coinbase.com/products/BTC-USD/candles", ["granularity": "300"]),
            ("Binance · products", "https://data-api.binance.vision/api/v3/exchangeInfo", ["symbol": "BTCUSDT"]),
            ("Binance · price & 24h", "https://data-api.binance.vision/api/v3/ticker/24hr", ["symbol": "BTCUSDT"]),
            ("Binance · chart", "https://data-api.binance.vision/api/v3/klines", ["symbol": "BTCUSDT", "interval": "5m", "limit": "288"]),
            ("OKX · spot products", "https://www.okx.com/api/v5/public/instruments", ["instType": "SPOT"]),
            ("OKX · OKB price & 24h", "https://www.okx.com/api/v5/market/ticker", ["instId": "OKB-USDT"]),
            ("OKX · OKB chart", "https://www.okx.com/api/v5/market/candles", ["instId": "OKB-USDT", "bar": "5m", "limit": "300"])
        ]
        var results: [ConnectionResult] = []
        for (name, url, query) in checks {
            do {
                let start = Date()
                let data = try await http.get(url, query: query, referer: url.contains("gtimg") ? "https://gu.qq.com/" : nil)
                guard data.count > 10 else { throw FeedError.invalid("Empty response") }
                results.append(ConnectionResult(name: name, success: true, detail: "HTTP OK · \(Int(Date().timeIntervalSince(start) * 1000)) ms"))
            } catch { results.append(ConnectionResult(name: name, success: false, detail: error.localizedDescription)) }
        }
        return results
    }
}
