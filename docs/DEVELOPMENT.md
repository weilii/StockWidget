# Development

StockWidget is a Swift package targeting macOS 14+. The downloadable release targets Apple silicon; Intel execution has not been verified.

## Prerequisites and build

Install Xcode or Command Line Tools with **Swift 6 or later** and the macOS SDK. The package uses Swift 5 language mode with a Swift 6 package manifest.

```sh
zsh scripts/build-app.sh
open dist/StockWidget.app
```

The script builds in release mode, assembles the application bundle, generates its icon, and applies and verifies a local ad-hoc signature. It does not use a paid developer account or perform Apple notarization. Build on an arm64 Mac to reproduce the downloadable architecture.

To build into a separate location while another copy is running:

```sh
zsh scripts/build-app.sh "$PWD/output/StockWidget.app"
```

## Layout

| Path | Purpose |
| --- | --- |
| `Sources/MarketCore` | Instruments, quote parsing, sources, search, persistence, refresh policy, and snapping geometry |
| `Sources/StockWidget` | Native application, menu bar, desktop window, preferences, SwiftUI views, and pointer interactions |
| `Sources/StockWidgetCheck` | Offline regression checks and opt-in live checks |
| `scripts` | Build, icon generation, native UI smoke checks, and documentation capture |
| `packaging/Info.plist` | Bundle metadata and minimum macOS version |

There are no third-party package dependencies. `UIState` explicitly selects the SwiftUI property wrapper to avoid a same-named macro in newer SDKs whose plugin may be absent from Command Line Tools.

## Verification

Run offline checks:

```sh
swift run StockWidgetCheck
```

These cover quote units, exchange timestamps, rolling references, malformed and sparse history, index identities, search mapping, provider selection, persistence compatibility, refresh scheduling, pointer intent, and window snapping.

Live checks use the current network and may fail if a provider is unavailable:

```sh
swift run StockWidgetCheck --live
swift run StockWidgetCheck --live-index-search
swift run StockWidgetCheck --live-nasdaq-search
swift run StockWidgetCheck --live-okb
```

For native view states, compact layout, ordering, storage, menu actions, desktop window properties, dragging, and a short idle resource sample:

```sh
python3 scripts/smoke-ui.py
# Or use a separately built app:
python3 scripts/smoke-ui.py --app output/StockWidget.app
```

Smoke runs use temporary state and capture only the application's own views. They do not replace the everyday watchlist. The periodic quote scheduler is disabled during smoke captures. The resource sample is not a measurement of sustained polling, battery use, or total memory footprint. Window-property checks do not automate macOS Space gestures, actual sleep, or system login-item approval.

## Reproduce the README screenshot

```sh
python3 scripts/capture-readme.py
# Or use a separately built app:
python3 scripts/capture-readme.py --app output/StockWidget.app
```

This launches the actual application in an isolated smoke session with Shanghai Composite, Nasdaq Composite, Unitree, Intel, Bitcoin, Ethereum, and OKB, in that order. It fetches real quotes and charts, uses concise English labels and dark appearance, and writes `docs/assets/stockwidget.png`. It fails if any of the seven quotes or charts is missing. Prices are captured data, never generated fixtures. English labels apply to this showcase only; normal searches retain provider names.

Additional isolated capture options:

```sh
mkdir -p output
dist/StockWidget.app/Contents/MacOS/StockWidget \
  --smoke-test --screen search --search-query OKB \
  --settle-seconds 12 --capture "$PWD/output/search.png"
```

Available screens are `settings`, `search`, `detail`, `empty`, and `offline`. `--chinese` switches UI language. `--nasdaq-quotes` and `--okb-quotes` change the smoke inputs. `--settle-seconds` allows 1–20 seconds before capture. These options do not populate the normal watchlist.

## Data behavior

- Yahoo supplies US stock and supported Nasdaq index prices and intraday charts. Index response symbols and instrument types are checked; index levels display PTS.
- Tencent supplies mainland/Hong Kong quotes, search, and intraday history. Exchange-qualified IDs distinguish the Shanghai Composite from Ping An Bank despite their shared numeric code.
- Coinbase uses USD; Binance and OKX use USDT. Price, reference, and history stay with the same exchange/pair. Source timestamps are stored separately from request times.
- Crypto search uses live spot-product catalogs with six-hour caching. Exact symbols/aliases return when a matching pair is confirmed; outstanding catalog requests are canceled. Automatic quote selection remembers the last successful exchange and considers known listings for new additions.
- Failed requests preserve cached prices. A missing chart is reported separately. Weekday session estimates are not a full exchange calendar.

The app uses the system network/proxy configuration. Regional reachability and upstream data freshness cannot be inferred from a successful HTTP request.

## Contributions

Keep changes focused and run checks relevant to the change. For parser changes, add a small response fixture covering the failure or ambiguity. For UI changes, capture the actual native view using isolated state. Keep credentials, personal watchlists, logs, and build products out of commits.

Useful provider references: [Coinbase](https://docs.cdp.coinbase.com/exchange/introduction/welcome), [Binance public market data](https://developers.binance.com/docs/binance-spot-api-docs/faqs/market_data_only), and [OKX API documentation](https://www.okx.com/docs-v5/en/).
