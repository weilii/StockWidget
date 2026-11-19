import AppKit
import SwiftUI
import CoreGraphics
import MarketCore

struct PointerMenuAction {
    var title: String
    var symbol: String?
    var checked: Bool?
    var action: () -> Void
    init(_ title: String, symbol: String? = nil, checked: Bool? = nil, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.checked = checked; self.action = action
    }
}

struct RowPointerSurface: NSViewRepresentable {
    var label: String
    var tooltip: String
    var click: () -> Void
    var prepare: () -> Void
    var drag: (NSEvent) -> Void
    var finish: () -> Void
    var actions: [PointerMenuAction]

    func makeNSView(context: Context) -> RowPointerView { RowPointerView() }
    func updateNSView(_ view: RowPointerView, context: Context) {
        view.label = label; view.toolTip = tooltip
        view.click = click; view.prepare = prepare; view.drag = drag; view.finish = finish; view.actions = actions
    }
}

final class RowPointerView: NSView {
    var label = ""
    var click: () -> Void = {}
    var prepare: () -> Void = {}
    var drag: (NSEvent) -> Void = { _ in }
    var finish: () -> Void = {}
    var actions: [PointerMenuAction] = []
    private var intent = PointerIntent()
    private var mouseDownEvent: NSEvent?

    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func screenPoint(_ event: NSEvent) -> CGPoint { window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow }
    override func mouseDown(with event: NSEvent) {
        prepare()
        mouseDownEvent = event
        intent.begin(at: screenPoint(event))
    }
    override func mouseDragged(with event: NSEvent) {
        if intent.move(to: screenPoint(event)), let original = mouseDownEvent { drag(original) }
    }
    override func mouseUp(with event: NSEvent) {
        let activate = intent.end(at: screenPoint(event))
        mouseDownEvent = nil
        if activate { click() } else { finish() }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { click() } else { super.keyDown(with: event) }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { label }
    override func accessibilityPerformPress() -> Bool { click(); return true }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (index, entry) in actions.enumerated() {
            if index == 3 { menu.addItem(.separator()) }
            let item = NSMenuItem(title: entry.title, action: #selector(invokeMenuItem(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = index
            if let symbol = entry.symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            if let checked = entry.checked { item.state = checked ? .on : .off }
            menu.addItem(item)
        }
        return menu
    }
    @objc private func invokeMenuItem(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int, actions.indices.contains(index) else { return }
        actions[index].action()
    }
}

struct ReorderHandle: NSViewRepresentable {
    let identifier: String
    let label: String
    var prepare: () -> Void
    var began: () -> Void
    var ended: () -> Void
    func makeNSView(context: Context) -> ReorderHandleView { ReorderHandleView() }
    func updateNSView(_ view: ReorderHandleView, context: Context) {
        view.assetIdentifier = identifier; view.toolTip = label
        view.prepare = prepare; view.began = began; view.ended = ended
    }
}

final class ReorderHandleView: NSView, NSDraggingSource {
    var assetIdentifier = ""
    var prepare: () -> Void = {}
    var began: () -> Void = {}
    var ended: () -> Void = {}
    private var down: NSEvent?
    private var intent = PointerIntent()
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.65).setStroke()
        let lines = NSBezierPath(); lines.lineWidth = 1.2; lines.lineCapStyle = .round
        for offset in [-3.0, 0, 3.0] {
            lines.move(to: NSPoint(x: bounds.midX - 3.5, y: bounds.midY + offset))
            lines.line(to: NSPoint(x: bounds.midX + 3.5, y: bounds.midY + offset))
        }
        lines.stroke()
    }
    override func mouseDown(with event: NSEvent) {
        prepare(); down = event; intent.begin(at: event.locationInWindow)
    }
    override func mouseDragged(with event: NSEvent) {
        guard intent.move(to: event.locationInWindow), let down else { return }
        self.down = nil
        let item = NSPasteboardItem(); item.setString(assetIdentifier, forType: .string)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil) ?? NSImage(size: NSSize(width: 12, height: 12))
        dragging.setDraggingFrame(NSRect(x: 0, y: bounds.midY - 7, width: 14, height: 14), contents: image)
        began()
        beginDraggingSession(with: [dragging], event: down, source: self)
    }
    override func mouseUp(with event: NSEvent) { down = nil; _ = intent.end(at: event.locationInWindow) }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { ended() }
}

@MainActor
final class WindowSnapController {
    private weak var window: NSWindow?
    private var releaseMonitor: Task<Void, Never>?
    private var animation: Task<Void, Never>?
    private var preview: NSWindow?
    private var neighbors: [CGRect] = []
    private(set) var isDragging = false
    private var animating = false
    private let saveGeometry: Bool

