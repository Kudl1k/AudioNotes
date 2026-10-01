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
    mutating func positionChanged(nearBottom: Bool) {
        self.nearBottom = nearBottom
        if isUserScrolling { applyUserPosition() }
    }
    private mutating func applyUserPosition() {
        followsLatest = nearBottom
        if nearBottom { hasUnseenContent = false }
    }
    @discardableResult mutating func contentArrived() -> Bool {
        if !followsLatest { hasUnseenContent = true }
        return followsLatest
    }
    mutating func jumpToLatest() {
        followsLatest = true
        hasUnseenContent = false
    }
}
