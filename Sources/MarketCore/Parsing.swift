import Foundation
import CoreFoundation

public enum FeedParsing {
    public static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FeedError.invalid("JSON object") }
        return value
    }
    public static func number(_ value: Any?) -> Double? {
        let n: Double?
        if let s = value as? String { n = Double(s) }
        else if let v = value as? NSNumber, CFGetTypeID(v) != CFBooleanGetTypeID() { n = v.doubleValue }
        else { n = nil }
        return n.flatMap { $0.isFinite ? $0 : nil }
    }
    public static func text(_ data: Data) throws -> String {
        if let result = String(data: data, encoding: .utf8) { return result }
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        guard let result = String(data: data, encoding: gb) else { throw FeedError.invalid("text encoding") }
        return result
    }
    public static func date(_ string: String, format: String, zone: TimeZone) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = zone; f.dateFormat = format
        return f.date(from: string)
    }
    public static func isoDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: string) { return date }
        f.formatOptions = [.withInternetDateTime]; return f.date(from: string)
    }
    public static func cleanPoints(_ points: [PricePoint]) -> [PricePoint] {
        var byTime: [Date: PricePoint] = [:]
        for point in points where point.value.isFinite && point.value > 0 { byTime[point.date] = point }
        return byTime.values.sorted { $0.date < $1.date }
    }
    public static func tencentQuote(_ data: Data, asset: Asset, now: Date = Date()) throws -> Quote {
        let string = try text(data)
        guard let start = string.firstIndex(of: "\""), let end = string.lastIndex(of: "\""), start < end else { throw FeedError.invalid("Tencent quote") }
        let fields = String(string[string.index(after: start)..<end]).components(separatedBy: "~")
        guard fields.count > 34, let price = number(fields[3]), price > 0 else { throw FeedError.invalid("No quote for \(asset.symbol)") }
        let quotedAt = date(fields[30], format: asset.market == .hk ? "yyyy/MM/dd HH:mm:ss" : "yyyyMMddHHmmss", zone: asset.market.timeZone)
        return Quote(assetID: asset.id, price: price, reference: number(fields[4]), open: number(fields[5]), high: number(fields[33]), low: number(fields[34]), currency: asset.priceUnit, source: "Tencent", pair: asset.lookup, quotedAt: quotedAt, fetchedAt: now, session: TradingHours.estimated(asset.market, at: now))
    }
    public static func tencentPoints(_ data: Data, asset: Asset) throws -> [PricePoint] {
        let root = try object(data)
        guard let all = root["data"] as? [String: Any], let item = all[asset.lookup] as? [String: Any], let series = item["data"] as? [String: Any], let day = series["date"] as? String, let rows = series["data"] as? [String] else { throw FeedError.invalid("Intraday series unavailable") }
        let points = rows.compactMap { row -> PricePoint? in
            let f = row.split(separator: " ")
            guard f.count >= 2, let date = date(day + f[0], format: "yyyyMMddHHmm", zone: asset.market.timeZone), let price = Double(f[1]) else { return nil }
            return PricePoint(date: date, value: price)
        }
        let clean = cleanPoints(points)
        guard !clean.isEmpty else { throw FeedError.invalid("Empty intraday series") }
        return clean
    }
    public static func yahoo(_ data: Data, asset: Asset, now: Date = Date()) throws -> Quote {
        let root = try object(data)
        guard let chart = root["chart"] as? [String: Any], let results = chart["result"] as? [[String: Any]], let item = results.first, let meta = item["meta"] as? [String: Any], let price = number(meta["regularMarketPrice"]), price > 0 else { throw FeedError.invalid("Yahoo quote unavailable") }
        guard (meta["currency"] as? String) == asset.market.currency else { throw FeedError.invalid("Unexpected quote currency") }
        if asset.instrumentKind == .index {
            guard meta["instrumentType"] as? String == "INDEX",
                  (meta["symbol"] as? String)?.uppercased() == asset.lookup.uppercased() else {
                throw FeedError.invalid("Unexpected index symbol or instrument type")
            }
        }
        let timestamps = item["timestamp"] as? [Any] ?? []
        let indicators = item["indicators"] as? [String: Any]
        let values = (indicators?["quote"] as? [[String: Any]])?.first
        let closes = values?["close"] as? [Any] ?? []
        var points: [PricePoint] = []
        for i in 0..<min(timestamps.count, closes.count) {
            if let time = number(timestamps[i]), let close = number(closes[i]) { points.append(PricePoint(date: Date(timeIntervalSince1970: time), value: close)) }
        }
        let opens = values?["open"] as? [Any] ?? []
        let open = opens.compactMap { number($0) }.first
        return Quote(assetID: asset.id, price: price, reference: number(meta["chartPreviousClose"]) ?? number(meta["previousClose"]), open: open, high: number(meta["regularMarketDayHigh"]), low: number(meta["regularMarketDayLow"]), currency: asset.priceUnit, source: "Yahoo", pair: asset.symbol, quotedAt: number(meta["regularMarketTime"]).map(Date.init(timeIntervalSince1970:)), fetchedAt: now, points: cleanPoints(points), chartFetchedAt: points.isEmpty ? nil : now, chartError: points.isEmpty ? "Intraday series unavailable" : nil, session: TradingHours.estimated(asset.market, at: now))
    }
    public static func coinbase(ticker: Data, stats: Data, asset: Asset, now: Date = Date()) throws -> Quote {
        let t = try object(ticker), s = try object(stats)
        guard let price = number(t["price"]), price > 0, let reference = number(s["open"]), reference > 0 else { throw FeedError.invalid("Coinbase quote") }
        return Quote(assetID: asset.id, price: price, reference: reference, open: reference, high: number(s["high"]), low: number(s["low"]), currency: "USD", source: "Coinbase", pair: asset.symbol + "-USD", quotedAt: isoDate(t["time"] as? String), fetchedAt: now, session: .open)
    }
    public static func coinbasePoints(_ data: Data, now: Date = Date()) throws -> [PricePoint] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[Any]] else { throw FeedError.invalid("Coinbase candles") }
        return cleanPoints(rows.compactMap { row in
            guard row.count >= 5, let time = number(row[0]), let close = number(row[4]), time >= now.addingTimeInterval(-86400).timeIntervalSince1970, time <= now.timeIntervalSince1970 + 60 else { return nil }
            return PricePoint(date: Date(timeIntervalSince1970: time), value: close)
        })
    }
    public static func binance(_ data: Data, asset: Asset, now: Date = Date()) throws -> Quote {
        let item = try object(data)
        guard let price = number(item["lastPrice"]), price > 0, let reference = number(item["openPrice"]), reference > 0 else { throw FeedError.invalid("Binance quote") }
        return Quote(assetID: asset.id, price: price, reference: reference, open: reference, high: number(item["highPrice"]), low: number(item["lowPrice"]), currency: "USDT", source: "Binance", pair: asset.symbol + "USDT", quotedAt: number(item["closeTime"]).map { Date(timeIntervalSince1970: $0 / 1000) }, fetchedAt: now, session: .open)
    }
    public static func binancePoints(_ data: Data, now: Date = Date()) throws -> [PricePoint] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[Any]] else { throw FeedError.invalid("Binance candles") }
        return cleanPoints(rows.compactMap { row in
            guard row.count >= 5, let time = number(row[0]), let close = number(row[4]), time / 1000 >= now.addingTimeInterval(-86400).timeIntervalSince1970, time / 1000 <= now.timeIntervalSince1970 + 60 else { return nil }
            return PricePoint(date: Date(timeIntervalSince1970: time / 1000), value: close)
        })
    }
    private static func okxPayload(_ data: Data) throws -> [Any] {
        let root = try object(data)
        guard let code = root["code"] as? String else { throw FeedError.invalid("OKX response code") }
        guard code == "0" else { throw FeedError.unavailable("OKX \(code): \(root["msg"] as? String ?? "Request failed")") }
        guard let rows = root["data"] as? [Any] else { throw FeedError.invalid("OKX response data") }
        return rows
    }
    public static func okxInstruments(_ data: Data) throws -> [Asset] {
        let rows = try okxPayload(data)
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let item = row as? [String: Any], item["instType"] as? String == "SPOT",
                  item["quoteCcy"] as? String == "USDT", item["state"] as? String == "live",
                  let base = item["baseCcy"] as? String, !base.isEmpty,
                  item["instId"] as? String == base + "-USDT", seen.insert(base).inserted else { return nil }
            return Asset(market: .crypto, symbol: base, name: base)
        }
    }
    public static func okx(_ data: Data, asset: Asset, now: Date = Date()) throws -> Quote {
        let rows = try okxPayload(data)
        guard let item = rows.first as? [String: Any], item["instType"] as? String == "SPOT",
              item["instId"] as? String == asset.symbol + "-USDT",
              let price = number(item["last"]), price > 0,
              let reference = number(item["open24h"]), reference > 0,
              let time = number(item["ts"]), time > 0 else { throw FeedError.invalid("OKX spot quote") }
        return Quote(assetID: asset.id, price: price, reference: reference, open: reference,
            high: number(item["high24h"]), low: number(item["low24h"]), currency: "USDT", source: "OKX",
            pair: asset.symbol + "-USDT", quotedAt: Date(timeIntervalSince1970: time / 1000), fetchedAt: now, session: .open)
    }
    public static func okxPoints(_ data: Data, now: Date = Date()) throws -> [PricePoint] {
        let rows = try okxPayload(data)
        return cleanPoints(rows.compactMap { row in
            guard let row = row as? [Any], row.count >= 5, let time = number(row[0]), let close = number(row[4]),
                  time / 1000 >= now.addingTimeInterval(-86400).timeIntervalSince1970,
                  time / 1000 <= now.timeIntervalSince1970 + 60 else { return nil }
            return PricePoint(date: Date(timeIntervalSince1970: time / 1000), value: close)
        })
    }
    public static func tencentSearch(_ data: Data) throws -> [Asset] {
        let string = try text(data)
        guard let first = string.firstIndex(of: "\""), let last = string.lastIndex(of: "\""), first <= last else { return [] }
        let encoded = String(string[first...last])
        let decoded = (try? JSONDecoder().decode(String.self, from: Data(encoded.utf8))) ?? String(string[string.index(after: first)..<last])
        var results: [Asset] = []
        for row in decoded.components(separatedBy: "^") {
            let f = row.components(separatedBy: "~")
            guard f.count >= 5 else { continue }
            // A-share boards carry suffixes (e.g. GP-A-KCB for STAR Market).
            // Keep supported stock families and mapped cash indices, while
            // rejecting funds and unrelated products.
            let type = f[4]
            guard type == "GP" || type == "GP-A" || type.hasPrefix("GP-A-") || type == "ZS" else { continue }
            let prefix = f[0], raw = f[1], name = f[2]
            switch prefix {
            case "sh", "sz": results.append(Asset(market: .cn, symbol: raw, name: name, lookup: prefix + raw, kind: type == "ZS" ? .index : .stock))
            case "hk":
                guard type != "ZS" else { continue }
                results.append(Asset(market: .hk, symbol: raw, name: name, lookup: "hk" + raw, kind: .stock))
            case "us":
                if type == "ZS" {
                    if let index = USIndexCatalog.exactMatch(raw) { results.append(index) }
                    continue
                }
                let symbol = String(raw.split(separator: ".").dropLast().joined(separator: ".")).uppercased()
                let clean = symbol.isEmpty ? raw.uppercased() : symbol
                results.append(Asset(market: .us, symbol: clean, name: name, lookup: clean.replacingOccurrences(of: ".", with: "-")))
            default: break
            }
        }
        var seen = Set<String>()
        return results.filter { seen.insert($0.id).inserted }
    }
}
