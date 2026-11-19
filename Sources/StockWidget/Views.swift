import SwiftUI
import UniformTypeIdentifiers
import MarketCore

// Explicitly select the property-wrapper type. The macOS 27 CLT SDK also
// exports a same-named State macro whose plugin ships only with full Xcode.
typealias UIState<Value> = SwiftUI.State<Value>

enum CompactLayout {
    static let width: CGFloat = 360
    static let minimumWidth: CGFloat = 320
    static let rowHeight: CGFloat = 44
    static func height(for count: Int) -> CGFloat {
        count == 0 ? 128 : CGFloat(min(max(count, 1), 10)) * rowHeight + 12
    }
}

struct WatchlistView: View {
    @EnvironmentObject var store: AppStore
    var initialSearchQuery = ""
    var body: some View {
        VStack(spacing: 0) {
            if let error = store.storageError {
                Label(store.t("Saved data issue") + ": " + error, systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            if store.assets.isEmpty { emptyState }
            else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.assets) { asset in
                            QuoteRow(asset: asset)
                                .onDrop(of: [UTType.text], delegate: SymbolDropDelegate(asset: asset, store: store))
                        }
                    }.padding(.horizontal, 6).padding(.vertical, 6)
                }.scrollIndicators(.hidden)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
        .frame(minWidth: CompactLayout.minimumWidth, minHeight: 56)
        .contextMenu {
            Button(store.t("Add symbol"), systemImage: "plus") { store.showingSearch = true }
            Button(store.t("Refresh"), systemImage: "arrow.clockwise") { store.refreshNow() }.disabled(store.isRefreshing)
            Button(store.t("Settings"), systemImage: "slider.horizontal.3") { store.showingSettings = true }
            Toggle(store.t("Always on top"), isOn: $store.preferences.alwaysOnTop)
        }
        .sheet(isPresented: $store.showingSearch, onDismiss: { store.onReturnToWatchlist?() }) { SearchView(initialQuery: initialSearchQuery).environmentObject(store) }
        .sheet(isPresented: $store.showingSettings, onDismiss: { store.onReturnToWatchlist?() }) { SettingsView().environmentObject(store) }
        .sheet(item: $store.selectedAsset, onDismiss: { store.onReturnToWatchlist?() }) { asset in DetailView(asset: asset).environmentObject(store) }
    }
    private var emptyState: some View {
        VStack(spacing: 12) {
            Text(store.t("No symbols yet")).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Button(store.t("Add your first symbol")) { store.showingSearch = true }
                .buttonStyle(.bordered).controlSize(.small)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(16)
    }
}

struct QuoteRow: View {
    @EnvironmentObject var store: AppStore
    let asset: Asset
    @UIState private var hover = false
    private var quote: Quote? { store.quotes[asset.id] }
    private var failed: Bool { store.errors[asset.id] != nil }
    var body: some View {
        HStack(spacing: 0) {
            ReorderHandle(identifier: asset.id, label: store.t("Drag to reorder"),
                prepare: { store.onPrepareWindowDrag?() },
                began: { store.draggedAsset = asset.id },
                ended: { if store.draggedAsset == asset.id { store.draggedAsset = nil } })
                .frame(width: 14, height: CompactLayout.rowHeight)
            ZStack {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    TickerTypography.text(asset.displayName, size: 12, bold: true).lineLimit(1).truncationMode(.tail)
                    Text(displaySymbol).font(TickerTypography.font(10)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(width: 104, alignment: .leading)
                Sparkline(points: quote?.points ?? [], reference: quote?.reference, color: quoteColor(quote, redUp: store.preferences.redUp), filled: false)
                    .frame(maxWidth: .infinity).frame(height: 23).opacity(failed ? 0.4 : 0.9)
                    .overlay(alignment: .bottomTrailing) {
                        if quote?.chartError != nil { Image(systemName: "exclamationmark.circle").font(.system(size: 8)).foregroundStyle(.orange).help(store.t("History unavailable")) }
                    }
                VStack(alignment: .trailing, spacing: 3) {
                    HStack(spacing: 5) {
                        if failed || quote?.isStale() == true {
                            Image(systemName: failed ? "wifi.slash" : "clock").font(.system(size: 8)).foregroundStyle(.orange)
                        }
                        Text(quote?.percent.map { signed($0) + "%" } ?? "—")
                            .font(TickerTypography.font(12, bold: true))
                            .foregroundStyle(quoteColor(quote, redUp: store.preferences.redUp))
                    }
                    HStack(spacing: 4) {
                        Text(quote?.currency ?? asset.priceUnit).font(TickerTypography.font(7.5)).foregroundStyle(.tertiary)
                        Text(quote.map { priceString($0.price) } ?? "—").font(TickerTypography.font(11)).minimumScaleFactor(0.85).foregroundStyle(.secondary)
                    }
                }.frame(width: 100, alignment: .trailing)
            }.padding(.horizontal, 8).frame(height: CompactLayout.rowHeight)
                .contentShape(Rectangle())
                .background(hover ? Color.primary.opacity(0.035) : .clear, in: RoundedRectangle(cornerRadius: 9))
                .allowsHitTesting(false).accessibilityHidden(true)
                RowPointerSurface(label: "\(asset.displayName), \(asset.symbol)", tooltip: rowHelp,
                    click: { store.selectedAsset = asset },
                    prepare: { store.onPrepareWindowDrag?() },
                    drag: { store.onBeginWindowDrag?($0) },
                    finish: { store.onFinishWindowDrag?() }, actions: pointerActions)
            }
        }.frame(height: CompactLayout.rowHeight).onHover { hover = $0 }
    }
    private var pointerActions: [PointerMenuAction] {
        [
            PointerMenuAction(store.t("Move up"), symbol: "arrow.up") { store.step(asset, by: -1) },
            PointerMenuAction(store.t("Move down"), symbol: "arrow.down") { store.step(asset, by: 1) },
            PointerMenuAction(store.t("Remove"), symbol: "trash") { store.remove(asset) },
            PointerMenuAction(store.t("Add symbol"), symbol: "plus") { store.showingSearch = true },
            PointerMenuAction(store.t("Refresh"), symbol: "arrow.clockwise") { store.refreshNow() },
            PointerMenuAction(store.t("Settings"), symbol: "slider.horizontal.3") { store.showingSettings = true },
            PointerMenuAction(store.t("Always on top"), checked: store.preferences.alwaysOnTop) { store.preferences.alwaysOnTop.toggle() }
        ]
    }
    private var displaySymbol: String { asset.displayCode }
    private var rowHelp: String {
        var lines = [asset.displayName]
        if let quote {
            lines += ["\(quote.source) · \(quote.pair)", store.t("Quote time") + ": " + fullTime(quote.quotedAt)]
            if quote.isStale() { lines.append(store.t("Stale")) }
        }
        if let error = store.errors[asset.id] { lines.append(error) }
        return lines.joined(separator: "\n")
    }
}

struct Sparkline: View {
    let points: [PricePoint]
    var reference: Double?
    var color: Color = .teal
    var filled = true
    var body: some View {
        Canvas { context, size in
            guard points.count > 1, let first = points.first, let last = points.last else {
                var p = Path(); p.move(to: CGPoint(x: 0, y: size.height / 2)); p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(p, with: .color(.secondary.opacity(0.20)), style: StrokeStyle(lineWidth: 1, dash: [2, 4])); return
            }
            let minValue = points.map(\.value).min()!, maxValue = points.map(\.value).max()!
            let spread = max(maxValue - minValue, maxValue * 0.0001), padding = spread * 0.12
            let low = minValue - padding, high = maxValue + padding
            let time = max(last.date.timeIntervalSince(first.date), 1)
            func position(_ point: PricePoint) -> CGPoint {
                CGPoint(x: point.date.timeIntervalSince(first.date) / time * size.width,
                        y: (1 - (point.value - low) / (high - low)) * (size.height - 4) + 2)
            }
            if let reference, reference >= low, reference <= high {
                let y = position(PricePoint(date: first.date, value: reference)).y
                var baseline = Path(); baseline.move(to: CGPoint(x: 0, y: y)); baseline.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(baseline, with: .color(.secondary.opacity(0.22)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
            }
            var line = Path(); line.move(to: position(first))
            for point in points.dropFirst() { line.addLine(to: position(point)) }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height)); area.addLine(to: CGPoint(x: 0, y: size.height)); area.closeSubpath()
            if filled { context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.14), color.opacity(0)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height))) }
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
        }.accessibilityLabel("Price history, \(points.count) points")
    }
}

