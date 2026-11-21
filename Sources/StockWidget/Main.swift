import AppKit
import SwiftUI
import MarketCore

@main
struct StockWidgetMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var store: AppStore!
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var systemSleeping = false
    private var screenLocked = false
    private var compactWidth = CompactLayout.width
    private var snapController: WindowSnapController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        let smoke = arguments.contains("--smoke-test")
        var directory: URL?
        if let index = arguments.firstIndex(of: "--state-dir"), arguments.indices.contains(index + 1) { directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true) }
        if smoke && directory == nil { directory = FileManager.default.temporaryDirectory.appendingPathComponent("StockWidget-smoke-\(UUID().uuidString)", isDirectory: true) }
        store = AppStore(directory: directory)
        if smoke {
            store.assets = [
                Asset(market: .us, symbol: "AAPL", name: "Apple Inc."),
                Asset(market: .cn, symbol: "600519", name: "贵州茅台", lookup: "sh600519"),
                Asset(market: .hk, symbol: "00700", name: "腾讯控股", lookup: "hk00700"),
                Asset(market: .crypto, symbol: "BTC", name: "Bitcoin"),
                Asset(market: .crypto, symbol: "ETH", name: "Ethereum")
            ]
            if arguments.contains("--nasdaq-quotes") {
                store.assets.replaceSubrange(0...1, with: [USIndexCatalog.exactMatch("IXIC")!, USIndexCatalog.exactMatch("NDX")!])
            }
            if arguments.contains("--okb-quotes") {
                store.assets.replaceSubrange(0...0, with: [Asset(market: .crypto, symbol: "OKB", name: "OKB")])
            }
            if arguments.contains("--showcase") {
                store.assets = [
                    Asset(market: .cn, symbol: "000001", name: "SSE Composite", lookup: "sh000001", kind: .index),
                    Asset(market: .us, symbol: "IXIC", name: "Nasdaq Comp.", lookup: "^IXIC", kind: .index),
                    Asset(market: .cn, symbol: "688836", name: "Unitree", lookup: "sh688836"),
                    Asset(market: .us, symbol: "INTC", name: "Intel"),
                    Asset(market: .crypto, symbol: "BTC", name: "Bitcoin"),
                    Asset(market: .crypto, symbol: "ETH", name: "Ethereum"),
                    Asset(market: .crypto, symbol: "OKB", name: "OKB")
                ]
            }
        }
        if arguments.contains("--chinese") { store.preferences.language = .zh }
        if arguments.contains("--always-on-top") { store.preferences.alwaysOnTop = true }
        let searchQueryIndex = arguments.firstIndex(of: "--search-query")
        let initialSearchQuery = smoke ? searchQueryIndex.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "" : ""
        let root = WatchlistView(initialSearchQuery: initialSearchQuery).environmentObject(store)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: CompactLayout.width, height: CompactLayout.height(for: store.assets.count)), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "StockWidget"
        if smoke && arguments.contains("--showcase") { window.appearance = NSAppearance(named: .darkAqua) }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.isExcludedFromWindowsMenu = true
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(button)?.isHidden = true }
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: CompactLayout.minimumWidth, height: 56)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = [.minSize]
        window.contentView = hosting
        snapController = WindowSnapController(window: window, saveGeometry: !smoke)
        store.onPrepareWindowDrag = { [weak self] in self?.snapController.prepareForPress() }
        store.onBeginWindowDrag = { [weak self] event in self?.snapController.begin(with: event) }
        store.onFinishWindowDrag = { [weak self] in self?.snapController.finish() }
        window.delegate = self
        window.center()
        if !smoke {
            if window.setFrameUsingName("StockWidget.compact.v1") { compactWidth = max(CompactLayout.minimumWidth, window.frame.width) }
            else { _ = window.setFrameUsingName("StockWidget.main") }
            window.setFrameAutosaveName("StockWidget.compact.v1")
        }
        fitWindowToContent()
        store.onPreferencesChanged = { [weak self] in self?.applyPreferences() }
        store.onWatchlistChanged = { [weak self] in self?.fitWindowToContent() }
        store.onReturnToWatchlist = { [weak self] in
            DispatchQueue.main.async { self?.fitWindowToContent() }
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "chart.xyaxis.line", accessibilityDescription: "StockWidget")
        statusItem.button?.image?.isTemplate = true
        applyPreferences()
        installMainMenu()
        installNotifications()
        showWindow()
        if smoke { runSmoke(arguments) } else { store.start() }
    }
    private func ensureOnScreen() {
        guard !NSScreen.screens.contains(where: { $0.visibleFrame.intersection(window.frame).width >= 100 && $0.visibleFrame.intersection(window.frame).height >= 100 }) else { return }
        window.center()
    }
    private func fitWindowToContent() {
        guard window.attachedSheet == nil else { return }
        var frame = window.frame
        let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame
        let height = min(CompactLayout.height(for: store.assets.count), visibleFrame?.height ?? 600)
        let top = min(frame.maxY, visibleFrame?.maxY ?? frame.maxY)
        frame.origin.y = max(top - height, visibleFrame?.minY ?? top - height)
        frame.size = NSSize(width: compactWidth, height: height)
        window.setFrame(frame, display: true)
        ensureOnScreen()
    }
    private func applyPreferences() {
        guard window != nil, statusItem != nil else { return }
        // stationary excludes the widget from Mission Control's desktop-reveal
        // animation; joining all apps keeps Stage Manager from shelving it.
        // This is independent of whether the user chooses floating window level.
        // fullScreenPrimary opts out of joining another app's full-screen
        // Space while canJoinAllApplications keeps Stage Manager from shelving it.
        window.collectionBehavior = [.stationary, .ignoresCycle, .canJoinAllApplications, .fullScreenPrimary]
        window.hidesOnDeactivate = false
        window.level = store.preferences.alwaysOnTop ? .floating : .normal
        let menu = NSMenu()
        let toggle = NSMenuItem(title: store.t(window.isVisible ? "Hide Watchlist" : "Show Watchlist"), action: #selector(toggleWindow), keyEquivalent: "")
        toggle.target = self; menu.addItem(toggle)
        let refresh = NSMenuItem(title: store.t("Refresh"), action: #selector(refresh), keyEquivalent: "r"); refresh.target = self; menu.addItem(refresh)
        let add = NSMenuItem(title: store.t("Add symbol"), action: #selector(addSymbol), keyEquivalent: "n"); add.target = self; menu.addItem(add)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: store.t("Settings") + "…", action: #selector(showSettings), keyEquivalent: ","); settings.target = self; menu.addItem(settings)
        let pin = NSMenuItem(title: store.t("Always on top"), action: #selector(toggleAlwaysOnTop), keyEquivalent: "")
        pin.target = self; pin.state = store.preferences.alwaysOnTop ? .on : .off; menu.addItem(pin)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: store.t("Quit StockWidget"), action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        statusItem.menu = menu
    }
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: store.t("Add symbol") + "…", action: #selector(addSymbol), keyEquivalent: "n").target = self
        appMenu.addItem(withTitle: store.t("Refresh"), action: #selector(refresh), keyEquivalent: "r").target = self
        appMenu.addItem(withTitle: "Hide Window", action: #selector(hideWindow), keyEquivalent: "w").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit StockWidget", action: #selector(quitApp), keyEquivalent: "q").target = self
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); main.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        for (title, action, key) in [("Undo", Selector(("undo:")), "z"), ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] { edit.addItem(withTitle: title, action: action, keyEquivalent: key) }
        NSApp.mainMenu = main
    }
    private func installNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(waking), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(waking), name: NSWorkspace.screensDidWakeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(locked), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(unlocked), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
    }
    @objc private func sleeping() { systemSleeping = true; store.suspended = true }
    @objc private func waking() { systemSleeping = false; store.suspended = screenLocked }
    @objc private func locked() { screenLocked = true; store.suspended = true }
    @objc private func unlocked() { screenLocked = false; store.suspended = systemSleeping }
    @objc private func toggleWindow() { if window.isVisible { window.orderOut(nil); updateVisibility() } else { showWindow() } }
    @objc private func hideWindow() { window.orderOut(nil); updateVisibility() }
    @objc private func toggleAlwaysOnTop() { store.preferences.alwaysOnTop.toggle() }
    @objc private func refresh() { store.refreshNow() }
    @objc private func addSymbol() { showWindow(); store.showingSearch = true }
    @objc private func showSettings() { showWindow(); store.showingSettings = true }
    @objc private func quitApp() { NSApp.terminate(nil) }
    private func showWindow() { window.deminiaturize(nil); window.makeKeyAndOrderFront(nil); NSApp.activate(); updateVisibility() }
    private func updateVisibility() { store.windowVisible = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible); applyPreferences() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); updateVisibility(); return false }
    func windowDidChangeOcclusionState(_ notification: Notification) { updateVisibility() }
    func windowDidMiniaturize(_ notification: Notification) { updateVisibility() }
    func windowDidDeminiaturize(_ notification: Notification) { updateVisibility() }
    func windowWillMove(_ notification: Notification) { snapController?.nativeMoveStarted() }
    func windowDidMove(_ notification: Notification) { snapController?.windowMoved() }
    func windowDidEndLiveResize(_ notification: Notification) { compactWidth = max(CompactLayout.minimumWidth, window.frame.width) }
    func windowDidEndSheet(_ notification: Notification) { DispatchQueue.main.async { [weak self] in self?.fitWindowToContent() } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationWillTerminate(_ notification: Notification) { store.persist() }

    private func runSmoke(_ args: [String]) {
        Task {
            if !args.contains("--cached-ui") { await store.refresh(force: true) }
            var storeChecksPassed = true
            if args.contains("--exercise-store") {
                let originalAssets = store.assets, originalQuotes = store.quotes, originalPreferences = store.preferences
                if let first = originalAssets.first, let last = originalAssets.last {
                    store.move(last.id, before: first.id)
                    storeChecksPassed = store.assets.first?.id == last.id
                    store.remove(last)
                    storeChecksPassed = storeChecksPassed && !store.assets.contains(last) && store.quotes[last.id] == nil
                    store.add(last)
                    store.preferences.alwaysOnTop = true
                    storeChecksPassed = storeChecksPassed && window.level == .floating
                    store.preferences.language = .zh
                    storeChecksPassed = storeChecksPassed && store.t("Watchlist") == "自选行情"
                    do {
                        let restored = try StateFile(url: URL(fileURLWithPath: store.stateLocation)).load()
                        storeChecksPassed = storeChecksPassed && restored.assets == store.assets && restored.preferences.language == .zh
                    } catch { storeChecksPassed = false }
                }
                store.assets = originalAssets; store.quotes = originalQuotes; store.preferences = originalPreferences; store.persist()
                print("STORE_SMOKE pass=\(storeChecksPassed)")
            }
            if args.contains("--exercise-compact") {
                // Route clicks only to this application's own window, including
                // the first row where a hidden native title bar could intercept them.
                let point = NSPoint(x: 35, y: window.frame.height - 6 - CompactLayout.rowHeight / 2)
                for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
                try? await Task.sleep(nanoseconds: 600_000_000)
                storeChecksPassed = storeChecksPassed && store.selectedAsset?.id == store.assets.first?.id && window.attachedSheet != nil
                store.selectedAsset = nil
                try? await Task.sleep(nanoseconds: 600_000_000)
                fitWindowToContent()
                storeChecksPassed = storeChecksPassed && window.frame.width == compactWidth && window.frame.height <= CompactLayout.height(for: store.assets.count) + 1
                store.showingSearch = true
                try? await Task.sleep(nanoseconds: 500_000_000)
                storeChecksPassed = storeChecksPassed && window.attachedSheet != nil
                let added = (store.assets.count..<9).map { Asset(market: .us, symbol: "TEST\($0)", name: "Smoke test") }
                for asset in added { store.add(asset) }
                store.showingSearch = false
                try? await Task.sleep(nanoseconds: 600_000_000)
                let expectedHeight = min(CompactLayout.height(for: 9), window.screen?.visibleFrame.height ?? 600)
                storeChecksPassed = storeChecksPassed && window.frame.width == compactWidth && abs(window.frame.height - expectedHeight) <= 1
                for asset in added { store.remove(asset) }
                let restoredHeight = min(CompactLayout.height(for: store.assets.count), window.screen?.visibleFrame.height ?? 600)
                storeChecksPassed = storeChecksPassed && abs(window.frame.height - restoredHeight) <= 1
                print("COMPACT_SMOKE pass=\(storeChecksPassed) size=\(Int(window.frame.width))x\(Int(window.frame.height))")
            }
            if args.contains("--exercise-desktop") {
                let original = store.preferences.alwaysOnTop
                let required: NSWindow.CollectionBehavior = [.stationary, .ignoresCycle, .canJoinAllApplications, .fullScreenPrimary]
                for pinned in [false, true] {
                    store.preferences.alwaysOnTop = pinned
                    storeChecksPassed = storeChecksPassed && window.collectionBehavior.isSuperset(of: required) && !window.hidesOnDeactivate
                    storeChecksPassed = storeChecksPassed && !window.collectionBehavior.contains(.canJoinAllSpaces) && !window.collectionBehavior.contains(.moveToActiveSpace)
                    storeChecksPassed = storeChecksPassed && !window.collectionBehavior.contains(.fullScreenAuxiliary) && !window.styleMask.contains(.fullScreen)
                    storeChecksPassed = storeChecksPassed && window.level == (pinned ? .floating : .normal)
                }
                let frame = window.frame
                NSApp.deactivate()
                try? await Task.sleep(nanoseconds: 300_000_000)
                storeChecksPassed = storeChecksPassed && window.isVisible && window.frame == frame
                hideWindow()
                storeChecksPassed = storeChecksPassed && !window.isVisible
                showWindow()
                storeChecksPassed = storeChecksPassed && window.isVisible
                store.preferences.alwaysOnTop = original
                print("DESKTOP_SMOKE pass=\(storeChecksPassed) stationary=\(window.collectionBehavior.contains(.stationary)) singleSpace=\(!window.collectionBehavior.contains(.canJoinAllSpaces) && !window.collectionBehavior.contains(.moveToActiveSpace))")
            }
            if args.contains("--exercise-drag") {
                let interactions = await InteractionChecks.run(window: window, store: store, snap: snapController)
                storeChecksPassed = storeChecksPassed && interactions
                print("INTERACTION_SMOKE pass=\(interactions)")
            }
            var expectedSheet = false
            var expectedErrors = 0
            if let i = args.firstIndex(of: "--screen"), args.indices.contains(i + 1) {
                switch args[i + 1] {
                case "settings": store.showingSettings = true; expectedSheet = true
                case "search": store.showingSearch = true; expectedSheet = true
                case "detail": store.selectedAsset = store.assets.first; expectedSheet = true
                case "empty": store.assets = []; fitWindowToContent()
                case "offline":
                    if let asset = store.assets.first { store.errors[asset.id] = "Offline UI validation: retaining the last valid quote"; expectedErrors = 1 }
                default: break
                }
            }
            let settleIndex = args.firstIndex(of: "--settle-seconds")
            let settleSeconds = settleIndex.flatMap { args.indices.contains($0 + 1) ? UInt64(args[$0 + 1]) : nil } ?? 1
            try? await Task.sleep(nanoseconds: min(max(settleSeconds, 1), 20) * 1_000_000_000)
            var exitCode: Int32 = 0
            if let i = args.firstIndex(of: "--capture"), args.indices.contains(i + 1) {
                do {
                    guard let view = window.attachedSheet?.contentView ?? window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw FeedError.invalid("Window capture") }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    guard let png = rep.representation(using: .png, properties: [:]) else { throw FeedError.invalid("PNG capture") }
                    try png.write(to: URL(fileURLWithPath: args[i + 1]))
                } catch { print("UI_CAPTURE_FAIL \(error)"); exitCode = 1 }
            }
            print("UI_SMOKE window=\(window.isVisible) rows=\(store.assets.count) quotes=\(store.quotes.count) errors=\(store.errors.count) language=\(store.preferences.language.rawValue) size=\(Int(window.frame.width))x\(Int(window.frame.height))")
            for asset in store.assets {
                if let q = store.quotes[asset.id] { print("\(asset.symbol): \(q.source) \(q.price) \(q.currency) chart=\(q.points.count)") }
                else { print("\(asset.symbol): \(store.errors[asset.id] ?? "No quote")") }
            }
            let expectedQuotes = args.contains("--showcase") ? 7 : 5
            let expectedRows = args.contains("empty") ? 0 : expectedQuotes
            if !window.isVisible || store.assets.count != expectedRows || store.quotes.count != expectedQuotes || store.errors.count != expectedErrors || !storeChecksPassed { exitCode = 1 }
            if args.contains("--showcase") && store.assets.contains(where: { store.quotes[$0.id]?.chartError != nil || (store.quotes[$0.id]?.points.count ?? 0) < 2 }) {
                print("UI_SMOKE_FAIL showcase needs real prices and charts for every symbol"); exitCode = 1
            }
            if expectedSheet && window.attachedSheet == nil { print("UI_SMOKE_FAIL expected sheet was not presented"); exitCode = 1 }
            if !expectedSheet && (window.frame.height > CompactLayout.height(for: store.assets.count) + 1 || window.frame.width > CompactLayout.width + 1) {
                print("UI_SMOKE_FAIL compact layout left excess window space"); exitCode = 1
            }
            fflush(stdout)
            if let i = args.firstIndex(of: "--hold-seconds"), args.indices.contains(i + 1), let seconds = UInt64(args[i + 1]) {
                try? await Task.sleep(nanoseconds: min(seconds, 120) * 1_000_000_000)
            }
            Foundation.exit(exitCode)
        }
    }
}
