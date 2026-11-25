import Foundation

/// Writes each update of a generated screen into the store: merged by the screen's reconciler over the screen as it
/// is, laid out off the main actor, and committed as one change (plan 3, call 1). One writer per generation, so that
/// a key keeps its id across every update, and what the person changes meanwhile stays theirs.
///
/// The merge and the layout run on a copy: the screen's root, its device and the design's settings as they were when
/// the update came. The commit takes that layout as it is only while all three are still so. A change the person made
/// meanwhile (a drag, a retyped word, another device or other tokens) is merged over again on the main actor, and the
/// rules lay out what that changed, so no edit landing during the layout is overwritten by a stale merge.
@MainActor
final class GenerationWriter {
    /// An update merged and laid out ahead of its commit.
    struct Prepared: Sendable {
        /// The update as the generator wrote it.
        let generated: LayerNode
        /// The screen's root it was merged over and laid out from.
        let base: LayerNode
        let merge: TreeReconciler.Merge
        /// `merge.root` laid out as the rules would lay it out on the screen.
        let laidOut: LayerNode
        /// What is still wrong with what the generator wrote, as laid out: not what the person made on the screen.
        let unfixed: [UnfixedIssue: [UUID]]
        /// The screen's device and the design's settings it was laid out for.
        fileprivate let deviceID: String?
        fileprivate let settings: CanvasSettings
    }

    let screenID: TreeScreen.ID
    private(set) var reconciler: TreeReconciler

    #if DEBUG
    /// Runs between the layout and the commit: a test edits the screen here, as the person might while the update
    /// is laid out.
    var beforeCommit: (@MainActor () -> Void)?
    #endif

    init(screenID: TreeScreen.ID, reconciler: TreeReconciler = TreeReconciler()) {
        self.screenID = screenID
        self.reconciler = reconciler
    }

    /// Merged over the screen as it is now and laid out, off the main actor. Nil when the screen is gone.
    func prepare(_ generated: LayerNode, from store: DesignStore) async -> Prepared? {
        guard let screen = store.tree.screens.first(where: { $0.id == screenID }) else { return nil }
        let base = screen.root, deviceID = screen.deviceID, settings = store.tree.settings
        let reconciler = reconciler
        let prepared = await Task.detached(priority: .userInitiated) {
            let merge = reconciler.merged(generated, over: base)
            let made = TreeRules.laidOutReporting(merge.root, deviceID: deviceID, settings: settings, previous: base)
            let unfixed = UnfixedIssue.found(in: made.root, on: settings.device(named: deviceID),
                                             diagnostics: made.diagnostics, among: merge.generatedIDs)
            return Prepared(generated: generated, base: base, merge: merge, laidOut: made.root, unfixed: unfixed,
                            deviceID: deviceID, settings: settings)
        }.value
        #if DEBUG
        beforeCommit?()
        #endif
        return prepared
    }

    /// One change. Over `base`, with the hint. Over a screen changed since, merged again here, and the rules lay out
    /// what that changed. Records what was written. False when the screen is gone.
    ///
    /// Also false, with nothing written or recorded, when the store refuses the root (`commitGenerated`): a node
    /// deeper than 32, or a design of more than 5,000 nodes.
    @discardableResult
    func commit(_ prepared: Prepared, to store: DesignStore) -> Bool {
        guard let screen = store.tree.screens.first(where: { $0.id == screenID }) else { return false }
        let isAsLaidOut = screen.root == prepared.base && screen.deviceID == prepared.deviceID
            && store.tree.settings == prepared.settings
        let merge = isAsLaidOut ? prepared.merge : reconciler.merged(prepared.generated, over: screen.root)
        guard store.commitGenerated(isAsLaidOut ? prepared.laidOut : merge.root, on: screenID,
                                    laidOutOver: isAsLaidOut ? prepared.base : nil),
              let committed = store.root(of: screenID) else { return false }
        reconciler.record(merge, committed: committed)
        return true
    }

    /// prepare, then commit inside `edit` (or as a change of its own when nil).
    func write(_ generated: LayerNode, to store: DesignStore, in edit: DesignStore.Edit?) async -> Bool {
        guard let prepared = await prepare(generated, from: store) else { return false }
        return store.act(for: edit) { commit(prepared, to: store) }
    }
}