@MainActor
struct SymbolDropDelegate: DropDelegate {
    let asset: Asset
    let store: AppStore
    func dropEntered(info: DropInfo) {
        guard let dragged = store.draggedAsset, dragged != asset.id else { return }
        withAnimation(.easeInOut(duration: 0.12)) { store.move(dragged, before: asset.id) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func validateDrop(info: DropInfo) -> Bool { store.draggedAsset != nil }
    func performDrop(info: DropInfo) -> Bool { let valid = store.draggedAsset != nil; store.draggedAsset = nil; return valid }
}

struct SearchView: View {
    @EnvironmentObject var store: AppStore
    @UIState private var query: String
    @UIState private var selectedMarket = "all"
    @UIState private var results: [Asset] = []
    @UIState private var searching = false
    @UIState private var error: String?
    @FocusState private var focused: Bool
    init(initialQuery: String = "") { _query = UIState(wrappedValue: initialQuery) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(store.t("Add symbol")).font(.title2.weight(.semibold))
                Spacer()
                Button(store.t("Done")) { store.showingSearch = false }.keyboardShortcut(.defaultAction)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(store.t("Name or symbol"), text: $query).textFieldStyle(.plain).focused($focused)
                if searching { ProgressView().controlSize(.small) }
            }.padding(10).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            Picker(store.t("Search"), selection: $selectedMarket) {
                Text(store.t("All markets")).tag("all")
                Text(store.t("US markets")).tag("us")
                Text(store.t("China")).tag("cn")
                Text(store.t("HK stocks")).tag("hk")
                Text(store.t("Crypto")).tag("crypto")
            }.pickerStyle(.segmented).labelsHidden()
            if let error {
                Label(store.t("Search failed"), systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if results.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: query.isEmpty ? "text.magnifyingglass" : "magnifyingglass").font(.system(size: 27, weight: .light)).foregroundStyle(.tertiary)
                    Text(store.t(query.isEmpty ? "Search by name or ticker" : (searching ? "Searching…" : "No matching symbols"))).font(.headline)
                    Text(store.t(query.isEmpty ? "Try AAPL, 600519, 00700, or BTC." : "Try another symbol or select a market.")).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { asset in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(asset.displayCode).font(TickerTypography.font(12, bold: true))
                                        Text(asset.exchange + " · " + store.t(asset.instrumentKind.title)).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Text(asset.displayName).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                let added = store.assets.contains(where: { $0.id == asset.id })
                                Button(store.t(added ? "Added" : "Add")) { store.add(asset) }.disabled(added).buttonStyle(.bordered)
                            }.padding(.vertical, 10)
                            Divider()
                        }
                    }
                }
            }
        }.padding(24).frame(width: 520, height: 460).background(Color(nsColor: .windowBackgroundColor))
            .onAppear { focused = true }
            .task(id: "\(query)|\(selectedMarket)|\(store.preferences.cryptoSource.rawValue)") {
                results = []; error = nil
                guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { searching = false; return }
                searching = true
                do {
                    try await Task.sleep(nanoseconds: 350_000_000)
                    let found = try await store.service.search(query, market: Market(rawValue: selectedMarket), cryptoSource: store.preferences.cryptoSource)
                    try Task.checkCancellation(); results = found; searching = false
                } catch is CancellationError {} catch {
                    if !Task.isCancelled { self.error = error.localizedDescription; searching = false }
                }
            }
    }
}

