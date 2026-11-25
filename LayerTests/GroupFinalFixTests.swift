import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// The final review's model fixes: a selection holding a group and one of its members, a
/// group resized to a non-finite frame, a group with nothing showing, Siri's Show.
@Suite("Groups, final fixes")
@MainActor
struct GroupFinalFixTests {
    @Test func duplicatingAGroupAndOneOfItsMembersCopiesTheMemberOnce() throws {
        let board = OrderBoard()
        let g = board.group(board.b, board.c)
        let before = board.store.tree.listedEverywhere.count
        let selection = try #require(CanvasSelection([.element(g), .element(board.b)]))

        let copies = board.store.duplicate(selection)

        // One group, with its two members: three new elements, the original group unchanged.
        #expect(board.store.tree.listedEverywhere.count == before + 3)
        #expect(board.store.members(of: g.node).count == 2)
        #expect(copies?.things.count == 1)
        board.undo.undo()
        #expect(board.store.tree.listedEverywhere.count == before)
    }

    @Test func rehostingAGroupAndOneOfItsMembersLeavesTheMemberInItsGroup() throws {
        let board = OrderBoard()
        let g = board.group(board.b, board.c)
        let selection = try #require(CanvasSelection([.element(g), .element(board.b)]))

        _ = board.store.rehost(selection)

        #expect(board.store.container(of: board.b.node) == g.node)
        #expect(board.store.members(of: g.node).count == 2)
    }

    @Test func aGroupResizedToANonFiniteFrameStaysFinite() throws {
        let board = OrderBoard()
        let g = board.group(board.b, board.c)
        let box = try #require(board.store.ownFrame(g.node))

        board.store.resizeGroup(g, to: CGRect(x: box.minX, y: box.minY, width: .infinity, height: box.height))
        board.store.resizeGroup(g, to: CGRect(x: box.minX, y: box.minY, width: box.width, height: 1e300))
        board.store.resizeGroup(g, to: CGRect(x: box.minX, y: box.minY, width: 1e300, height: 1e300))

        for id in [board.b, board.c] {
            let frame = try #require(board.store.ownFrame(id.node))
            #expect(frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite)
        }
        #expect(throws: Never.self) { try JSONEncoder().encode(board.store.tree) }
    }

    @Test func aGroupWithEveryMemberHiddenIsNoTarget() {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        #expect(board.store.treeTargets(entered: []).refs(on: .screen(board.screen)).contains(g))

        board.store.asOneStep {
            for member in [board.b, board.d] { board.store.update(member.node) { $0.isHidden = true } }
        }

        #expect(board.store.node(g.node)?.isHidden == false)
        #expect(!board.store.treeTargets(entered: []).refs(on: .screen(board.screen)).contains(g))
        #expect(!board.store.treeTargets(entered: []).byHost[.screen(board.screen), default: []].contains { $0.id == g.node })
    }

    @Test func siriShowingAMemberHiddenByItsGroupShowsTheGroupToo() throws {
        let board = OrderBoard()
        let i = board.group(board.c, board.e, named: "I") { $0.isHidden = true }
        let g = board.group(board.a, i, named: "G") { $0.isHidden = true }
        #expect(board.store.isHiddenWithItsContainers(board.c.node))
        let hidden = board.store.tree

        try SetElementHiddenIntent.setHidden(false, board.c, in: board.model, undoManager: nil)

        #expect(!board.store.isHiddenWithItsContainers(board.c.node))
        #expect(board.store.node(g.node)?.isHidden == false)
        board.undo.undo()
        #expect(board.store.tree == hidden, "one step")
    }

    /// The Format panel is for the selection: with nothing selected it closes.
    @Test func deselectingClosesTheFormatPanel() {
        let board = OrderBoard()
        board.model.selection = .element(board.b)
        board.model.isInspectorOpen = true

        board.model.selection = nil

        #expect(!board.model.isInspectorOpen)
    }

    // MARK: The Layers panel

    /// A drop at the end of a run that an open group's members come after lands before the next
    /// run's first row, just under the group, and not at the back of the whole list.
    @Test func aDropAtTheEndOfARunBeforeAnOpenGroupsRowsLandsBeforeTheNextRun() {
        let board = OrderBoard()
        let next = board.c.node
        let middle = LayerDropList(list: .host(.screen(board.screen)), endsBefore: next)
        #expect(middle.landing(before: nil) == next)
        #expect(middle.landing(before: board.b.node) == board.b.node, "dropped before a row, it lands before that row")
        let last = LayerDropList(list: .host(.screen(board.screen)), endsBefore: nil)
        #expect(last.landing(before: nil) == nil, "the last run's end is the back of the list")
    }

    @Test func aRowSaysWhatItIsAndWhatHidesOrLocksIt() {
        #expect(rowValue(isGroup: true, isHidden: false, isDimmed: false, isLocked: false, isLockedByGroup: false) == "Group")
        #expect(rowValue(isGroup: false, isHidden: false, isDimmed: true, isLocked: false, isLockedByGroup: true) == "Hidden by its group, Locked by its group")
        #expect(rowValue(isGroup: false, isHidden: true, isDimmed: true, isLocked: true, isLockedByGroup: true) == "Hidden, Locked")
        #expect(rowValue(isGroup: false, isHidden: false, isDimmed: false, isLocked: false, isLockedByGroup: false) == "")
    }

    // MARK: Hover

    /// After a double-tap goes into a group the outline of the outer group, which the pointer
    /// last hovered, is stale: it is let go, and found again as the pointer moves.
    @Test func aChangeOfSelectionLetsGoOfTheCanvasHover() {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        board.model.hovered = .element(g)
        board.model.selection = .element(g)
        #expect(board.model.hovered == nil)

        board.model.hovered = .element(g)
        board.model.selection = .element(board.b)
        #expect(board.model.hovered == nil)
    }

    /// A hover that comes from a row of the Layers list is the list's: the row says when it ends.
    @Test func aChangeOfSelectionLeavesTheListsHoverAlone() {
        let board = OrderBoard()
        board.model.isHoveringList = true
        board.model.hovered = .element(board.b)

        board.model.selection = .element(board.c)

        #expect(board.model.hovered == .element(board.b))
    }
}
