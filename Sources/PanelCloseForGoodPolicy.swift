/// The only close predicate used by panel, workspace, and window retirement.
enum PanelCloseForGoodPolicy {
    static func shouldFire(isDetaching: Bool, isTerminatingApp: Bool) -> Bool {
        !isDetaching && !isTerminatingApp
    }
}
