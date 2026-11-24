import Foundation
@testable import Layer

/// The tree's targets with their hosts keyed as the selection keys them: for the tests written for the list's target
/// functions, which `treeTargets(entered:)` replaced (plan 4, Task 3, clause (i)). Only the host's key is mapped; the targets are as `TreeTargets` has them, back to front.
extension TreeTargets {
    /// Each host's targets, by the selection's host: as the list's target functions gave them.
    var byHost: [DesignStore.ElementRef.Host: [Target]] {
        Dictionary(uniqueKeysWithValues: hosts.map { (DesignStore.ElementRef.Host($0.key), $0.value) })
    }

    /// One host's targets as the selection points at them: as `targets(on:entered:)` gave them.
    func refs(on host: DesignStore.ElementRef.Host) -> [DesignStore.ElementRef] {
        (byHost[host] ?? []).map { DesignStore.ElementRef(host: host, element: $0.id) }
    }
}
