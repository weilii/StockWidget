import Foundation

/// Verified Yahoo symbols for the supported Nasdaq cash indices. Keep these
/// separate from stock tickers: NDAQ is a company, and IXIC and NDX differ.
public enum USIndexCatalog {
    private struct Entry {
        let asset: Asset
        let aliases: [String]
    }
    private static let entries: [Entry] = [
        Entry(asset: Asset(market: .us, symbol: "IXIC", name: "纳斯达克综合指数", lookup: "^IXIC", kind: .index), aliases: [
            "IXIC", "^IXIC", ".IXIC", "INDEXNASDAQ:.IXIC", ".IXIC:INDEXNASDAQ",
            "NASDAQ Composite", "NASDAQ Composite Index", "纳斯达克综合指数", "纳斯达克综合", "纳斯达克综指", "纳斯达克指数", "纳指综指", "納斯達克綜合指數"
        ]),
        Entry(asset: Asset(market: .us, symbol: "NDX", name: "纳斯达克100指数", lookup: "^NDX", kind: .index), aliases: [
            "NDX", "^NDX", ".NDX", "INDEXNASDAQ:NDX", "NDX:INDEXNASDAQ",
            "NASDAQ-100", "NASDAQ 100", "NASDAQ-100 Index", "NASDAQ 100 Index", "纳斯达克100指数", "纳斯达克100", "纳指100", "納斯達克100指數"
        ])
    ]
    private static func key(_ value: String) -> String {
        value.uppercased().filter { !$0.isWhitespace }
    }
    public static func exactMatch(_ query: String) -> Asset? {
        let value = key(query)
        guard !value.isEmpty else { return nil }
        return entries.first { $0.aliases.contains { key($0) == value } }?.asset
    }
    public static func matches(_ query: String) -> [Asset] {
        let value = key(query)
        guard value.count >= 2 else { return [] }
        if let exact = exactMatch(query) { return [exact] }
        let broadNasdaq = ["NASDAQ", "纳斯达克", "纳指", "納斯達克"].contains(value)
        return entries.filter { entry in
            broadNasdaq || entry.aliases.contains { key($0).hasPrefix(value) }
        }.map(\.asset)
    }
}
