import Foundation

/// User intent is separate from geometry changes caused by a growing response.
struct ChatScrollState: Equatable {
    private(set) var followsLatest = true
    private(set) var hasUnseenContent = false
    private(set) var isUserScrolling = false
    private var nearBottom = true

    mutating func userScrolling(_ value: Bool) {
        isUserScrolling = value
        if !value { applyUserPosition() }
    }
    mutating func positionChanged(nearBottom: Bool, userInitiated: Bool = false) {
        self.nearBottom = nearBottom
        if isUserScrolling || userInitiated { applyUserPosition() }
    }
    private mutating func applyUserPosition() {
        followsLatest = nearBottom
        if nearBottom { hasUnseenContent = false }
    }
    @discardableResult mutating func contentArrived() -> Bool {
        if !followsLatest { hasUnseenContent = true }
        return followsLatest && !isUserScrolling
    }
    mutating func jumpToLatest() {
        followsLatest = true
        hasUnseenContent = false
    }
}

/// Distinguish a mouse-wheel/keyboard move from response growth and window resizing.
struct ChatScrollGeometry: Equatable {
    let offset: CGFloat
    let contentHeight: CGFloat
    let viewportHeight: CGFloat
    var nearBottom: Bool { contentHeight - (offset + viewportHeight) <= 64 }
    func movedByUser(from old: Self, isPositionedByUser: Bool) -> Bool {
        guard isPositionedByUser, viewportHeight == old.viewportHeight else { return false }
        // Upward motion always expresses intent; downward motion must not be a
        // layout adjustment caused by a taller response.
        return offset < old.offset - 1 || (contentHeight == old.contentHeight && offset > old.offset + 1)
    }
}