struct DetailView: View {
    @EnvironmentObject var store: AppStore
    let asset: Asset
    private var quote: Quote? { store.quotes[asset.id] }
    var body: some View {
        VStack(spacing: 0) {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(asset.symbol).font(TickerTypography.font(28, bold: true))
                    TickerTypography.text(asset.displayName + " · " + asset.market.label, size: 13).foregroundStyle(.secondary)
                }
                Spacer()
                Button(store.t("Done")) { store.selectedAsset = nil }.keyboardShortcut(.defaultAction)
            }
            if let quote {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(priceString(quote.price)).font(TickerTypography.font(34))
                    Text(quote.currency).font(TickerTypography.font(12)).foregroundStyle(.secondary)
                    Spacer()
                    Text(quote.percent.map { signed($0) + "%" } ?? "—").font(TickerTypography.font(18, bold: true)).foregroundStyle(quoteColor(quote, redUp: store.preferences.redUp))
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(store.t(asset.market == .crypto ? "Last 24 hours" : "Intraday"))
                        Spacer()
                        if quote.points.isEmpty || quote.chartError != nil { Text(store.t(quote.points.isEmpty ? "No chart data" : "Cached")).foregroundStyle(.orange) }
                    }.font(.caption).foregroundStyle(.secondary)
                    Sparkline(points: quote.points, reference: quote.reference, color: quoteColor(quote, redUp: store.preferences.redUp)).frame(height: 110)
                    HStack {
                        Text(quote.points.first.map { chartTime($0.date) } ?? "—")
                        Spacer()
                        Text(quote.points.last.map { chartTime($0.date) } ?? "—")
                    }.font(TickerTypography.font(10)).foregroundStyle(.tertiary)
                }.padding(16).background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                Grid(alignment: .leading, horizontalSpacing: 30, verticalSpacing: 10) {
                    metric(asset.market == .crypto ? "24h reference" : "Previous close", quote.reference)
                    metric("Open", quote.open)
                    metric(asset.market == .crypto ? "24h high" : "High", quote.high)
                    metric(asset.market == .crypto ? "24h low" : "Low", quote.low)
                    metric("Change", quote.change)
                }.font(.system(size: 12))
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    metadata("Source", quote.source + " · " + quote.pair)
                    metadata("Quote time", fullTime(quote.quotedAt))
                    metadata("Last successful request", fullTime(quote.fetchedAt))
                    metadata("Chart updated", fullTime(quote.chartFetchedAt))
                    if asset.market != .crypto {
                        metadata("Market hours", store.t(quote.session == .open ? "Market hours" : (quote.session == .breakTime ? "Trading break" : (quote.session == .closed ? "Outside regular hours" : "Unknown"))))
                        Text(store.t("Hours are a weekday estimate, not an exchange holiday calendar.")).font(.caption2).foregroundStyle(.tertiary)
                    }
                    if quote.isStale() { Label(store.t("Quote age exceeds 5 minutes during expected trading hours."), systemImage: "clock").font(.caption).foregroundStyle(.orange) }
                    if let chartError = quote.chartError { Text(store.t("History unavailable") + ": " + chartError).font(.caption).foregroundStyle(.orange) }
                }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "chart.xyaxis.line").font(.largeTitle).foregroundStyle(.tertiary)
                    Text(store.t("Quote unavailable")).font(.headline)
                    Text(store.t("Refresh to try again. Previous data stays visible when a feed fails.")).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 35)
            }
            if let error = store.errors[asset.id] { Label(error, systemImage: "wifi.slash").font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }.padding(26)
        }
        Divider()
        HStack {
            Button(store.t("Remove"), role: .destructive) { store.remove(asset) }
            Spacer()
            Button(store.t("Refresh")) { store.refreshNow() }.disabled(store.isRefreshing)
        }.padding(.horizontal, 26).padding(.vertical, 14)
        }.frame(width: 510, height: 650).background(Color(nsColor: .windowBackgroundColor))
    }
    private func metric(_ title: String, _ value: Double?) -> some View {
        GridRow { Text(store.t(title)).foregroundStyle(.secondary); Text(value.map { priceString($0) } ?? "—").font(TickerTypography.font(12)).frame(maxWidth: .infinity, alignment: .trailing) }
    }
    private func metadata(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(store.t(title)).foregroundStyle(.secondary); Spacer(); TickerTypography.text(value, size: 10).textSelection(.enabled).multilineTextAlignment(.trailing) }.font(.system(size: 10))
    }
    private func chartTime(_ date: Date) -> String {
        let f = DateFormatter(); f.timeZone = asset.market == .crypto ? .current : asset.market.timeZone; f.dateFormat = "MMM d, HH:mm"; return f.string(from: date)
    }
}

func priceString(_ value: Double) -> String {
    if value > 0 && value < 0.00000001 { return String(format: "%.4g", value) }
    let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "en_US")
    f.minimumFractionDigits = 2; f.maximumFractionDigits = value >= 1 ? 2 : (value >= 0.01 ? 4 : 8)
    return f.string(from: NSNumber(value: value)) ?? "—"
}
func signed(_ value: Double) -> String { String(format: "%+.2f", value) }
func fullTime(_ date: Date?) -> String { date?.formatted(date: .abbreviated, time: .standard) ?? "—" }
func quoteColor(_ quote: Quote?, redUp: Bool) -> Color {
    guard let change = quote?.change, change != 0 else { return .secondary }
    return (change > 0) == redUp ? .red : .green
}
