import Foundation

public enum Market: String, Codable, CaseIterable, Sendable {
    case us, cn, hk, crypto
    public var label: String { [Self.us: "US", .cn: "CN", .hk: "HK", .crypto: "CRYPTO"][self]! }
    public var currency: String { [Self.us: "USD", .cn: "CNY", .hk: "HKD", .crypto: "USD"][self]! }
    public var timeZone: TimeZone {
        TimeZone(identifier: self == .us ? "America/New_York" : "Asia/Shanghai")!
    }
}

public enum InstrumentKind: String, Codable, Sendable {
    case stock, index, crypto
    public var title: String { switch self { case .stock: return "Stock"; case .index: return "Index"; case .crypto: return "Crypto" } }
}

public struct Asset: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var market: Market
    public var symbol: String
    public var name: String
    public var lookup: String
    public var kind: InstrumentKind?
    public var id: String { "\(market.rawValue):\(lookup)" }
    public var instrumentKind: InstrumentKind { kind ?? (market == .crypto ? .crypto : .stock) }
    public var priceUnit: String { instrumentKind == .index ? "PTS" : market.currency }
    public var exchange: String {
        switch market {
        case .cn: return lookup.hasPrefix("sh") ? "SSE" : (lookup.hasPrefix("sz") ? "SZSE" : "CN")
        case .hk: return "HKEX"
        case .us: return "US"
        case .crypto: return "CRYPTO"
        }
    }
    public var displayCode: String {
        switch market {
        case .cn: return (lookup.hasPrefix("sh") ? "SH" : (lookup.hasPrefix("sz") ? "SZ" : "")) + symbol
        case .hk: return "HK" + String(symbol.drop(while: { $0 == "0" }))
        default: return symbol
        }
    }
    public var displayName: String {
        guard market == .cn || market == .hk,
              let suffix = name.range(of: #"(?<=\p{Han})[WwPpSsBbRr]{1,2}$"#, options: .regularExpression) else { return name }
        return String(name[..<suffix.lowerBound]) + "-" + name[suffix].uppercased()
    }
    public init(market: Market, symbol: String, name: String, lookup: String? = nil, kind: InstrumentKind? = nil) {
        self.market = market; self.symbol = symbol; self.name = name; self.lookup = lookup ?? symbol; self.kind = kind
    }
}

public struct PricePoint: Codable, Equatable, Sendable {
    public var date: Date
    public var value: Double
    public init(date: Date, value: Double) { self.date = date; self.value = value }
}

public enum SessionState: String, Codable, Sendable { case open, closed, breakTime, unknown }

public struct Quote: Codable, Sendable {
    public var assetID: String
    public var price: Double
    public var reference: Double?
    public var open: Double?
    public var high: Double?
    public var low: Double?
    public var currency: String
    public var source: String
    public var pair: String
    public var quotedAt: Date?
    public var fetchedAt: Date
    public var points: [PricePoint]
    public var chartFetchedAt: Date?
    public var chartError: String?
    public var session: SessionState

    public init(assetID: String, price: Double, reference: Double?, open: Double?, high: Double?, low: Double?, currency: String, source: String, pair: String, quotedAt: Date?, fetchedAt: Date = Date(), points: [PricePoint] = [], chartFetchedAt: Date? = nil, chartError: String? = nil, session: SessionState = .unknown) {
        self.assetID = assetID; self.price = price; self.reference = reference
        self.open = open; self.high = high; self.low = low; self.currency = currency
        self.source = source; self.pair = pair; self.quotedAt = quotedAt; self.fetchedAt = fetchedAt
        self.points = points; self.chartFetchedAt = chartFetchedAt; self.chartError = chartError; self.session = session
    }
    public var change: Double? { reference.map { price - $0 } }
    public var percent: Double? { reference.flatMap { $0 > 0 ? (price - $0) / $0 * 100 : nil } }
    public func isStale(now: Date = Date()) -> Bool {
        if now.timeIntervalSince(fetchedAt) > 20 * 60 { return true }
        guard session != .closed && session != .breakTime else { return false }
        guard let quotedAt else { return true }
        return now.timeIntervalSince(quotedAt) > 5 * 60
    }
}

public enum CryptoSource: String, Codable, CaseIterable, Sendable {
    case automatic, coinbase, binance, okx
    public var title: String {
        switch self { case .automatic: return "Automatic · USD / USDT"; case .coinbase: return "Coinbase · USD"; case .binance: return "Binance · USDT"; case .okx: return "OKX · USDT" }
    }
    public func providers(previousSource: String? = nil) -> [CryptoSource] {
        guard self == .automatic else { return [self] }
        let defaults: [CryptoSource] = [.coinbase, .binance, .okx]
        guard let previousSource, let preferred = CryptoSource(rawValue: previousSource.lowercased()), defaults.contains(preferred) else { return defaults }
        return [preferred] + defaults.filter { $0 != preferred }
    }
}

public enum AppLanguage: String, Codable, CaseIterable, Sendable { case en, zh }

public struct Preferences: Codable, Equatable, Sendable {
    public var language: AppLanguage = .en
    public var refreshMinutes: Int = 1
    public var redUp: Bool = false
    public var alwaysOnTop: Bool = false
    public var cryptoSource: CryptoSource = .automatic
    public init() {}
    public func interval(visible: Bool) -> TimeInterval { Double(visible ? refreshMinutes : max(5, refreshMinutes)) * 60 }
}

public struct SavedState: Codable, Sendable {
    public var version = 1
    public var assets: [Asset]
    public var preferences: Preferences
    public var quotes: [String: Quote]
    public init(assets: [Asset] = [], preferences: Preferences = Preferences(), quotes: [String: Quote] = [:]) {
        self.assets = assets; self.preferences = preferences; self.quotes = quotes
    }
}

public struct StateFile {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> SavedState {
        guard FileManager.default.fileExists(atPath: url.path) else { return SavedState() }
        return try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: url))
    }
    public func save(_ state: SavedState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}

public enum FeedError: Error, LocalizedError {
    case invalid(String), http(Int), unavailable(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let s): return "Unexpected market data: \(s)"
        case .http(let code): return "HTTP \(code). Try again or check your network."
        case .unavailable(let s): return s
        }
    }
}

public enum TradingHours {
    // Weekday/session estimate only. A feed timestamp remains visible; this is not an exchange holiday calendar.
    public static func estimated(_ market: Market, at date: Date = Date()) -> SessionState {
        if market == .crypto { return .open }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = market.timeZone
        let weekday = calendar.component(.weekday, from: date)
        if weekday == 1 || weekday == 7 { return .closed }
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        switch market {
        case .us: return (570..<960).contains(minute) ? .open : .closed
        case .cn:
            if (570..<690).contains(minute) || (780..<900).contains(minute) { return .open }
            return (690..<780).contains(minute) ? .breakTime : .closed
        case .hk:
            if (570..<720).contains(minute) || (780..<960).contains(minute) { return .open }
            return (720..<780).contains(minute) ? .breakTime : .closed
        case .crypto: return .open
        }
    }
    public static func nextOpen(_ market: Market, after date: Date) -> Date? {
        guard market != .crypto else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = market.timeZone
        let starts = market == .us ? [570] : [570, 780]
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: date)) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            if weekday == 1 || weekday == 7 { continue }
            for minute in starts {
                if let candidate = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day), candidate > date { return candidate }
            }
        }
        return nil
    }
}
