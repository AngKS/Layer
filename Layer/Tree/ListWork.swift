import Foundation

#if DEBUG
/// How much of the design its changes write: for the tests that hold a change to writing only
/// what it changes (audit C6, M6). Each element of the flat list written counts, and so does each
/// node written by a store verb or by a write through the projection: one for a field or geometry
/// update, one for each add or move, the number removed, and the slots a reorder changes. A whole
/// host set in one go isn't counted, and neither are the frames the layout engine writes, which
/// its own counters count.
///
/// Counted on the main thread alone, where the store makes its changes, so that a design changed
/// elsewhere meanwhile doesn't add to a test's count. The count only grows: a test measures the
/// difference it makes.
enum ListWork {
    nonisolated(unsafe) private(set) static var elementsWritten = 0

    static func wrote(_ count: Int = 1) {
        guard count > 0, Thread.isMainThread else { return }
        elementsWritten += count
    }
}
#endif
