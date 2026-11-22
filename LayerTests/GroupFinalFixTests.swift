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
        let before = board.store.content.elements.count
        let selection = try #require(CanvasSelection([.element(g), .element(board.b)]))

        let copies = board.store.duplicate(selection)

        // One group, with its two members: three new elements, the original group unchanged.
        #expect(board.store.content.elements.count == before + 3)
        #expect(board.store.content.members(of: g.element).count == 2)
        #expect(copies?.things.count == 1)
        board.undo.undo()
        #expect(board.store.content.elements.count == before)
    }

    @Test func rehostingAGroupAndOneOfItsMembersLeavesTheMemberInItsGroup() throws {
        let board = OrderBoard()
        let g = board.group(board.b, board.c)
        let selection = try #require(CanvasSelection([.element(g), .element(board.b)]))

        _ = board.store.rehost(selection)

        #expect(board.store.element(board.b.element)?.group == g.element)
        #expect(board.store.content.members(of: g.element).count == 2)
    }

    @Test func aGroupResizedToANonFiniteFrameStaysFinite() throws {
        let board = OrderBoard()
        let g = board.group(board.b, board.c)
        let box = try #require(board.store.element(g.element)?.frame)

        board.store.resizeGroup(g, to: CGRect(x: box.minX, y: box.minY, width: .infinity, height: box.height))
        board.store.resizeGroup(g, to: CGRect(x: box.minX, y: box.minY, width: box.width, height: 1e300))
        board.store.resizeGroup(g, to: CGRect(x: box.minX, y: box.minY, width: 1e300, height: 1e300))

        for id in [board.b, board.c] {
            let frame = try #require(board.store.element(id.element)?.frame)
            #expect(frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite)
        }
        #expect(throws: Never.self) { try JSONEncoder().encode(board.store.content) }
    }

    @Test func aGroupWithEveryMemberHiddenIsNoTarget() {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        #expect(board.store.targets(on: .screen(board.screen), entered: []).contains(g))

        board.store.update([board.b, board.d]) { $0.isHidden = true }

        #expect(board.store.element(g.element)?.isHidden == false)
        #expect(!board.store.targets(on: .screen(board.screen), entered: []).contains(g))
        #expect(!board.store.targetElements(entered: [])[.screen(board.screen), default: []].contains { $0.id == g.element })
    }

    @Test func siriShowingAMemberHiddenByItsGroupShowsTheGroupToo() throws {
        let board = OrderBoard()
        let i = board.group(board.c, board.e, named: "I") { $0.isHidden = true }
        let g = board.group(board.a, i, named: "G") { $0.isHidden = true }
        #expect(board.store.content.isHiddenWithItsGroups(board.c.element))
        let hidden = board.store.content

        try SetElementHiddenIntent.setHidden(false, board.c, in: board.model, undoManager: nil)

        #expect(!board.store.content.isHiddenWithItsGroups(board.c.element))
        #expect(board.store.element(g.element)?.isHidden == false)
        board.undo.undo()
        #expect(board.store.content == hidden, "one step")
    }
}
