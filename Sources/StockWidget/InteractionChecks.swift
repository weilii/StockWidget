import AppKit
import MarketCore

@MainActor
enum InteractionChecks {
    static func run(window: NSWindow, store: AppStore, snap: WindowSnapController) async -> Bool {
        guard let root = window.contentView else { return false }
        func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
        let views = allViews(root)
        guard let pointer = views.compactMap({ $0 as? RowPointerView }).first,
              let handle = views.compactMap({ $0 as? ReorderHandleView }).first else { return false }
        print("SNAP_GUIDES desktopWidgets=\(snap.desktopGuideCount())")
        let originalClick = pointer.click, originalDrag = pointer.drag, originalFinish = pointer.finish, originalPrepare = pointer.prepare
        var clicks = 0, drags = 0
        pointer.click = { clicks += 1 }; pointer.drag = { _ in drags += 1 }; pointer.finish = {}; pointer.prepare = {}
        defer { pointer.click = originalClick; pointer.drag = originalDrag; pointer.finish = originalFinish; pointer.prepare = originalPrepare }
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        let p = NSPoint(x: 40, y: window.frame.height - 28)
        pointer.mouseDown(with: event(.leftMouseDown, p))
        pointer.mouseUp(with: event(.leftMouseUp, p))
        guard clicks == 1 else { return false }
        pointer.mouseDown(with: event(.leftMouseDown, p))
        pointer.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: p.x + 30, y: p.y)))
        pointer.mouseUp(with: event(.leftMouseUp, p))
        guard clicks == 1 && drags == 1 else { return false }
        pointer.mouseDown(with: event(.leftMouseDown, p))
        pointer.mouseUp(with: event(.leftMouseUp, NSPoint(x: p.x + 30, y: p.y)))
        guard clicks == 1 && !pointer.mouseDownCanMoveWindow && !handle.mouseDownCanMoveWindow else { return false }
        guard pointer.menu(for: event(.rightMouseDown, p))?.items.count ?? 0 >= 7 else { return false }
        let font = NSFont(name: "Courier", size: 12)!
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        guard abs(("1111" as NSString).size(withAttributes: attrs).width - ("WWWW" as NSString).size(withAttributes: attrs).width) < 0.1 else { return false }
        let frame = window.frame
        var target = frame; target.origin.x += 12; target.origin.y += 8
        snap.settle(to: target)
        try? await Task.sleep(nanoseconds: 450_000_000)
        let settled = abs(window.frame.minX - target.minX) < 0.5 && abs(window.frame.minY - target.minY) < 0.5 && store.selectedAsset == nil
        window.setFrame(frame, display: true)
        return settled
    }
}
