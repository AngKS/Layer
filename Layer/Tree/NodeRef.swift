import Foundation

/// Points at one node on a screen or the open canvas: where it lives, and which one it is there (plan 6, call 12). The
/// selection, Siri's entities and the canvas's gestures hold one. Its host is the index's (`TreeIndex.Host`).
struct NodeRef: Hashable, Sendable {
    typealias Host = TreeIndex.Host
    var host: Host
    var node: UUID
}