    init(window: NSWindow, saveGeometry: Bool = true) { self.window = window; self.saveGeometry = saveGeometry }
    func desktopGuideCount() -> Int { Self.desktopWidgetFrames(excluding: ProcessInfo.processInfo.processIdentifier).count }
    func prepareForPress() {
        releaseMonitor?.cancel(); releaseMonitor = nil
        animation?.cancel(); animation = nil
        isDragging = false; animating = false; preview?.orderOut(nil)
    }
    func begin(with event: NSEvent) {
        guard let window, window.attachedSheet == nil else { return }
        startTracking()
        window.performDrag(with: event)
    }
    func nativeMoveStarted() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
        startTracking()
    }
    private func startTracking() {
        guard !isDragging, window != nil else { return }
        animation?.cancel(); animation = nil; animating = false
        neighbors = Self.desktopWidgetFrames(excluding: ProcessInfo.processInfo.processIdentifier)
        isDragging = true
        releaseMonitor?.cancel()
        releaseMonitor = Task { [weak self] in
            // performDrag can consume mouse-up. Track only while a drag is active.
            do { try await Task.sleep(nanoseconds: 24_000_000) } catch { return }
            while NSEvent.pressedMouseButtons & 1 != 0 {
                do { try await Task.sleep(nanoseconds: 24_000_000) } catch { return }
            }
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }
    func windowMoved() {
        guard isDragging, !animating, let window, let target = snapTarget() else { return }
        guard hypot(target.minX - window.frame.minX, target.minY - window.frame.minY) > 0.5 else { preview?.orderOut(nil); return }
        if preview == nil {
            let hint = NSWindow(contentRect: target, styleMask: .borderless, backing: .buffered, defer: false)
            hint.isOpaque = false; hint.backgroundColor = .clear; hint.hasShadow = false
            hint.ignoresMouseEvents = true
            hint.collectionBehavior = [.stationary, .ignoresCycle, .canJoinAllApplications, .fullScreenPrimary]
            hint.contentView = NSHostingView(rootView:
                RoundedRectangle(cornerRadius: 15)
                    .fill(Color.accentColor.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.accentColor.opacity(0.55), lineWidth: 2))
                    .padding(1))
            preview = hint
        }
        preview?.level = NSWindow.Level(rawValue: window.level.rawValue)
        preview?.setFrame(target, display: true)
        preview?.order(.below, relativeTo: window.windowNumber)
    }
    private func snapTarget() -> CGRect? {
        guard let window else { return nil }
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? window.screen ?? NSScreen.main
        guard let screen else { return nil }
        return WindowSnapping.frame(window.frame, in: screen.visibleFrame, neighbors: neighbors)
    }
    func finish() {
        guard isDragging, let window else { return }
        isDragging = false
        releaseMonitor?.cancel(); releaseMonitor = nil
        preview?.orderOut(nil)
        guard let target = snapTarget() else { return }
        let origin = window.frame
        guard hypot(target.minX - origin.minX, target.minY - origin.minY) > 0.5 else {
            if saveGeometry { window.saveFrame(usingName: "StockWidget.compact.v1") }; return
        }
        settle(to: target)
    }
    func settle(to target: CGRect) {
        guard let window else { return }
        let origin = window.frame
        animation?.cancel()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            window.setFrame(target, display: true)
            if saveGeometry { window.saveFrame(usingName: "StockWidget.compact.v1") }; return
        }
        animating = true
        animation = Task { [weak self, weak window] in
            let started = Date()
            while let window {
                if Task.isCancelled { return }
                let elapsed = Date().timeIntervalSince(started) / 0.28
                if elapsed >= 1 { break }
                let p = WindowSnapping.springProgress(elapsed)
                var frame = origin
                frame.origin.x += (target.minX - origin.minX) * p
                frame.origin.y += (target.minY - origin.minY) * p
                window.setFrame(frame, display: true)
                do { try await Task.sleep(nanoseconds: 16_000_000) } catch { return }
            }
            window?.setFrame(target, display: true)
            if self?.saveGeometry == true { window?.saveFrame(usingName: "StockWidget.compact.v1") }
            self?.animating = false
        }
    }
    private static func desktopWidgetFrames(excluding pid: Int32) -> [CGRect] {
        guard let top = NSScreen.screens.first?.frame.maxY,
              let entries = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard (entry[kCGWindowOwnerPID as String] as? Int32) != pid,
                  let owner = entry[kCGWindowOwnerName as String] as? String,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"] else { return nil }
            let host = owner.lowercased()
            guard layer < 0, host.contains("notification") || host.contains("widget") || host.contains("chronod") || owner.contains("通知中心") else { return nil }
            guard width >= 100, height >= 80, width <= 900, height <= 900 else { return nil }
            // Desktop WidgetKit hosts include an 8pt transparent margin around
            // their visible card. Align the cards rather than that host padding.
            return CGRect(x: x, y: top - y - height, width: width, height: height).insetBy(dx: 8, dy: 8)
        }
    }
}
