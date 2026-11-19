import Foundation
import CoreGraphics

/// Geometry only: no screen capture, accessibility access or window manipulation.
public enum WindowSnapping {
    public static func frame(_ frame: CGRect, in visible: CGRect, neighbors: [CGRect], gap: CGFloat = 16, threshold: CGFloat = 18) -> CGRect {
        guard frame.width > 0, frame.height > 0, visible.width > 0, visible.height > 0 else { return frame }
        let inset = min(gap, max(0, (min(visible.width, visible.height) - 1) / 2))
        let area = visible.insetBy(dx: inset, dy: inset)
        var xs = [area.minX, area.maxX - frame.width]
        var ys = [area.minY, area.maxY - frame.height]
        let candidates = neighbors.filter { !$0.isEmpty && !$0.isInfinite && $0.intersects(visible) }
        for rect in candidates {
            xs += [rect.minX, rect.maxX - frame.width, rect.maxX + gap, rect.minX - gap - frame.width]
            ys += [rect.minY, rect.maxY - frame.height, rect.maxY + gap, rect.minY - gap - frame.height]
        }
        func closest(_ values: [CGFloat], to value: CGFloat) -> CGFloat? {
            values.filter { abs($0 - value) <= threshold }.min { abs($0 - value) < abs($1 - value) }
        }
        let x = closest(xs, to: frame.minX), y = closest(ys, to: frame.minY)
        func clamped(_ rect: CGRect) -> CGRect {
            var result = rect
            result.origin.x = min(max(result.minX, area.minX), max(area.minX, area.maxX - result.width))
            result.origin.y = min(max(result.minY, area.minY), max(area.minY, area.maxY - result.height))
            return result
        }
        func increasesOverlap(_ rect: CGRect) -> Bool {
            candidates.contains { neighbor in
                let before = frame.intersection(neighbor), after = rect.intersection(neighbor)
                let oldArea = before.isNull ? 0 : before.width * before.height
                let newArea = after.isNull ? 0 : after.width * after.height
                return newArea > oldArea + 1
            }
        }
        var result = clamped(CGRect(origin: CGPoint(x: x ?? frame.minX, y: y ?? frame.minY), size: frame.size))
        if increasesOverlap(result) {
            let alternatives = [
                clamped(CGRect(origin: CGPoint(x: x ?? frame.minX, y: frame.minY), size: frame.size)),
                clamped(CGRect(origin: CGPoint(x: frame.minX, y: y ?? frame.minY), size: frame.size))
            ].filter { !increasesOverlap($0) }
            result = alternatives.min {
                hypot($0.minX - frame.minX, $0.minY - frame.minY) < hypot($1.minX - frame.minX, $1.minY - frame.minY)
            } ?? clamped(frame)
        }
        return result
    }

    /// A short damped response, with a small overshoot and an exact final value.
    public static func springProgress(_ progress: Double) -> Double {
        if progress <= 0 { return 0 }
        if progress >= 1 { return 1 }
        let damping = 7.2, frequency = 10.0
        return 1 - exp(-damping * progress) * (cos(frequency * progress) + damping / frequency * sin(frequency * progress))
    }
}

public struct PointerIntent {
    public private(set) var hasDragged = false
    public private(set) var origin: CGPoint?
    public var threshold: CGFloat
    public init(threshold: CGFloat = 5) { self.threshold = threshold }
    public mutating func begin(at point: CGPoint) { origin = point; hasDragged = false }
    @discardableResult public mutating func move(to point: CGPoint) -> Bool {
        guard let origin else { return false }
        let wasDragging = hasDragged
        if hypot(point.x - origin.x, point.y - origin.y) >= threshold { hasDragged = true }
        return hasDragged && !wasDragging
    }
    public mutating func end(at point: CGPoint) -> Bool {
        guard origin != nil else { return false }
        move(to: point)
        let isClick = !hasDragged
        origin = nil
        return isClick
    }
}
