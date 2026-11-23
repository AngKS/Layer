import Foundation
import os

#if DEBUG
/// How much work generated screens make: their commits, and their layouts ahead of a commit and where those ran.
/// For the tests that hold each update to one commit, laid out off the main actor (plan 3, Task 1). Counted under a
/// lock, since layouts ahead run on any thread, and per screen and per root, since suites that run alongside make
/// screens of their own.
enum GenerationWork {
    /// Roots committed on this screen by `commitGenerated` or `addLaidOutScreens`.
    static func commits(on screen: TreeScreen.ID) -> Int { work.withLock { $0.commits[screen] ?? 0 } }

    /// Roots of this id laid out by `TreeRules.laidOut`, and how many of those ran on the main thread.
    static func layoutsAhead(of rootID: UUID) -> (total: Int, onMainThread: Int) {
        work.withLock { $0.ahead[rootID] ?? (0, 0) }
    }

    static func committed(on screen: TreeScreen.ID) {
        work.withLock { $0.commits[screen, default: 0] += 1 }
    }

    static func laidOutAhead(_ rootID: UUID, onMainThread: Bool) {
        work.withLock { work in
            var counts = work.ahead[rootID] ?? (0, 0)
            counts.total += 1
            if onMainThread { counts.onMainThread += 1 }
            work.ahead[rootID] = counts
        }
    }

    private struct Work: Sendable {
        var commits: [TreeScreen.ID: Int] = [:]
        var ahead: [UUID: (total: Int, onMainThread: Int)] = [:]
    }

    private static let work = OSAllocatedUnfairLock(initialState: Work())
}
#endif
