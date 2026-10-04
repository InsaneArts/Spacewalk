import Foundation

/// Which way the content travels. `forward` means the new workspace enters from the trailing edge
/// (from the right, or from below when vertical).
public enum Direction: Sendable {
    case forward, backward

    public var sign: CGFloat { self == .forward ? 1 : -1 }
    public var flipped: Direction { self == .forward ? .backward : .forward }

    /// Resolve from the ordered workspace list, e.g. ["1", "2", ..., "8"].
    public static func resolve(from current: String?, to target: String?, order: [String], mode: DirectionMode, inverted: Bool) -> Direction {
        var direction: Direction
        switch mode {
        case .alwaysForward: direction = .forward
        case .alwaysBackward: direction = .backward
        case .byOrder:
            guard let current, let target,
                  let a = order.firstIndex(of: current), let b = order.firstIndex(of: target) else {
                direction = .forward
                break
            }
            direction = b >= a ? .forward : .backward
        }
        return inverted ? direction.flipped : direction
    }
}
