import CoreGraphics
import Foundation
import Testing
@testable import Layer

extension OrderBoard {
    /// Groups things that share a host under a new group item, built whole in one change,
    /// as Group does: an item added alone, or its members pointed at it in a change of their
    /// own, would be put right at the end of that change. `adjust` sets the item up before it
    /// is added: its angle, lock or hide. On the open canvas the item is drawn `scale` canvas
    /// points to each of its own.
    @discardableResult
    func group(
        _ refs: DesignStore.ElementRef..., named name: String = "G", scale: CGFloat? = nil,
        adjust: (inout DesignElement) -> Void = { _ in }
    ) -> DesignStore.ElementRef {
        let host = refs[0].host
        let parent: DesignScreen.ID? = if case .screen(let id) = host { id } else { nil }
        var item = DesignStore.newElement(.group)
        item.name = name
        adjust(&item)
        let made = item
        store.apply { content in
            content.add(made, to: parent, scale: scale)
            for ref in refs { content.update(ref.element) { $0.group = made.id } }
        }
        return DesignStore.ElementRef(host: host, element: made.id)
    }

    /// A group item on the board's screen, in `content` alone: what `keepGroupsSound()` is
    /// then asked to put right.
    static func addGroup(named name: String, holding members: [DesignElement.ID], to parent: DesignScreen.ID?, in content: inout DesignContent, adjust: (inout DesignElement) -> Void = { _ in }) -> DesignElement.ID {
        var item = DesignStore.newElement(.group)
        item.name = name
        adjust(&item)
        content.add(item, to: parent)
        for member in members { content.update(member) { $0.group = item.id } }
        return item.id
    }
}

/// Names of what is on a host in a design's own list, back to front.
private func names(_ content: DesignContent, on parent: DesignScreen.ID?) -> [String] {
    content.children(of: parent).map { $0.name ?? "" }
}

/// Whether two designs hold the same things, each host's in the same order. The order of
/// things on different hosts means nothing, and writing a view back can change it.
private func holdTheSame(_ a: DesignContent, _ b: DesignContent) -> Bool {
    let hosts: [DesignScreen.ID?] = a.screenFrames.map(\.id) + [nil]
    return a.screenFrames == b.screenFrames && a.elements.count == b.elements.count && hosts.allSatisfy { a.children(of: $0) == b.children(of: $0) }
}

private func close(_ a: CGRect, _ b: CGRect, within tolerance: CGFloat = 0.000_001) -> Bool {
    abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
}

/// The box a free container that fits what it holds takes round `corners`, the corners of what it holds turned as they
/// are, in its parent's points: turned to `degrees`, its own points starting at `origin`. The engine's rule
/// (`LayoutEngine.shapesBox`, with its `roundingError`): the box round what it holds is taken out to whole points of its
/// own, each side to the next whole point along its own axes, a thousandth of a point being a turn's rounding and no
/// reason to take a whole point more. An upright frame in the parent's points, centred on the box's turned centre, as a
/// turned element's frame is kept.
private func wholePointBox(round corners: [CGPoint], at degrees: Double, ownPointsFrom origin: CGPoint) -> CGRect {
    let turn = degrees * .pi / 180
    let across = CGVector(dx: cos(turn), dy: sin(turn)), down = CGVector(dx: -sin(turn), dy: cos(turn))
    let own = corners.map { point in
        let (x, y) = (point.x - origin.x, point.y - origin.y)
        return CGPoint(x: x * across.dx + y * across.dy, y: x * down.dx + y * down.dy)
    }
    let rounding: CGFloat = 0.001
    let left = (own.map(\.x).min()! + rounding).rounded(.down), top = (own.map(\.y).min()! + rounding).rounded(.down)
    let right = max(left, (own.map(\.x).max()! - rounding).rounded(.up)), bottom = max(top, (own.map(\.y).max()! - rounding).rounded(.up))
    let middle = CGPoint(x: (left + right) / 2, y: (top + bottom) / 2)
    let centre = CGPoint(x: origin.x + across.dx * middle.x + down.dx * middle.y, y: origin.y + across.dy * middle.x + down.dy * middle.y)
    let size = CGSize(width: right - left, height: bottom - top)
    return CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height)
}

/// The group item itself: an element of the kind `.group` in the one list, its members
/// pointing at it, kept sound after every change, left out of what draws, exports and
/// describes the design, and saved with it.
@MainActor
@Suite("Group model")
struct GroupModelTests {
    // MARK: Boxes

    @Test func aGroupsBoxHoldsItsMembers() throws {
        let board = OrderBoard()
        // D narrower and further in than B, so that the box is neither member's frame.
        board.store.update(board.d) { $0.frame = CGRect(x: 90, y: 490, width: 150, height: 60) }
        var content = board.store.content
        let g = OrderBoard.addGroup(named: "G", holding: [board.b.element, board.d.element], to: board.screen, in: &content)
        #expect(content.element(g)?.frame == .zero)

        content.keepGroupsSound()

        #expect(content.element(g)?.frame == CGRect(x: 40, y: 190, width: 300, height: 360))
        #expect(content.element(g)?.rotation == nil)
    }

    @Test func aTurnedGroupsBoxIsAtItsAngle() throws {
        let board = OrderBoard()
        board.store.update(board.d) { $0.setRotation(15) }
        var content = board.store.content
        let g = OrderBoard.addGroup(named: "G", holding: [board.b.element, board.d.element], to: board.screen, in: &content) { $0.setRotation(30) }

        content.keepGroupsSound()

        // Worked out in canvas points, from the members' turned shapes, and kept in the
        // screen's points.
        let screen = try #require(board.store.screen(board.screen))
        let shapes = [board.b, board.d].map { ref in
            let element = board.store.element(ref.element)!
            return TurnedRect(rect: screen.placement.canvasRect(for: element.frame), degrees: element.resolvedRotation)
        }
        let box = try #require(TurnedRect.enclosing(shapes, at: 30))
        let item = try #require(content.element(g))
        // That box, taken out to whole points of the group's own, by the engine's rule (`LayoutEngine.shapesBox`). Its own
        // points start where its item was put: at the screen's origin, the frame of a new item being zero.
        let corners = box.corners.map(screen.placement.localPoint(for:))
        #expect(close(item.frame, wholePointBox(round: corners, at: 30, ownPointsFrom: .zero)))
        #expect(item.rotation == 30)
        // Not the upright box round them.
        let upright = try #require(TurnedRect.enclosing(shapes, at: 0))
        #expect(!close(item.frame, screen.placement.localRect(for: upright.rect), within: 1))
    }

    /// Members sharing the item's points are enclosed in them as they are: carried through
    /// canvas points and back, the box picked up rounding that changed as the screen moved,
    /// and moving a screen rewrote its groups.
    @Test func movingAScreenLeavesItsGroupsBoxesAlone() {
        let board = OrderBoard()
        board.store.updateScreen(board.screen) { $0.scale = 0.66 }
        let g = board.group(board.b, board.d)
        #expect(board.store.element(g.element)?.frame == CGRect(x: 40, y: 190, width: 300, height: 400))

        for origin in [CGPoint(x: 100.3, y: 51.7), CGPoint(x: -12.9, y: 333.1), CGPoint(x: 7.77, y: 0.1)] {
            board.store.updateScreen(board.screen) { $0.origin = origin }
            #expect(board.store.element(g.element)?.frame == CGRect(x: 40, y: 190, width: 300, height: 400))
        }
    }

    /// L5: floating members each have a scale of their own, so the box is enclosed in canvas
    /// points and kept in the item's.
    @Test func aFloatingGroupsBoxHoldsMembersOfMixedScales() throws {
        let board = OrderBoard()
        let big = board.store.addFloating(OrderBoard.element(.stickyNote, named: "big note", CGRect(x: 400, y: 300, width: 140, height: 130)), scale: 2)
        let g = board.group(board.note1, big, scale: 1)

        let small = try #require(board.store.canvasFrame(of: .element(board.note1)))
        let large = try #require(board.store.canvasFrame(of: .element(big)))
        #expect(large == CGRect(x: 800, y: 600, width: 280, height: 260))
        let box = try #require(board.store.canvasFrame(of: .element(g)))
        #expect(box == small.union(large))
        // Their own frames enclosed as if they shared one scale give another box.
        let naive = CGRect(x: 500, y: 100, width: 140, height: 130).union(CGRect(x: 400, y: 300, width: 140, height: 130))
        #expect(box != naive)
    }

    @Test func aGroupItemResolves() throws {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)

        let (item, placement) = try #require(board.store.resolve(g))
        #expect(item.kind == .group)
        #expect(placement == board.store.screen(board.screen)?.placement)
        let shape = try #require(board.store.canvasShape(of: .element(g)))
        #expect(shape == TurnedRect(rect: placement.canvasRect(for: item.frame), degrees: 0))
        let b = try #require(board.store.canvasFrame(of: .element(board.b)))
        let d = try #require(board.store.canvasFrame(of: .element(board.d)))
        #expect(shape.rect == b.union(d))
        #expect(board.store.canvasFrame(of: .element(g)) == shape.bounds)
        #expect(board.store.groupItem(g.element)?.id == g.element)
        #expect(board.store.groupItem(board.b.element) == nil)
        #expect(board.store.groupItems(on: .screen(board.screen)).map(\.id) == [g.element])
        #expect(board.store.children(on: .screen(board.screen)).map { $0.name ?? "" } == ["A", "C", "B", "D", "G", "E"])

        // Selected, it is the one element selected, locked by its own flag, and let go of
        // once it has gone.
        board.model.selection = .element(g)
        #expect(board.model.selectedElement?.element.id == g.element)
        #expect(board.model.selectedElement?.placement == placement)
        #expect(!board.store.isLocked(.element(g)))
        board.store.update(g) { $0.isLocked = true }
        #expect(board.store.isLocked(.element(g)))
        #expect(board.model.isSelectionLocked)
        board.store.delete(board.d)
        #expect(board.store.resolve(g) == nil)
        #expect(board.model.selection == nil)
    }

    // MARK: Order

    /// D2: the item starts in front of E, so it has to move back to between D and E. The tree
    /// can't hold a group away from its members, so it is gathered as they are pointed at it.
    @Test func membersAreGatheredWithTheGroupInFrontOfThem() {
        let board = OrderBoard()
        var content = board.store.content
        _ = OrderBoard.addGroup(named: "G", holding: [board.b.element, board.d.element], to: board.screen, in: &content)
        #expect(names(content, on: board.screen) == ["A", "C", "B", "D", "G", "E"])

        content.keepGroupsSound()

        #expect(names(content, on: board.screen) == ["A", "C", "B", "D", "G", "E"])
        // What is on the open canvas doesn't move.
        #expect(names(content, on: nil) == ["note 1", "note 2", "drawing"])
    }

    /// Drawings are in no layer order, so gathering leaves each where it is among the canvas's
    /// own nodes, as arranging does (F7, F10): only the things around it move. A drawing can't be
    /// among a group's members in the tree, so the group is beside it.
    @Test func aDrawingBesideACanvasGroupKeepsItsIndexAmongTheCanvasNodes() {
        let board = OrderBoard()
        let note3 = board.addNote(named: "note 3", at: CGPoint(x: 900, y: 100))
        let note4 = board.addNote(named: "note 4", at: CGPoint(x: 1100, y: 100))
        var content = board.store.content
        #expect(content.tree.canvas.map(\.kind) == [.stickyNote, .stickyNote, .drawing, .stickyNote, .stickyNote])
        _ = OrderBoard.addGroup(named: "G", holding: [note3.element, note4.element], to: nil, in: &content)

        content.keepGroupsSound()

        #expect(content.tree.canvas.map(\.kind) == [.stickyNote, .stickyNote, .drawing, .group])
        #expect(names(content, on: nil) == ["note 1", "note 2", "drawing", "note 3", "note 4", "G"])
    }

    @Test func aGroupInsideAGroupIsGatheredAndBoxedInnermostFirst() throws {
        let board = OrderBoard()
        var content = board.store.content
        let inner = OrderBoard.addGroup(named: "I", holding: [board.c.element, board.e.element], to: board.screen, in: &content)
        let outer = OrderBoard.addGroup(named: "G", holding: [board.a.element, inner], to: board.screen, in: &content)

        content.keepGroupsSound()

        #expect(names(content, on: board.screen) == ["B", "D", "A", "C", "E", "I", "G"])
        #expect(content.ancestors(of: board.c.element) == [inner, outer])
        #expect(content.members(of: outer).map { $0.name ?? "" } == ["A", "I"])
        #expect(content.leaves(of: outer).map { $0.name ?? "" } == ["A", "C", "E"])
        #expect(content.element(inner)?.frame == CGRect(x: 40, y: 340, width: 300, height: 400))
        #expect(content.element(outer)?.frame == CGRect(x: 40, y: 40, width: 300, height: 700))
    }

    @Test func updatingAScreenKeepsEachGroupItemOnce() {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)

        board.store.updateScreen(board.screen) { screen in
            guard let index = screen.elements.firstIndex(where: { $0.id == board.a.element }) else { return }
            screen.elements[index].frame.origin.x += 10
        }

        #expect(board.store.content.elements.filter { $0.id == g.element }.count == 1)
        #expect(board.store.content.members(of: g.element).map { $0.name ?? "" } == ["B", "D"])
        #expect(board.screenOrder == ["A", "C", "B", "D", "G", "E"])
        #expect(board.store.element(board.a.element)?.frame.minX == 50)
    }

    // MARK: Groups of one, and none

    /// Review Focus 3.
    @Test func aGroupLeftWithOneMemberDissolvesAndUndoBringsItBack() {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        #expect(board.screenOrder == ["A", "C", "B", "D", "G", "E"])
        let grouped = board.store.content

        board.store.delete(board.d)

        #expect(board.store.element(g.element) == nil)
        #expect(board.store.element(board.b.element)?.group == nil)
        #expect(board.screenOrder == ["A", "C", "B", "E"])

        board.undo.undo()

        #expect(board.store.content == grouped)
        #expect(board.screenOrder == ["A", "C", "B", "D", "G", "E"])
        #expect(board.store.element(board.b.element)?.group == g.element)
        #expect(board.store.element(board.d.element)?.group == g.element)
    }

    @Test func aDissolvingHiddenGroupLeavesItsMemberHidden() {
        let board = OrderBoard()
        board.group(board.b, board.d) {
            $0.isHidden = true
            $0.isLocked = true
        }
        #expect(board.store.element(board.b.element)?.isHidden == false)

        board.store.delete(board.d)

        let b = board.store.element(board.b.element)
        #expect(b?.group == nil)
        #expect(b?.isHidden == true)
        #expect(b?.isLocked == true)
    }

    /// Rule 3 with nesting: the member of a group of one takes that group's place in the
    /// group above it, rather than leaving it.
    @Test func aGroupOfOneInsideAGroupHandsItsMemberUp() throws {
        let board = OrderBoard()
        let inner = board.group(board.c, board.e, named: "I")
        let outer = board.group(board.a, inner)
        #expect(board.store.content.ancestors(of: board.c.element) == [inner.element, outer.element])

        board.store.delete(board.e)

        #expect(board.store.element(inner.element) == nil)
        #expect(board.store.element(board.c.element)?.group == outer.element)
        #expect(board.store.content.members(of: outer.element).map { $0.name ?? "" } == ["A", "C"])
        let a = try #require(board.store.canvasFrame(of: .element(board.a)))
        let c = try #require(board.store.canvasFrame(of: .element(board.c)))
        #expect(board.store.canvasFrame(of: .element(outer)) == a.union(c))
    }

    /// An undo takes back its step's own changes and leaves those made since: taken back
    /// among them, a step can leave a group unsound, and is put right as it is undone.
    @Test func undoingAStepAmongOthersLeavesNoGroupOfOne() {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        // A drag begins, and moves A.
        let drag = board.store.beginEdit()
        board.store.act(for: drag) { board.store.update(board.a) { $0.frame.origin.x += 5 } }
        // Meanwhile D is deleted, as a step of its own, which dissolves G.
        board.store.asOwnStep { board.store.delete(board.d) }
        #expect(board.store.element(g.element) == nil)
        // The drag's edit goes on, and takes B away.
        board.store.act(for: drag) { board.store.delete(board.b) }
        board.store.endEdit(drag)

        // Undoing the deletion brings D and G back, but G's other member has gone since.
        board.undo.undo()

        #expect(board.store.element(board.d.element) != nil)
        #expect(board.store.element(board.d.element)?.group == nil)
        #expect(board.store.element(g.element) == nil)
        #expect(board.screenOrder == ["A", "C", "D", "E"])
    }

    @Test func oneScreenIsShownAsTheScreensAre() {
        let board = OrderBoard()
        board.group(board.b, board.d) { $0.isHidden = true }
        let content = board.store.content

        #expect(content.screen(board.screen) == content.screens.first)
        #expect(content.screen(board.screen)?.elements.contains { $0.kind == .group } == false)
    }

    // MARK: Files

    @Test func groupsSurviveTheFile() throws {
        let board = OrderBoard()
        let g = board.group(board.b, board.d) {
            $0.setRotation(30)
            $0.isHidden = true
        }
        let notes = board.group(board.note1, board.note2, named: "N")

        let reopened = try DesignFile(wrapper: DesignFile(content: board.store.content).wrapper()).content

        #expect(reopened == board.store.content)
        #expect(names(reopened, on: board.screen) == ["A", "C", "B", "D", "G", "E"])
        #expect(reopened.members(of: g.element).map { $0.name ?? "" } == ["B", "D"])
        #expect(reopened.members(of: notes.element).map { $0.name ?? "" } == ["note 1", "note 2"])
        #expect(reopened.element(g.element)?.rotation == 30)
        #expect(reopened.element(g.element)?.isHidden == true)
        #expect(reopened.elements.allSatisfy { $0.unknownKeys.values.isEmpty })

        // A member is written inside its group; nothing else says it is in one.
        let written = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(board.store.content)) as? [String: Any])
        func everyNode(_ nodes: [[String: Any]]) -> [[String: Any]] {
            nodes + nodes.flatMap { everyNode($0["children"] as? [[String: Any]] ?? []) }
        }
        let screens = try #require(written["screens"] as? [[String: Any]])
        let tops = screens.flatMap { ($0["root"] as? [String: Any])?["children"] as? [[String: Any]] ?? [] }
            + (written["canvas"] as? [[String: Any]] ?? [])
        let entries = everyNode(tops)
        let held = entries.filter { $0["kind"] as? String == "group" }
            .flatMap { ($0["children"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String } }
        #expect(Set(held) == ["B", "D", "note 1", "note 2"])
        #expect(entries.allSatisfy { $0["group"] == nil })
    }

    // MARK: What doesn't know about groups

    @Test func groupItemsAreLeftOutOfWhatIsDrawnExportedAndDescribed() throws {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        let notes = board.group(board.note1, board.note2, named: "N")
        let content = board.store.content

        #expect(content.screens[0].elements.map { $0.name ?? "" } == ["A", "C", "B", "D", "E"])
        // The drawing, which the list kept between the notes and their group item, can't be in
        // the group's block in the tree: it keeps its slot just behind the group.
        #expect(content.floating.map { $0.element.name ?? "" } == ["drawing", "note 1", "note 2"])
        #expect(!content.screens.flatMap(\.elements).contains { $0.kind == .group })
        #expect(!content.floating.contains { $0.element.kind == .group })

        // The code is that of the same design without the group items.
        var plain = content
        plain.remove([g.element, notes.element])
        for member in [board.b, board.d, board.note1, board.note2] { plain.update(member.element) { $0.group = nil } }
        #expect(plain.screens[0].elements.map(\.id) == content.screens[0].elements.map(\.id))
        #expect(SwiftUICodeGenerator.code(for: content.screens[0], typeName: nil, settings: CodeSettings())
            == SwiftUICodeGenerator.code(for: plain.screens[0], typeName: nil, settings: CodeSettings()))

        // How voice and Siri are told the same board went to their own lanes' files (plan 6, Task 1, F11):
        // `CanvasPictureTests.aGroupsMembersAreToldInItsPlace` and `EntityKeyTests.aGroupsMembersAreSirisElements`.
    }

    // MARK: Lock and hide

    @Test func aHiddenOrLockedGroupHidesOrLocksItsMembersWithoutChangingTheirOwnFlags() {
        let board = OrderBoard()
        board.group(board.b, board.d) { $0.isHidden = true }
        board.group(board.note1, board.note2, named: "N") { $0.isLocked = true }

        // As the views show them, the members are hidden or locked…
        #expect(board.store.screens[0].elements.filter(\.isHidden).map { $0.name ?? "" } == ["B", "D"])
        #expect(board.store.floating.filter(\.element.isLocked).map { $0.element.name ?? "" } == ["note 1", "note 2"])
        // …and their own flags are as they were.
        #expect(board.store.content.children(of: board.screen).filter(\.isHidden).map { $0.name ?? "" } == ["G"])
        #expect(board.store.content.children(of: nil).filter(\.isLocked).map { $0.name ?? "" } == ["N"])
        #expect(board.store.isLocked(.element(board.note1)))
        #expect(!board.store.isLocked(.element(board.b)))
        #expect(board.store.content.isHiddenWithItsGroups(board.b.element))
        #expect(board.store.content.isLockedWithItsGroups(board.note2.element))

        // Written back as they were shown, nothing changes: the group items stay, in front of
        // their members, and the members keep their own flags.
        let before = board.store.content
        board.store.apply { $0.screens = $0.screens }
        #expect(holdTheSame(board.store.content, before))
        board.store.apply { $0.floating = $0.floating }
        #expect(holdTheSame(board.store.content, before))

        // A flag written that differs from what was shown is the thing's own.
        board.store.apply { content in
            guard let index = content.screens[0].elements.firstIndex(where: { $0.id == board.b.element }) else { return }
            content.screens[0].elements[index].isLocked = true
        }
        #expect(board.store.element(board.b.element)?.isLocked == true)
        #expect(board.store.element(board.b.element)?.isHidden == false)
        #expect(board.store.element(board.d.element)?.isLocked == false)
    }

    /// Conflict D: Unlock on a member locked only by its group unlocks the group, in one step.
    @Test func unlockingAMemberLockedByItsGroupUnlocksTheGroup() {
        let board = OrderBoard()
        let g = board.group(board.b, board.d) { $0.isLocked = true }
        board.model.selection = .element(board.b)
        #expect(board.model.isSelectionLocked)
        let locked = board.store.content

        board.model.setSelectionLocked(false)

        #expect(board.store.element(g.element)?.isLocked == false)
        #expect(!board.model.isSelectionLocked)
        #expect(!board.store.isLocked(.element(board.d)))

        board.undo.undo()
        #expect(board.store.content == locked)
    }

    /// F4: a member of a locked group can be selected, by a double-tap or a Layers row, but
    /// isn't resized or turned on its own.
    @Test func aMemberOfALockedGroupIsntResizedOrTurnedOnItsOwn() throws {
        let board = OrderBoard()
        board.group(board.b, board.d) { $0.isLocked = true }
        #expect(board.store.element(board.b.element)?.isLocked == false)
        board.model.selection = .element(board.b)
        let (before, placement) = try #require(board.store.resolve(board.b))

        #expect(!board.model.canTurnSelection)
        board.model.rotateSelection(by: 30)
        #expect(board.store.element(board.b.element)?.rotation == before.rotation)

        // A corner handle dragged 40 points.
        let drags = CanvasDrags()
        let owner = CanvasDrags.Owner()
        drags.moveElement(board.b, from: before.frame, placement: placement, by: CGSize(width: 40, height: 40), startingAt: CGPoint(x: 1, y: 1), findsNewHome: false, owner: owner, model: board.model) {
            { origin, translation in
                (ElementLayout.resizedTurned(origin, degrees: before.resolvedRotation, from: .bottomRight, by: translation, kind: before.kind), [])
            }
        }
        drags.dropElement(board.b, findsNewHome: false, owner: owner, model: board.model)

        #expect(board.store.element(board.b.element)?.frame == before.frame)
        #expect(!drags.isDragging)
        #expect(!board.model.isAdjusting)
    }

    /// Several things turned together leave alone a member locked by its group.
    @Test func turningSeveralLeavesAMemberOfALockedGroupWhereItIs() throws {
        let board = OrderBoard()
        board.group(board.b, board.d) { $0.isLocked = true }
        board.model.selection = board.selection(board.a, board.b)
        let before = try #require(board.store.element(board.b.element))

        board.model.rotateSelection(by: 30)

        #expect(board.store.element(board.a.element)?.rotation == 30)
        #expect(board.store.element(board.b.element)?.frame == before.frame)
        #expect(board.store.element(board.b.element)?.rotation == before.rotation)
    }

    /// VoiceOver's Reset rotation on several things stands up only those that aren't locked.
    @Test func resettingSeveralLeavesAMemberOfALockedGroupTurned() {
        let board = OrderBoard()
        board.store.update(board.a) { $0.setRotation(20) }
        board.store.update(board.b) { $0.setRotation(20) }
        board.group(board.b, board.d) { $0.isLocked = true }
        board.model.selection = board.selection(board.a, board.b)

        board.model.resetSelectionRotation()

        #expect(board.store.element(board.a.element)?.rotation == nil)
        #expect(board.store.element(board.b.element)?.rotation == 20)
    }

    /// The Format panel's corners, opacity and angle for several things change only those that
    /// aren't locked, and show an unlocked one's value.
    @Test func theFormatPanelLeavesAMemberOfALockedGroupAlone() {
        let board = OrderBoard()
        board.group(board.b, board.d) { $0.isLocked = true }
        board.model.selection = board.selection(board.a, board.b)

        #expect(board.model.unlockedSelectedElements.map(\.element.id) == [board.a.element])
        board.model.changeElements([board.a, board.b], unlockedOnly: true, where: { _ in true }) { $0.opacity = 0.5 }

        #expect(board.store.element(board.a.element)?.opacity == 0.5)
        #expect(board.store.element(board.b.element)?.opacity == nil)
    }
}

extension OrderBoard {
    /// The names of what is on the board's screen, back to front, with group items called
    /// as given: Group leaves a new group unnamed, shown as its kind until it is renamed.
    fileprivate func screenOrder(calling groups: [DesignStore.ElementRef: String]) -> [String] {
        let called = Dictionary(groups.map { ($0.key.element, $0.value) }, uniquingKeysWith: { first, _ in first })
        return store.content.children(of: screen).map { called[$0.id] ?? $0.name ?? "" }
    }

    /// A group's members, by name, back to front.
    fileprivate func members(of group: DesignStore.ElementRef) -> [String] {
        store.content.members(of: group.element).map { $0.name ?? "" }
    }
}

/// Group and Ungroup: a group built whole, as one step, where its frontmost member was, from
/// the things that can join it; taken apart again with its members kept where they are; and
/// arranged as one block among its siblings, with what is inside it arranged inside it.
@MainActor
@Suite("Group commands")
struct GroupCommandTests {
    // MARK: Group

    @Test func groupingScatteredThingsGathersThemWhereTheFrontmostWas() throws {
        let board = OrderBoard()
        let b = try #require(board.store.canvasFrame(of: .element(board.b)))
        let d = try #require(board.store.canvasFrame(of: .element(board.d)))
        board.model.selection = board.selection(board.b, board.d)
        #expect(board.model.canGroupSelection)

        board.model.groupSelection()

        let g = try #require(board.model.selectedElement)
        #expect(board.model.selection == .element(g.ref))
        #expect(g.element.kind == .group)
        #expect(g.ref.host == .screen(board.screen))
        #expect(g.element.group == nil)
        // Named as its kind until it is renamed.
        #expect(g.element.name == nil)
        #expect(board.screenOrder(calling: [g.ref: "G"]) == ["A", "C", "B", "D", "G", "E"])
        #expect(board.members(of: g.ref) == ["B", "D"])
        #expect(board.store.canvasFrame(of: .element(g.ref)) == b.union(d))
        // The members stay where they are, and nothing else moves.
        #expect(board.store.canvasFrame(of: .element(board.b)) == b)
        #expect(board.store.canvasFrame(of: .element(board.d)) == d)
        #expect(board.canvasOrder == ["note 1", "note 2", "drawing"])
    }

    /// On the open canvas each thing has a scale of its own: the group takes its frontmost
    /// member's, and its box holds them all on the canvas (L5).
    @Test func aGroupOnTheOpenCanvasTakesItsFrontmostMembersScale() throws {
        let board = OrderBoard()
        let big = board.store.addFloating(OrderBoard.element(.stickyNote, named: "big note", CGRect(x: 400, y: 300, width: 140, height: 130)), scale: 2)
        let small = try #require(board.store.canvasFrame(of: .element(board.note1)))
        let large = try #require(board.store.canvasFrame(of: .element(big)))

        let g = try #require(board.store.group(board.selection(board.note1, big)))

        #expect(g.host == .canvas)
        #expect(board.store.element(g.element)?.scale == 2)
        #expect(board.store.canvasFrame(of: .element(g)) == small.union(large))
        #expect(board.store.content.members(of: g.element).map(\.id) == [board.note1.element, big.element])
    }

    @Test func lockedThingsAndDrawingsAreLeftOut() throws {
        let board = OrderBoard()
        board.store.setLocked(true, .element(board.b))

        let g = try #require(board.store.group(board.selection(board.b, board.c, board.d)))

        #expect(board.members(of: g) == ["C", "D"])
        #expect(board.store.element(board.b.element)?.group == nil)
        #expect(board.screenOrder(calling: [g: "G"]) == ["A", "B", "C", "D", "G", "E"])

        // With the locked one left out, one is left: Group is off and does nothing.
        let refused = OrderBoard()
        refused.store.setLocked(true, .element(refused.b))
        let before = refused.store.content
        refused.model.selection = refused.selection(refused.b, refused.c)
        #expect(!refused.store.canGroup(refused.selection(refused.b, refused.c)))
        #expect(!refused.model.canGroupSelection)
        #expect(refused.store.group(refused.selection(refused.b, refused.c)) == nil)
        refused.model.groupSelection()
        #expect(refused.store.content == before)
        #expect(refused.model.selection == refused.selection(refused.b, refused.c))

        // A drawing is left out likewise.
        let drawn = OrderBoard()
        let notes = try #require(drawn.store.group(drawn.selection(drawn.note1, drawn.note2, drawn.drawing)))
        #expect(drawn.store.content.members(of: notes.element).map(\.id) == [drawn.note1.element, drawn.note2.element])
        #expect(drawn.store.element(drawn.drawing.element)?.group == nil)
        #expect(!drawn.store.canGroup(drawn.selection(drawn.note2, drawn.drawing)))

        // So is what a locked group locks: entered, its members can't be grouped.
        let locked = OrderBoard()
        locked.group(locked.b, locked.c, locked.d) { $0.isLocked = true }
        #expect(!locked.store.canGroup(locked.selection(locked.b, locked.c)))
    }

    @Test func thingsOnTwoScreensOrAScreenCantBeGrouped() {
        let board = OrderBoard()
        #expect(board.store.canGroup(board.selection(board.a, board.b)))
        #expect(!board.store.canGroup(board.selection(board.a)))

        // A thing on the screen and a note on the open canvas.
        board.model.selection = board.selection(board.a, board.note1)
        #expect(!board.store.canGroup(board.selection(board.a, board.note1)))
        #expect(!board.model.canGroupSelection)
        #expect(board.model.groupSelectionSpansHosts)
        let before = board.store.content
        board.model.groupSelection()
        #expect(board.store.content == before)
        #expect(board.model.selection == board.selection(board.a, board.note1))

        // Things on two screens.
        let other = board.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 1000, y: 50), scale: 0.5))
        let f = board.store.setElements([OrderBoard.element(.button, named: "F", CGRect(x: 40, y: 40, width: 300, height: 100))], on: other.id)[0]
        board.model.selection = board.selection(board.a, f)
        #expect(!board.model.canGroupSelection)
        #expect(board.model.groupSelectionSpansHosts)

        // A screen, with something on it or with things on the open canvas.
        #expect(!board.store.canGroup(CanvasSelection([.screen(board.screen), .element(board.a)])!))
        #expect(!board.store.canGroup(CanvasSelection([.screen(board.screen), .element(board.note1), .element(board.note2)])!))

        // Things on one screen sharing no group.
        let grouped = OrderBoard()
        grouped.group(grouped.b, grouped.d)
        grouped.model.selection = grouped.selection(grouped.a, grouped.b)
        #expect(!grouped.model.canGroupSelection)
        #expect(!grouped.model.groupSelectionSpansHosts)
    }

    /// Every member of a group, grouped, would make the same group again under a new id: the
    /// old one, left with one member, would dissolve into it, and its name and angle with it.
    @Test func everyMemberOfAGroupIsNotGroupedAgain() throws {
        let board = OrderBoard()
        board.group(board.b, board.c, board.d) { $0.setRotation(20) }
        let before = board.store.content
        let all = board.selection(board.b, board.c, board.d)

        #expect(!board.store.canGroup(all))
        #expect(board.store.group(all) == nil)
        #expect(board.store.content == before)

        // A locked member is left out, so the rest are not the whole group: they make a group
        // inside it.
        let locked = OrderBoard()
        let g = locked.group(locked.b, locked.c, locked.d)
        locked.store.setLocked(true, .element(locked.c))
        let inner = try #require(locked.store.group(locked.selection(locked.b, locked.c, locked.d)))
        #expect(locked.store.element(inner.element)?.group == g.element)
        #expect(locked.members(of: inner) == ["B", "D"])
        #expect(locked.store.content.members(of: g.element).map(\.id) == [locked.c.element, inner.element])
    }

    /// Review Focus 1: the things grouped weren't next to each other.
    @Test func undoingAGroupPutsTheOrderBack() throws {
        let board = OrderBoard()
        let before = board.store.content
        #expect(!board.undo.canUndo)
        board.model.selection = board.selection(board.b, board.d)

        board.model.groupSelection()

        let g = try #require(board.model.selectedElement?.ref)
        #expect(board.screenOrder(calling: [g: "G"]) == ["A", "C", "B", "D", "G", "E"])
        #expect(board.undo.canUndo)
        // A one-off, as Delete is: plain Undo.
        #expect(board.undo.undoActionName == "")

        board.undo.undo()

        #expect(!board.undo.canUndo)
        #expect(board.store.content == before)
        #expect(board.screenOrder == ["A", "B", "C", "D", "E"])
        #expect(board.store.groupItems(on: .screen(board.screen)).isEmpty)
        #expect(board.store.element(board.b.element)?.group == nil)
        #expect(board.store.element(board.d.element)?.group == nil)

        board.undo.redo()
        #expect(board.screenOrder(calling: [g: "G"]) == ["A", "C", "B", "D", "G", "E"])
        #expect(board.members(of: g) == ["B", "D"])
    }

    // MARK: Ungroup

    @Test func ungroupingKeepsPlacesAndPassesLockAndHideDown() throws {
        let board = OrderBoard()
        let g = board.group(board.b, board.d) { $0.isHidden = true }
        let b = try #require(board.store.element(board.b.element))
        let d = try #require(board.store.element(board.d.element))
        #expect(!b.isHidden)
        board.model.selection = .element(g)
        #expect(board.model.canUngroupSelection)

        board.model.ungroupSelection()

        #expect(board.store.element(g.element) == nil)
        #expect(board.screenOrder == ["A", "C", "B", "D", "E"])
        #expect(board.model.selection == board.selection(board.b, board.d))
        for (ref, was) in [(board.b, b), (board.d, d)] {
            let now = try #require(board.store.element(ref.element))
            #expect(now.group == nil)
            #expect(now.isHidden)
            #expect(!now.isLocked)
            #expect(now.frame == was.frame)
        }
        #expect(board.store.element(board.a.element)?.isHidden == false)

        // Only a group is ungrouped.
        board.model.selection = .element(board.a)
        #expect(!board.model.canUngroupSelection)
        #expect(board.store.ungroup(board.a) == nil)

        // A locked group isn't taken apart from the selection's commands; Ungroup itself
        // passes its lock down.
        let locked = OrderBoard()
        let l = locked.group(locked.b, locked.d) { $0.isLocked = true }
        locked.model.selection = .element(l)
        #expect(!locked.model.canUngroupSelection)
        locked.model.ungroupSelection()
        #expect(locked.store.element(l.element) != nil)
        #expect(locked.store.ungroup(l) == locked.selection(locked.b, locked.d))
        #expect(locked.store.element(locked.b.element)?.isLocked == true)
        #expect(locked.store.element(locked.d.element)?.isLocked == true)
    }

    /// Review Focus 1: one undo brings the group back with its members, their own flags and
    /// the order as they were.
    @Test func undoingAnUngroupPutsTheGroupBack() throws {
        let board = OrderBoard()
        let start = board.store.content
        let g = board.group(board.b, board.d) { $0.isHidden = true }
        let grouped = board.store.content
        board.model.selection = .element(g)

        board.model.ungroupSelection()
        #expect(board.screenOrder == ["A", "C", "B", "D", "E"])
        #expect(board.undo.undoActionName == "")

        board.undo.undo()

        #expect(board.store.content == grouped)
        #expect(board.screenOrder == ["A", "C", "B", "D", "G", "E"])
        #expect(board.members(of: g) == ["B", "D"])
        #expect(board.store.element(board.b.element)?.isHidden == false)
        // The step before is the group's own making.
        board.undo.undo()
        #expect(board.store.content == start)
    }

    @Test func aGroupInsideAGroup() throws {
        let board = OrderBoard()
        let g1 = try #require(board.store.group(board.selection(board.b, board.c)))
        let g2 = try #require(board.store.group(board.selection(g1, board.d)))
        let called = [g1: "G1", g2: "G2"]

        #expect(board.store.content.ancestors(of: board.b.element) == [g1.element, g2.element])
        #expect(board.screenOrder(calling: called) == ["A", "B", "C", "G1", "D", "G2", "E"])

        #expect(board.store.ungroup(g2) == board.selection(g1, board.d))

        #expect(board.store.content.ancestors(of: board.b.element) == [g1.element])
        #expect(board.store.element(g1.element)?.group == nil)
        #expect(board.members(of: g1) == ["B", "C"])
        #expect(board.screenOrder(calling: called) == ["A", "B", "C", "G1", "D", "E"])

        // A group made of things in a group is made in that group, and ungrouped, its
        // members go back to it.
        let nested = OrderBoard()
        let outer = nested.group(nested.b, nested.c, nested.d)
        let inner = try #require(nested.store.group(nested.selection(nested.b, nested.c)))
        #expect(nested.store.element(inner.element)?.group == outer.element)
        #expect(nested.store.content.ancestors(of: nested.b.element) == [inner.element, outer.element])
        #expect(nested.screenOrder(calling: [inner: "I"]) == ["A", "B", "C", "I", "D", "G", "E"])
        nested.store.ungroup(inner)
        #expect(nested.store.content.ancestors(of: nested.b.element) == [outer.element])
        #expect(nested.members(of: outer) == ["B", "C", "D"])
    }

    // MARK: Arranging

    @Test func aGroupArrangesAsOneBlock() {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        // A member locked on its own goes with its group.
        board.store.setLocked(true, .element(board.b))

        board.store.arrange(.element(g), .back)
        #expect(board.screenOrder == ["B", "D", "G", "A", "C", "E"])

        board.store.arrange(.element(g), .forward)
        #expect(board.screenOrder == ["A", "B", "D", "G", "C", "E"])

        // From the selection's commands too.
        board.model.selection = .element(g)
        #expect(board.model.canArrangeSelection(.front))
        board.model.arrangeSelection(.front)
        #expect(board.screenOrder == ["A", "C", "E", "B", "D", "G"])
        #expect(!board.model.canArrangeSelection(.forward))

        // So does what a locked group inside it locks.
        let nested = OrderBoard()
        let inner = nested.group(nested.b, nested.c, named: "I") { $0.isLocked = true }
        let outer = nested.group(inner, nested.d)
        nested.store.arrange(.element(outer), .back)
        #expect(nested.screenOrder == ["B", "C", "I", "D", "G", "A", "E"])

        // On the open canvas a drawing can't be among a group's members: the group of the notes
        // either side of it sits beside it, in front, where its frontmost member was, and goes to
        // the back as one block, the drawing keeping its index among the canvas's nodes, now just
        // in front of the block.
        let canvas = OrderBoard()
        let note3 = canvas.addNote(named: "note 3", at: CGPoint(x: 900, y: 100))
        let notes = canvas.group(canvas.note1, note3)
        #expect(canvas.canvasOrder == ["note 2", "drawing", "note 1", "note 3", "G"])
        canvas.store.arrange(.element(notes), .back)
        #expect(canvas.canvasOrder == ["note 1", "note 3", "G", "drawing", "note 2"])
    }

    /// A thing next to a group steps past the whole group: stepped past a member alone, it
    /// was gathered back behind the group at the end of the change, and the command did
    /// nothing though it was on.
    @Test func aThingNextToAGroupStepsPastAllOfIt() {
        let board = OrderBoard()
        board.group(board.b, board.d)
        #expect(board.screenOrder == ["A", "C", "B", "D", "G", "E"])

        #expect(board.store.canArrange(board.c, .forward))
        board.store.arrange(board.c, .forward)
        #expect(board.screenOrder == ["A", "B", "D", "G", "C", "E"])

        board.store.arrange(board.c, .backward)
        #expect(board.screenOrder == ["A", "C", "B", "D", "G", "E"])

        board.store.arrange(board.e, .backward)
        #expect(board.screenOrder == ["A", "C", "E", "B", "D", "G"])
    }

    /// Siri's Change Element Order arranges a member among the others in its group, and says
    /// so when it can go no further there, rather than doing nothing.
    @Test func siriArrangesAMemberWithinItsGroupAndSaysWhenItCantGoFurther() throws {
        let board = OrderBoard()
        board.group(board.b, board.d)

        try ArrangeElementIntent.arrange(board.b, in: board.model, .front, undoManager: nil)
        #expect(board.screenOrder == ["A", "C", "D", "B", "G", "E"])

        let inGroup = #expect(throws: LayerIntentError.self) {
            try ArrangeElementIntent.arrange(board.b, in: board.model, .forward, undoManager: nil)
        }
        #expect(inGroup.map { if case .cantGoFurther(withinGroup: true) = $0 { true } else { false } } == true)
        #expect(board.screenOrder == ["A", "C", "D", "B", "G", "E"])

        // Not in a group, it is told the same, without the group.
        let alone = #expect(throws: LayerIntentError.self) {
            try ArrangeElementIntent.arrange(board.e, in: board.model, .front, undoManager: nil)
        }
        #expect(alone.map { if case .cantGoFurther(withinGroup: false) = $0 { true } else { false } } == true)
        #expect(board.screenOrder == ["A", "C", "D", "B", "G", "E"])
    }

    @Test func arrangingInsideAGroupStaysInside() {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        // D is in front of everything in G, though E is in front of it on the screen.
        #expect(!board.store.canArrange(board.d, .front))
        #expect(!board.store.canArrange(board.d, .forward))
        #expect(!board.store.canArrange(board.b, .back))

        board.store.arrange(board.b, .front)

        #expect(board.screenOrder == ["A", "C", "D", "B", "G", "E"])
        #expect(board.members(of: g) == ["D", "B"])

        // A thing inside and a thing outside each move in their own list, in one step.
        board.store.arrange(board.selection(board.a, board.d), .front)
        #expect(board.screenOrder == ["C", "B", "D", "G", "E", "A"])
        board.undo.undo()
        #expect(board.screenOrder == ["A", "C", "D", "B", "G", "E"])
    }
}

/// A clock for taps that a test moves on by hand: a second tap is a double-tap by the time
/// since the first. Tests that tap the same thing twice wait between taps on it, so that
/// the second is a tap of its own however fast the test runs.
@MainActor
final class TapClock {
    private(set) var now = ContinuousClock.now

    init(_ model: AppModel) {
        model.now = { self.now }
    }

    func wait(_ milliseconds: Int) {
        now += .milliseconds(milliseconds)
    }
}

extension OrderBoard {
    /// The middle of something, in the view: the board shows the canvas unscrolled and
    /// unzoomed, so it is the same point on the canvas.
    fileprivate func middle(of ref: DesignStore.ElementRef) -> CGPoint {
        let frame = store.canvasFrame(of: .element(ref)) ?? .null
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// A loop round an area of the canvas, its corners in turn.
    fileprivate func loop(round area: CGRect) -> [CGPoint] {
        [CGPoint(x: area.minX, y: area.minY), CGPoint(x: area.maxX, y: area.minY), CGPoint(x: area.maxX, y: area.maxY), CGPoint(x: area.minX, y: area.maxY)]
    }
}

/// Selecting with groups: a tap on a grouped thing picks its outermost group, a quick second
/// tap goes one level in, and once something inside a group is selected, taps there pick
/// the next level only. A group is one target, hit anywhere in its box, until something in
/// it is selected; a loop picks whole groups; a drag on a group's target moves the group.
@MainActor
@Suite("Selecting groups")
struct SelectingGroupsTests {
    @Test func aTapOnAMemberPicksItsOutermostGroup() throws {
        let board = OrderBoard()
        let clock = TapClock(board.model)
        let g = board.group(board.b, board.d)
        let g2 = board.group(g, board.c, named: "G2")

        board.model.pick(.element(board.b))
        #expect(board.model.selection == .element(g2))

        // A tap on the group's target, over the member, picks the same; the hover there
        // finds the member, and outlines what a tap would pick.
        board.model.selection = nil
        clock.wait(1000)
        let onB = board.middle(of: board.b)
        board.model.targetTapped(.element(g2), at: onB)
        #expect(board.model.selection == .element(g2))
        let hovered = try #require(board.model.hoverTarget(at: onB))
        #expect(hovered == .element(board.b))
        #expect(board.model.pickTarget(hovered) == .element(g2))

        // Something in no group is picked itself, and added.
        clock.wait(1000)
        board.model.pick(.element(board.a))
        #expect(board.model.selection == .several([.element(g2), .element(board.a)]))
    }

    @Test func aSecondTapWithin350msGoesOneLevelIn() {
        let board = OrderBoard()
        let clock = TapClock(board.model)
        let g = board.group(board.b, board.d)
        board.model.pick(.element(board.b))
        #expect(board.model.selection == .element(g))
        clock.wait(100)
        board.model.pick(.element(board.b))
        #expect(board.model.selection == .element(board.b))

        // Further apart, they are two taps: the second takes the group out again.
        let slow = OrderBoard()
        let slowClock = TapClock(slow.model)
        let h = slow.group(slow.b, slow.d)
        slow.model.pick(.element(slow.b))
        #expect(slow.model.selection == .element(h))
        slowClock.wait(500)
        slow.model.pick(.element(slow.b))
        #expect(slow.model.selection == nil)
    }

    @Test func aDoubleTapIsReadAgainstTheSelectionBeforeIt() {
        let board = OrderBoard()
        let clock = TapClock(board.model)
        let g = board.group(board.b, board.d)

        // G selected: the first tap takes it out at once, and the second goes into it.
        board.model.selection = .element(g)
        board.model.pick(.element(board.b))
        #expect(board.model.selection == nil)
        clock.wait(100)
        board.model.pick(.element(board.b))
        #expect(board.model.selection == .element(board.b))

        // A selected: the first tap adds G, and the second goes into it, keeping A.
        clock.wait(1000)
        board.model.selection = .element(board.a)
        board.model.pick(.element(board.b))
        #expect(board.model.selection == board.selection(board.a, g))
        clock.wait(100)
        board.model.pick(.element(board.b))
        #expect(board.model.selection == board.selection(board.a, board.b))
    }

    @Test func aDoubleTapNeverTakesAThingOut() {
        let board = OrderBoard()
        let clock = TapClock(board.model)
        // Two taps that each acted alone would add A and take it out again.
        board.model.pick(.element(board.a))
        clock.wait(100)
        board.model.pick(.element(board.a))
        #expect(board.model.selection == .element(board.a))
        clock.wait(1000)
        board.model.selection = .element(board.c)
        board.model.pick(.element(board.a))
        clock.wait(100)
        board.model.pick(.element(board.a))
        #expect(board.model.selection == board.selection(board.c, board.a))

        // A selected: the first tap takes it out at once, and the second puts it back.
        clock.wait(1000)
        board.model.selection = .element(board.a)
        board.model.pick(.element(board.a))
        #expect(board.model.selection == nil)
        clock.wait(100)
        board.model.pick(.element(board.a))
        #expect(board.model.selection == .element(board.a))

        // Nor does it add a selected member's group: the member is as far in as it goes.
        let i = board.group(board.b, board.d, named: "I")
        board.group(i, board.c, named: "G2")
        clock.wait(1000)
        board.model.selection = .element(board.b)
        board.model.pick(.element(board.b))
        #expect(board.model.selection == nil)
        clock.wait(100)
        board.model.pick(.element(board.b))
        #expect(board.model.selection == .element(board.b))
    }

    /// Each quick tap after a double-tap goes one level further in, down to the thing itself,
    /// rather than taking what the double-tap picked out again.
    @Test func quickTapsGoOneLevelFurtherInEach() {
        let board = OrderBoard()
        let clock = TapClock(board.model)
        let i = board.group(board.b, board.d, named: "I")
        let g2 = board.group(i, board.c, named: "G2")
        var picked: [CanvasSelection?] = []
        for _ in 0..<4 {
            board.model.pick(.element(board.b))
            picked.append(board.model.selection)
            clock.wait(100)
        }
        #expect(picked == [.element(g2), .element(i), .element(board.b), .element(board.b)])
    }

    /// Review Focus 2: x is in I, which is in G2 with z; A is in H, outside G2.
    @Test func tapsInsideAnEnteredGroupPickTheNextLevelOnly() {
        let board = OrderBoard()
        let clock = TapClock(board.model)
        let (x, y, z) = (board.b, board.d, board.c)
        let i = board.group(x, y, named: "I")
        let g2 = board.group(i, z, named: "G2")
        let h = board.group(board.a, board.e, named: "H")

        // x, selected by double-taps: into G2, and then into I.
        board.model.pick(.element(x))
        clock.wait(100)
        board.model.pick(.element(x))
        #expect(board.model.selection == .element(i))
        clock.wait(1000)
        board.model.pick(.element(x))
        clock.wait(100)
        board.model.pick(.element(x))
        #expect(board.model.selection == .element(x))
        #expect(board.model.enteredGroups == [i.element, g2.element])

        clock.wait(1000)
        board.model.pick(.element(y))
        #expect(board.model.selection == board.selection(x, y))
        clock.wait(1000)
        board.model.pick(.element(z))
        #expect(board.model.selection == board.selection(x, y, z))
        clock.wait(1000)
        board.model.pick(.element(board.a))
        #expect(board.model.selection == board.selection(x, y, z, h))
    }

    @Test func aTapInAGapInsideAGroupsBoxPicksTheGroup() throws {
        let board = OrderBoard()
        let clock = TapClock(board.model)
        board.model.tool = .select
        let g = board.group(board.b, board.d)
        // Between B and C, inside G's box.
        let b = try #require(board.store.canvasFrame(of: .element(board.b)))
        let c = try #require(board.store.canvasFrame(of: .element(board.c)))
        let gap = CGPoint(x: b.midX, y: (b.maxY + c.minY) / 2)
        #expect(try #require(board.store.canvasShape(of: .element(g))).contains(gap))
        #expect(TreeTargets.leaf(at: gap, in: g.element, content: board.store.tree, index: board.store.index) == nil)

        board.model.targetTapped(.element(g), at: gap)
        #expect(board.model.selection == .element(g))

        // In Draw a finger's tap reaches the canvas, which finds the group by its gap too.
        clock.wait(1000)
        board.model.tool = .draw
        #expect(board.model.selection == nil)
        board.model.canvasTapped(at: gap)
        #expect(board.model.selection == .element(g))
        #expect(board.model.hoverTarget(at: gap) == .element(g))

        // Voice looks through a group's gap, as through ink: it sees elements, not groups.
        #expect(board.model.hoverTarget(at: gap, skippingDrawings: true) == .screen(board.screen))
    }

    /// Review Focus 6: a group is one target until something in it is selected; then its
    /// one target is swapped for its members' own.
    @Test func aGroupIsOneTargetUntilItIsEntered() {
        let board = OrderBoard()
        let host = DesignStore.ElementRef.Host.screen(board.screen)
        let g = board.group(board.b, board.d)
        #expect(board.store.treeTargets(entered: []).refs(on: host) == [board.a, board.c, g, board.e])

        board.model.selection = .element(board.b)
        #expect(board.model.enteredGroups == [g.element])
        #expect(board.store.treeTargets(entered: board.model.enteredGroups).refs(on: host) == [board.a, board.c, board.b, board.d, board.e])

        // Inside a group gone into, a group in it is one target, and the rest are their own.
        let g2 = board.group(g, board.c, named: "G2")
        #expect(board.store.treeTargets(entered: []).refs(on: host) == [board.a, g2, board.e])
        #expect(board.store.treeTargets(entered: [g2.element]).refs(on: host) == [board.a, board.c, g, board.e])

        // A hidden group has none, and nor do its members.
        board.store.update(g2) { $0.isHidden = true }
        #expect(board.store.treeTargets(entered: []).refs(on: host) == [board.a, board.e])
        #expect(board.store.treeTargets(entered: [g.element, g2.element]).refs(on: host) == [board.a, board.e])

        // On the open canvas a drawing is picked by its ink, and has no target.
        #expect(board.store.treeTargets(entered: []).refs(on: .canvas) == [board.note1, board.note2])
    }

    @Test func aLoopPicksWholeGroupsNeverMembersAlone() throws {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        let b = try #require(board.store.canvasFrame(of: .element(board.b)))
        #expect(board.store.things(enclosedBy: board.loop(round: b.insetBy(dx: -5, dy: -5))).isEmpty)

        // G's box holds C as well, which isn't in it.
        let box = try #require(board.store.canvasFrame(of: .element(g)))
        #expect(Set(board.store.things(enclosedBy: board.loop(round: box.insetBy(dx: -5, dy: -5)))) == [.element(g), .element(board.c)])

        let all = try #require(board.store.canvasFrame(of: board.selection(board.a, board.e))).insetBy(dx: -5, dy: -5)
        #expect(Set(board.store.things(enclosedBy: board.loop(round: all))) == [.element(board.a), .element(board.c), .element(g), .element(board.e)])

        // Locked or hidden, the group is left alone, and so are its members.
        board.store.setLocked(true, .element(g))
        #expect(Set(board.store.things(enclosedBy: board.loop(round: all))) == [.element(board.a), .element(board.c), .element(board.e)])
        board.store.setLocked(false, .element(g))
        board.store.update(g) { $0.isHidden = true }
        #expect(Set(board.store.things(enclosedBy: board.loop(round: all))) == [.element(board.a), .element(board.c), .element(board.e)])
    }

    @Test func aDragOnAGroupsTargetSelectsTheGroup() throws {
        let board = OrderBoard()
        board.store.updateCanvas { $0.snapsToGuides = false }
        board.model.tool = .select
        let g = board.group(board.b, board.d)
        let drags = CanvasDrags()
        board.model.drags = drags
        let screen = board.store.screen(board.screen)
        func drag(by dx: CGFloat, from start: CGPoint, owner: CanvasDrags.Owner) throws {
            let (element, placement) = try #require(board.store.resolve(g))
            drags.moveOnTarget(g, element: element, placement: placement, on: screen, by: CGSize(width: dx, height: 0), startingAt: start, owner: owner, model: board.model)
        }

        // Nothing selected, or something else: the group alone is selected, and moves.
        for before in [nil, CanvasSelection.element(board.a)] {
            board.model.selection = before
            let owner = CanvasDrags.Owner()
            let start = board.middle(of: board.b)
            try drag(by: 10, from: start, owner: owner)
            #expect(board.model.selection == .element(g))
            #expect(drags.isDragging)
            #expect(board.store.isEditing)
            // It moves as what is selected does, not as one element by its frame.
            #expect(drags.groupOrigins.map { Set($0.keys) } == [.element(g)])
            #expect(drags.elementOrigin == nil)
            try drag(by: 20, from: start, owner: owner)
            drags.dropOnTarget(g, startingAt: start, owner: owner, model: board.model)
            #expect(!drags.isDragging)
            #expect(!board.store.isEditing)
            #expect(board.model.selection == .element(g))
        }

        // Among what is selected, it moves with the rest.
        board.model.selection = board.selection(board.a, g)
        let a = try #require(board.store.canvasFrame(of: .element(board.a)))
        let owner = CanvasDrags.Owner()
        let start = board.middle(of: board.d)
        try drag(by: 10, from: start, owner: owner)
        #expect(board.model.selection == board.selection(board.a, g))
        #expect(board.store.isEditing)
        #expect(board.store.canvasFrame(of: .element(board.a)) == a.offsetBy(dx: 10, dy: 0))
        drags.dropOnTarget(g, startingAt: start, owner: owner, model: board.model)
        #expect(!board.store.isEditing)
        #expect(board.model.selection == board.selection(board.a, g))
    }

    /// The several-things area over a selected group taps through to what is under it, as
    /// the group's own target does: a double-tap there goes into the group.
    @Test func aDoubleTapOnASelectedGroupAmongSeveralGoesIntoIt() {
        let board = OrderBoard()
        let clock = TapClock(board.model)
        let g = board.group(board.b, board.d)
        board.model.selection = board.selection(board.a, g)
        let onB = board.middle(of: board.b)
        board.model.targetTapped(.element(g), at: onB)
        #expect(board.model.selection == .element(board.a))
        clock.wait(100)
        board.model.targetTapped(.element(g), at: onB)
        #expect(board.model.selection == board.selection(board.a, board.b))
    }

    /// Hover asks on every move of the pen; what can be touched is worked out once, and again
    /// only when the design changes or a group is gone into.
    @Test func hoverWorksOutTheTargetsOnceUntilSomethingChanges() throws {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        let (onA, onB) = (board.middle(of: board.a), board.middle(of: board.b))
        let b = try #require(board.store.canvasFrame(of: .element(board.b)))
        let c = try #require(board.store.canvasFrame(of: .element(board.c)))
        let gap = CGPoint(x: b.midX, y: (b.maxY + c.minY) / 2)
        let start = CanvasWork.targetPasses
        for step in 0..<50 {
            _ = board.model.hoverTarget(at: step.isMultiple(of: 2) ? onA : onB)
        }
        #expect(CanvasWork.targetPasses - start == 1)
        #expect(board.model.hoverTarget(at: gap) == .element(g))

        // Gone into, the group's gap is looked through.
        board.model.selection = .element(board.b)
        #expect(board.model.hoverTarget(at: gap) == .screen(board.screen))
        #expect(board.model.hoverTarget(at: onB) == .element(board.b))
        #expect(CanvasWork.targetPasses - start == 2)

        // Hidden, it isn't there to hover over.
        board.model.selection = nil
        board.store.update(g) { $0.isHidden = true }
        #expect(board.model.hoverTarget(at: onB) == .screen(board.screen))
        #expect(CanvasWork.targetPasses - start == 3)
    }

    /// With a finger resting, a double-tap is read against what the first tap started from,
    /// the thing the finger holds included; and the finger lifting is still no tap.
    @Test func aDoubleTapWithAFingerRestingKeepsWhatItHolds() {
        let board = OrderBoard()
        let clock = TapClock(board.model)
        let g = board.group(board.b, board.d)
        let i = board.group(board.c, board.e, named: "I")
        let onB = board.middle(of: board.b)
        board.model.restingFingers = { [onB] }
        board.model.pick(.element(board.c))
        #expect(board.model.selection == board.selection(g, i))
        clock.wait(100)
        board.model.pick(.element(board.c))
        #expect(board.model.selection == board.selection(g, board.c))

        board.model.restingFingers = { [] }
        board.model.fingersLifted()
        clock.wait(1000)
        board.model.targetTapped(.element(g), at: onB)
        #expect(board.model.selection == board.selection(g, board.c))
    }

    /// The thing a resting finger holds is what a tap there would pick: the member's group.
    /// Lifting, the finger reaches the group's target as a tap, which isn't one.
    @Test func aFingerRestingOnAMemberHoldsItsGroup() {
        let board = OrderBoard()
        _ = TapClock(board.model)
        let g = board.group(board.b, board.d)
        let onB = board.middle(of: board.b)
        board.model.restingFingers = { [onB] }
        board.model.pick(.element(board.a))
        #expect(board.model.selection == board.selection(g, board.a))

        board.model.restingFingers = { [] }
        board.model.fingersLifted()
        board.model.targetTapped(.element(g), at: onB)
        #expect(board.model.selection == board.selection(g, board.a))
    }
}

extension OrderBoard {
    /// A second phone screen at half size, right of the open canvas's notes: (900, 50) to
    /// (1096.5, 476) on the canvas. Added after the first, it is drawn over the canvas there.
    fileprivate func addSecondScreen() -> DesignScreen.ID {
        store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 900, y: 50), scale: 0.5)).id
    }

    /// An element's own frame, wherever it lives.
    fileprivate func frame(of ref: DesignStore.ElementRef) -> CGRect? {
        store.element(ref.element)?.frame
    }

    /// The middle of an element's own frame on the canvas, wherever it now lives.
    fileprivate func canvasCentre(of ref: DesignStore.ElementRef) -> CGPoint? {
        guard let element = store.element(ref.element) else { return nil }
        let here = DesignStore.ElementRef(host: element.parent.map { .screen($0) } ?? .canvas, element: ref.element)
        guard let (_, placement) = store.resolve(here) else { return nil }
        let rect = placement.canvasRect(for: element.frame)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    /// One frame of a finger dragging a group's target `translation` across the glass since
    /// it landed at `start`, as `ElementTarget`'s drag makes it.
    fileprivate func dragTarget(_ ref: DesignStore.ElementRef, by translation: CGSize, from start: CGPoint, owner: CanvasDrags.Owner, drags: CanvasDrags) {
        guard let (element, placement) = store.resolve(ref) else { return }
        let screen: DesignScreen? = if case .screen(let id) = ref.host { store.screen(id) } else { nil }
        drags.moveOnTarget(ref, element: element, placement: placement, on: screen, by: translation, startingAt: start, owner: owner, model: model)
    }
}

extension OrderBoard {
    /// How far each of a group's members' middles is from the middle of the group's box, in
    /// their own points (all on one host, at one scale).
    fileprivate func offsets(in group: DesignStore.ElementRef, of members: [DesignStore.ElementRef]) -> [CGPoint] {
        guard let box = store.element(group.element)?.frame else { return [] }
        return members.compactMap { store.element($0.element)?.frame }.map { CGPoint(x: $0.midX - box.midX, y: $0.midY - box.midY) }
    }
}

private func isNear(_ a: CGPoint?, _ b: CGPoint, within slack: CGFloat) -> Bool {
    guard let a else { return false }
    return abs(a.x - b.x) <= slack && abs(a.y - b.y) <= slack
}

/// A group moved, turned and resized as one piece: its members go with it, those locked on
/// their own included, and a locked group stays; dropped on another screen it lands there
/// whole, however its drag ends; turned, its members go round its middle and nested groups
/// turn with it; resized, its members scale in proportion from the corner across, with no
/// shear and no drift.
@MainActor
@Suite("Group geometry")
struct GroupGeometryTests {
    // MARK: Moving

    @Test func movingAGroupMovesItsMembers() throws {
        let board = OrderBoard()
        board.store.updateCanvas { $0.snapsToGuides = false }
        board.model.tool = .select
        let g = board.group(board.b, board.d)
        let drags = CanvasDrags()
        board.model.drags = drags
        let (a, b, d) = (try #require(board.frame(of: board.a)), try #require(board.frame(of: board.b)), try #require(board.frame(of: board.d)))

        // What the group is lined up with as it is dragged leaves out what it holds, which
        // moves with it: dragged a little, it would stick to where it was.
        let others = board.store.canvasFrames(besides: [.element(g)])
        #expect(!others.contains(try #require(board.store.canvasFrame(of: .element(board.b)))))
        #expect(!others.contains(try #require(board.store.canvasFrame(of: .element(board.d)))))
        #expect(others.contains(try #require(board.store.canvasFrame(of: .element(board.a)))))

        // A finger on the group's target, 20 points across the glass: 20 on the canvas, 40
        // of the half-size screen's own.
        let before = board.store.content
        let mark = board.store.historyMark
        let owner = CanvasDrags.Owner()
        let start = board.middle(of: board.b)
        for dx in [5.0, 12.0, 20.0] {
            board.dragTarget(g, by: CGSize(width: dx, height: 0), from: start, owner: owner, drags: drags)
        }
        drags.dropOnTarget(g, startingAt: start, owner: owner, model: board.model)

        #expect(board.frame(of: board.b) == b.offsetBy(dx: 40, dy: 0))
        #expect(board.frame(of: board.d) == d.offsetBy(dx: 40, dy: 0))
        #expect(board.frame(of: board.a) == a)
        #expect(board.model.selection == .element(g))
        #expect(board.screenOrder == ["A", "C", "B", "D", "G", "E"])
        #expect(board.store.historyMark == mark + 1, "the drag is one step")
        #expect(board.undo.undoActionName == "Move")
        board.undo.undo()
        #expect(board.store.content == before)

        // Selected, it is dragged by what drags the selection: 10 down the glass.
        board.model.selection = .element(g)
        let again = board.store.historyMark
        let other = CanvasDrags.Owner()
        drags.moveGroup(by: CGSize(width: 0, height: 4), startingAt: start, owner: other, model: board.model)
        drags.moveGroup(by: CGSize(width: 0, height: 10), startingAt: start, owner: other, model: board.model)
        drags.dropGroup(owner: other, model: board.model)
        #expect(board.frame(of: board.b) == b.offsetBy(dx: 0, dy: 20))
        #expect(board.frame(of: board.d) == d.offsetBy(dx: 0, dy: 20))
        #expect(board.store.historyMark == again + 1)
    }

    /// D3: half of it moves, so that it fails while only the group item's frame is written,
    /// which the pass then fits round members that didn't move.
    @Test func aLockedGroupDoesntMoveAndNeitherDoItsMembers() throws {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        let box = try #require(board.store.canvasFrame(of: .element(g)))
        let (b, d) = (try #require(board.frame(of: board.b)), try #require(board.frame(of: board.d)))

        board.store.position([.element(g): CGPoint(x: box.minX + 20, y: box.minY)])
        #expect(board.frame(of: board.b) == b.offsetBy(dx: 40, dy: 0))
        #expect(board.frame(of: board.d) == d.offsetBy(dx: 40, dy: 0))
        #expect(board.store.canvasFrame(of: .element(g)) == box.offsetBy(dx: 20, dy: 0))

        board.store.setLocked(true, .element(g))
        let locked = board.store.content
        board.store.position([.element(g): CGPoint(x: box.minX + 60, y: box.minY)])
        board.store.position([.element(board.b): CGPoint(x: box.minX - 40, y: box.minY)])
        #expect(board.store.content == locked)
    }

    @Test func aMemberLockedOnItsOwnMovesWithItsGroup() throws {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        board.store.update(board.b) { $0.isLocked = true }
        let box = try #require(board.store.canvasFrame(of: .element(g)))
        let (b, d) = (try #require(board.frame(of: board.b)), try #require(board.frame(of: board.d)))

        board.store.position([.element(g): CGPoint(x: box.minX + 20, y: box.minY - 10)])

        #expect(board.frame(of: board.b) == b.offsetBy(dx: 40, dy: -20))
        #expect(board.frame(of: board.d) == d.offsetBy(dx: 40, dy: -20))
        #expect(board.store.element(board.b.element)?.isLocked == true)
    }

    @Test func droppingAGroupOnAnotherScreenMovesItWhole() throws {
        let board = OrderBoard()
        board.store.updateCanvas { $0.snapsToGuides = false }
        board.model.tool = .select
        let second = board.addSecondScreen()
        let g = board.group(board.b, board.c, board.d)
        let drags = CanvasDrags()
        board.model.drags = drags
        let members = [board.b, board.c, board.d]
        let centres = try members.map { try #require(board.canvasCentre(of: $0)) }
        let before = board.store.content
        let mark = board.store.historyMark

        // Its middle, at (195, 245), dragged 800 points across: over the second screen.
        let owner = CanvasDrags.Owner()
        let start = board.middle(of: board.c)
        board.dragTarget(g, by: CGSize(width: 400, height: 0), from: start, owner: owner, drags: drags)
        board.dragTarget(g, by: CGSize(width: 800, height: 0), from: start, owner: owner, drags: drags)
        drags.dropOnTarget(g, startingAt: start, owner: owner, model: board.model)

        let moved = DesignStore.ElementRef(host: .screen(second), element: g.element)
        #expect(board.model.selection == .element(moved))
        #expect(board.order(on: .screen(second)) == ["B", "C", "D", "G"])
        #expect(board.screenOrder == ["A", "E"])
        for (ref, centre) in zip(members, centres) {
            #expect(board.store.element(ref.element)?.parent == second)
            #expect(board.store.element(ref.element)?.group == g.element)
            // Each keeps its place on the canvas, to half a point of the screen's own.
            #expect(isNear(board.canvasCentre(of: ref), CGPoint(x: centre.x + 800, y: centre.y), within: 0.25))
        }
        #expect(board.store.historyMark == mark + 1, "the drag and its landing are one step")
        board.undo.undo()
        #expect(board.store.content == before)

        // Sticky notes don't go on screens: a group of them dropped on one stays on the open
        // canvas, where it was dropped.
        let notes = board.group(board.note1, board.note2, named: "N")
        let note1 = try #require(board.canvasCentre(of: board.note1))
        let other = CanvasDrags.Owner()
        let onNote = board.middle(of: board.note1)
        board.dragTarget(notes, by: CGSize(width: -500, height: 0), from: onNote, owner: other, drags: drags)
        drags.dropOnTarget(notes, startingAt: onNote, owner: other, model: board.model)
        #expect(board.model.selection == .element(notes))
        for ref in [board.note1, board.note2, notes] {
            #expect(board.store.element(ref.element)?.parent == nil)
        }
        #expect(board.store.element(board.note1.element)?.group == notes.element)
        #expect(isNear(board.canvasCentre(of: board.note1), CGPoint(x: note1.x - 500, y: note1.y), within: 0.001))
    }

    /// How a drag can end without its finger lifting (see `CanvasDrags`).
    enum CutShort: CaseIterable {
        case swiftUICancels, toolChanges, twistTakesOver, pencilLands
    }

    /// C4: a drag cut short lands what it moved as a drop would, in the drag's own step. A
    /// group lands whole, in its order. A twist that takes over goes on turning it there, in
    /// the same step.
    @Test(arguments: CutShort.allCases)
    func aGroupDragCutShortLandsWhole(by cut: CutShort) throws {
        let board = OrderBoard()
        board.store.updateCanvas { $0.snapsToGuides = false }
        board.model.tool = .select
        let second = board.addSecondScreen()
        let g = board.group(board.b, board.c, board.d)
        let drags = CanvasDrags()
        board.model.drags = drags
        let landed = DesignStore.ElementRef(host: .screen(second), element: g.element)
        let before = board.store.content
        let mark = board.store.historyMark

        let owner = CanvasDrags.Owner()
        let start = board.middle(of: board.c)
        if cut == .pencilLands {
            // With the palette up, a selected group is dragged by its area.
            board.model.tool = .draw
            board.model.selection = .element(g)
            drags.moveGroup(by: CGSize(width: 400, height: 0), startingAt: start, owner: owner, model: board.model)
            drags.moveGroup(by: CGSize(width: 800, height: 0), startingAt: start, owner: owner, model: board.model)
        } else {
            board.dragTarget(g, by: CGSize(width: 400, height: 0), from: start, owner: owner, drags: drags)
            board.dragTarget(g, by: CGSize(width: 800, height: 0), from: start, owner: owner, drags: drags)
        }
        let box = try #require(board.store.canvasShape(of: .element(g)))
        let centres = try [board.b, board.c, board.d].map { try #require(board.canvasCentre(of: $0)) }

        switch cut {
        case .swiftUICancels:
            drags.cancel(owner, model: board.model)
            #expect(board.model.selection == .element(landed))
        case .toolChanges:
            board.model.tool = .draw
        case .twistTakesOver:
            #expect(board.model.beginTwist())
            #expect(board.model.selection == .element(landed), "it lands on the second screen as the twist begins")
            board.model.twist(by: 30)
            board.model.endTwist()
            // What SwiftUI still reports of the drag lands nothing.
            board.dragTarget(landed, by: CGSize(width: 820, height: 0), from: start, owner: owner, drags: drags)
            drags.dropOnTarget(landed, startingAt: start, owner: owner, model: board.model)
            #expect(board.store.element(g.element)?.rotation == 30)
            for (ref, centre) in zip([board.b, board.c, board.d], centres) {
                #expect(board.store.element(ref.element)?.rotation == 30)
                #expect(isNear(board.canvasCentre(of: ref), Rotation.rotate(centre, about: box.centre, by: 30), within: 0.5))
            }
            #expect(board.undo.undoActionName == "Move and Rotate")
        case .pencilLands:
            let selected = try #require(board.model.selectionViewRect)
            board.model.pencilTouched(at: CGPoint(x: selected.midX, y: selected.midY))
            #expect(board.model.selection == nil)
            drags.cancel(owner, model: board.model)
            #expect(board.model.selection == nil, "let go of, it isn't selected again")
        }

        #expect(!drags.isDragging && !board.store.isEditing && !board.model.isAdjusting)
        #expect(board.order(on: .screen(second)) == ["B", "C", "D", "G"])
        #expect(board.members(of: landed) == ["B", "C", "D"])
        #expect(board.screenOrder == ["A", "E"])
        #expect(board.store.historyMark == mark + 1, "the drag and its landing are one step")
        board.undo.undo()
        #expect(board.store.content == before)
    }

    /// Review fix 1: a group landing where things are drawn at another scale lands as one
    /// element does, keeping its size in points, scaled about its middle: each member as far
    /// from the box's middle in its own points as before. Kept apart on the canvas instead,
    /// two buttons 10 points apart on the half-size screen overlapped on a full-size one.
    @Test func aGroupLandingWhereThingsAreDrawnAtAnotherScaleArrivesWhole() throws {
        let board = OrderBoard()
        let big = board.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 900, y: 50), scale: 1)).id
        let pair = board.store.setElements([
            OrderBoard.element(.button, named: "P", CGRect(x: 40, y: 760, width: 100, height: 40)),
            OrderBoard.element(.button, named: "Q", CGRect(x: 150, y: 760, width: 100, height: 40)),
        ], on: board.screen)
        let g = board.group(pair[0], pair[1])
        let offsets = board.offsets(in: g, of: pair)
        let box = try #require(board.store.canvasFrame(of: .element(g)))
        let middle = CGPoint(x: box.midX + 900, y: box.midY)

        // Half-size screen to the full-size one.
        board.store.position([.element(g): CGPoint(x: box.minX + 900, y: box.minY)])
        let landed = board.store.rehost(g)
        #expect(landed == DesignStore.ElementRef(host: .screen(big), element: g.element))
        for (now, was) in zip(board.offsets(in: landed, of: pair), offsets) { #expect(isNear(now, was, within: 0.5)) }
        let (p, q) = (try #require(board.frame(of: pair[0])), try #require(board.frame(of: pair[1])))
        #expect(q.minX - p.maxX == 10, "still 10 of their own points apart")
        #expect(p.size == CGSize(width: 100, height: 40))
        let now = try #require(board.store.canvasFrame(of: .element(landed)))
        #expect(isNear(CGPoint(x: now.midX, y: now.midY), middle, within: 0.5), "its middle stays where it was dropped")

        // The open canvas, drawn at full size, to the half-size screen.
        let loose = [
            board.store.addFloating(OrderBoard.element(.button, named: "R", CGRect(x: 500, y: 600, width: 100, height: 40)), scale: 1),
            board.store.addFloating(OrderBoard.element(.button, named: "S", CGRect(x: 610, y: 600, width: 100, height: 40)), scale: 1),
        ]
        let h = board.group(loose[0], loose[1], named: "H")
        let looseOffsets = board.offsets(in: h, of: loose)
        let looseBox = try #require(board.store.canvasFrame(of: .element(h)))
        board.store.position([.element(h): CGPoint(x: looseBox.minX - 405, y: looseBox.minY - 320)])
        let onScreen = board.store.rehost(h)
        #expect(onScreen == DesignStore.ElementRef(host: .screen(board.screen), element: h.element))
        for (now, was) in zip(board.offsets(in: onScreen, of: loose), looseOffsets) { #expect(isNear(now, was, within: 0.5)) }
        #expect(board.frame(of: loose[0])?.size == CGSize(width: 100, height: 40))
    }

    /// Review fix 1, for a turn under way: a twist cutting short a drag onto a screen of another
    /// scale goes on from where the group landed, without a jump.
    @Test func aTwistCuttingShortADragOntoAnotherScaleGoesOnWithoutAJump() throws {
        let board = OrderBoard()
        board.store.updateCanvas { $0.snapsToGuides = false }
        board.model.tool = .select
        let big = board.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 900, y: 50), scale: 1)).id
        let g = board.group(board.b, board.d)
        let drags = CanvasDrags()
        board.model.drags = drags
        let offsets = board.offsets(in: g, of: [board.b, board.d])

        let owner = CanvasDrags.Owner()
        let start = board.middle(of: board.b)
        board.dragTarget(g, by: CGSize(width: 800, height: 0), from: start, owner: owner, drags: drags)
        #expect(board.model.beginTwist())
        let landed = DesignStore.ElementRef(host: .screen(big), element: g.element)
        #expect(board.model.selection == .element(landed))
        for (now, was) in zip(board.offsets(in: landed, of: [board.b, board.d]), offsets) { #expect(isNear(now, was, within: 0.5)) }
        let frames = try [board.b, board.d].map { try #require(board.frame(of: $0)) }
        let box = try #require(board.store.canvasShape(of: .element(landed)))
        let centres = try [board.b, board.d].map { try #require(board.canvasCentre(of: $0)) }

        board.model.twist(by: 0)
        #expect(try [board.b, board.d].map { try #require(board.frame(of: $0)) } == frames, "held where it landed, nothing moves")
        board.model.twist(by: 30)
        for (ref, centre) in zip([board.b, board.d], centres) {
            #expect(board.store.element(ref.element)?.rotation == 30)
            #expect(isNear(board.canvasCentre(of: ref), Rotation.rotate(centre, about: box.centre, by: 30), within: 0.75))
        }
        board.model.endTwist()
        drags.cancel(owner, model: board.model)
    }

    /// A member moved on its own to another screen leaves its group (the pass's rule 1).
    @Test func aMemberDraggedAloneToAnotherScreenLeavesTheGroup() throws {
        let board = OrderBoard()
        board.store.updateCanvas { $0.snapsToGuides = false }
        board.model.tool = .select
        let second = board.addSecondScreen()
        let g = board.group(board.b, board.c, board.d)
        let drags = CanvasDrags()
        board.model.drags = drags
        // Gone into, the group's members have targets of their own.
        board.model.selection = .element(board.b)
        let owner = CanvasDrags.Owner()
        let start = board.middle(of: board.b)
        board.dragTarget(board.b, by: CGSize(width: 800, height: 0), from: start, owner: owner, drags: drags)
        drags.dropOnTarget(board.b, startingAt: start, owner: owner, model: board.model)

        #expect(board.model.selection == .element(DesignStore.ElementRef(host: .screen(second), element: board.b.element)))
        #expect(board.store.element(board.b.element)?.parent == second)
        #expect(board.store.element(board.b.element)?.group == nil)
        #expect(board.members(of: g) == ["C", "D"])
        #expect(board.screenOrder == ["A", "C", "D", "G", "E"])
    }

    // MARK: Turning

    @Test func turningAGroupTurnsItsMembersAboutItsMiddleAndKeepsItsAngle() throws {
        let board = OrderBoard()
        // A long button on the open canvas below the notes, and the notes in a group of their
        // own, already turned a little, all in one group.
        let button = board.store.addFloating(OrderBoard.element(.button, named: "button", CGRect(x: 480, y: 560, width: 320, height: 60)), scale: 1)
        let inner = board.group(board.note1, board.note2, named: "I") { $0.setRotation(10) }
        let g = board.group(button, inner)
        board.model.selection = .element(g)
        let before = board.store.content
        let box = try #require(board.store.canvasShape(of: .element(g)))
        #expect(box.degrees == 0)
        let members = [button, board.note1, board.note2]
        let centres = try members.map { try #require(board.canvasCentre(of: $0)) }
        // The outline is the group's own box.
        let outline = try #require(board.model.selectionShape)
        #expect(outline.degrees == 0 && close(outline.rect, box.rect, within: 0.000_1))

        #expect(board.model.canTurnSelection)
        #expect(board.model.beginTurn())
        board.model.turnSelection(by: 30, snaps: false)
        board.model.endTurn()

        #expect(board.store.element(g.element)?.rotation == 30)
        #expect(board.store.element(inner.element)?.rotation == 40)
        for (ref, centre) in zip(members, centres) {
            #expect(board.store.element(ref.element)?.rotation == 30)
            #expect(isNear(board.canvasCentre(of: ref), Rotation.rotate(centre, about: box.centre, by: 30), within: 0.5))
        }
        // The outline and the knob went round rigidly, and the group's box is at its angle.
        #expect(board.model.selectionShape?.degrees == 30)
        #expect(board.store.canvasShape(of: .element(g))?.degrees == 30)
        #expect(board.model.selectionTurn == 30)
        #expect(board.undo.undoActionName == "Rotate")

        board.model.beginTurn()
        board.model.turnSelection(by: -30, snaps: false)
        board.model.endTurn()
        #expect(board.store.content == before)

        // Reset stands it upright: turned to 50 from 20, it goes back to 0.
        board.model.rotateSelection(by: 20)
        board.model.selection = nil
        board.model.selection = .element(g)
        board.model.rotateSelection(by: 30)
        #expect(board.store.element(g.element)?.rotation == 50)
        board.model.resetSelectionTurn()
        #expect(board.store.element(g.element)?.rotation == nil)
        #expect(board.store.element(inner.element)?.rotation == 10)
        #expect(board.store.element(button.element)?.rotation == nil)
    }

    /// Carried from Task 3: the session reads the lock a group gives, and a turning group
    /// still turns its own members locked on their own.
    @Test func aMemberLockedOnItsOwnTurnsWithItsGroup() throws {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        board.store.update(board.b) { $0.isLocked = true }
        board.model.selection = .element(g)
        let box = try #require(board.store.canvasShape(of: .element(g)))
        let centres = try [board.b, board.d].map { try #require(board.canvasCentre(of: $0)) }
        #expect(board.model.canTurnSelection)

        board.model.rotateSelection(by: 30)

        #expect(board.store.element(g.element)?.rotation == 30)
        for (ref, centre) in zip([board.b, board.d], centres) {
            #expect(board.store.element(ref.element)?.rotation == 30)
            #expect(isNear(board.canvasCentre(of: ref), Rotation.rotate(centre, about: box.centre, by: 30), within: 0.5))
        }

        // Selected on its own, B is locked, and doesn't turn.
        board.model.selection = .element(board.b)
        #expect(!board.model.canTurnSelection)
        // A locked group doesn't turn, and nor does anything in it.
        board.store.setLocked(true, .element(g))
        board.model.selection = .element(g)
        let locked = board.store.content
        #expect(!board.model.canTurnSelection)
        board.model.rotateSelection(by: 30)
        board.model.resetSelectionTurn()
        #expect(board.store.content == locked)
    }

    /// Review fix 5: one group's outline is its turn's, which goes round rigidly with it, not
    /// the box fitted round its members, on whole points of their own, after each step.
    @Test func aSelectedGroupsOutlineGoesRoundRigidly() throws {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        board.model.selection = .element(g)
        let before = try #require(board.model.selectionShape)

        board.model.rotateSelection(by: 30)

        let after = try #require(board.model.selectionShape)
        #expect(after.rect == before.rect && after.degrees == 30)
        // Turning a group sets only its angle (plan 2's must-do, done in plan 4 Task 5): its box goes round
        // rigidly with it, so it is the outline.
        #expect(board.store.canvasShape(of: .element(g)) == after, "the group's box is the outline, turned as one piece")
    }

    /// Review fix 6: turned in many steps, one after another, and back to where it started, a
    /// group with a turned member and a turned group in it is exactly where it was.
    @Test func manyTurnsOfAGroupAddUpWithoutDrift() {
        let board = OrderBoard()
        let button = board.store.addFloating(OrderBoard.element(.button, named: "button", CGRect(x: 480, y: 560, width: 320, height: 60)), scale: 1)
        board.store.update(button) { $0.setRotation(20) }
        let inner = board.group(board.note1, board.note2, named: "I") { $0.setRotation(10) }
        let g = board.group(button, inner)
        board.model.selection = .element(g)
        let before = board.store.content

        for (index, angle) in [17.0, 29, 101, -147].enumerated() {
            #expect(board.model.beginTurn())
            board.model.turnSelection(by: angle, snaps: false)
            board.model.endTurn()
            if index == 1 {
                #expect(board.store.element(g.element)?.rotation == 46)
                #expect(board.store.element(inner.element)?.rotation == 56)
                #expect(board.store.element(button.element)?.rotation == 66)
            }
        }
        #expect(board.store.content == before)
    }

    // MARK: Resizing

    /// Review fix 5: a group's handles resize it in proportion; an element's, in its own axes.
    @Test func aGroupsHandlesResizeItInProportion() {
        let frame = CGRect(x: 10, y: 20, width: 300, height: 400)
        let drag = CGSize(width: 60, height: -20)
        let group = CanvasDrags.resizeRule(for: .group, degrees: 30, corner: .bottomRight)(frame, drag).0
        let button = CanvasDrags.resizeRule(for: .button, degrees: 30, corner: .bottomRight)(frame, drag).0
        #expect(group == ElementLayout.resizedProportionally(frame, degrees: 30, from: .bottomRight, by: drag))
        #expect(button == ElementLayout.resizedTurned(frame, degrees: 30, from: .bottomRight, by: drag, kind: .button))
        #expect(group != button)
    }

    /// Review fix 2: dragged in, a corner shrinks the box as readily as dragged out it grows it.
    /// By the larger factor, a drag in across alone left it as it was.
    @Test func aCornerShrinksAsReadilyAsItGrows() {
        let box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let shrunk = ElementLayout.resizedProportionally(box, degrees: 0, from: .bottomRight, by: CGSize(width: -30, height: 0))
        #expect(close(shrunk, CGRect(x: 0, y: 0, width: 270, height: 360), within: 0.001))
        let grown = ElementLayout.resizedProportionally(box, degrees: 0, from: .bottomRight, by: CGSize(width: 30, height: 0))
        #expect(close(grown, CGRect(x: 0, y: 0, width: 330, height: 440), within: 0.001))
        // In across and a little out down: the bigger change wins.
        let mixed = ElementLayout.resizedProportionally(box, degrees: 0, from: .bottomRight, by: CGSize(width: -30, height: 10))
        #expect(close(mixed, CGRect(x: 0, y: 0, width: 270, height: 360), within: 0.001))
        // From the top-left, the bottom-right stays.
        let fromTop = ElementLayout.resizedProportionally(box, degrees: 0, from: .topLeft, by: CGSize(width: 30, height: 0))
        #expect(close(fromTop, CGRect(x: 30, y: 40, width: 270, height: 360), within: 0.001))
    }

    /// Review fix 3: shrunk, a group goes no smaller than lets each thing in it keep its kind's
    /// smallest size; and a divider, whose height is fixed, keeps its height.
    @Test func aGroupShrinksNoFurtherThanWhatIsInItCanGo() throws {
        let board = OrderBoard()
        let line = board.store.setElements([OrderBoard.element(.divider, named: "line", CGRect(x: 40, y: 300, width: 200, height: 1))], on: board.screen)[0]
        let g = board.group(board.b, line)
        let box = try #require(board.frame(of: g))
        #expect(box == CGRect(x: 40, y: 190, width: 300, height: 111))

        // Asked for a twentieth, its top-left kept: a button can't be under 16 points high, so
        // B, 100 high, stops it at 0.16.
        board.store.resizeGroup(g, to: CGRect(x: box.minX, y: box.minY, width: box.width / 20, height: box.height / 20))

        let b = try #require(board.frame(of: board.b))
        #expect(close(b, CGRect(x: 40, y: 190, width: 48, height: 16), within: 0.001))
        let divider = try #require(board.frame(of: line))
        #expect(divider.height == 1)
        #expect(abs(divider.width - 32) < 0.001)
        #expect(abs(divider.midY - (190 + 110.5 * 0.16)) < 0.001)

        // Grown again, the divider still keeps its height while the button scales.
        let small = try #require(board.frame(of: g))
        board.store.resizeGroup(g, to: CGRect(x: small.minX, y: small.minY, width: small.width * 2, height: small.height * 2))
        #expect(board.frame(of: line)?.height == 1)
        #expect(board.frame(of: board.b).map { abs($0.height - 32) < 0.001 } == true)
    }

    @Test func resizingAGroupScalesItsMembersInProportion() throws {
        let board = OrderBoard()
        var text = OrderBoard.element(.text, named: "T", CGRect(x: 40, y: 300, width: 200, height: 30))
        text.fontSize = 17
        let t = board.store.setElements([text], on: board.screen)[0]
        let g = board.group(board.b, t, board.d)
        let members = [board.b, t, board.d]
        let box = try #require(board.frame(of: g))
        #expect(box == CGRect(x: 40, y: 190, width: 300, height: 400))
        let frames = try members.map { try #require(board.frame(of: $0)) }

        // Doubled from its bottom-right corner: the top-left stays put.
        let doubled = ElementLayout.resizedProportionally(box, degrees: 0, from: .bottomRight, by: CGSize(width: 300, height: 200))
        #expect(doubled == CGRect(x: 40, y: 190, width: 600, height: 800))
        board.store.resizeGroup(g, to: doubled)

        for (ref, was) in zip(members, frames) {
            #expect(board.frame(of: ref) == CGRect(x: 40 + (was.minX - 40) * 2, y: 190 + (was.minY - 190) * 2, width: was.width * 2, height: was.height * 2))
        }
        #expect(board.frame(of: g) == doubled)
        #expect(board.store.element(t.element)?.fontSize == 17)

        // A handle dragged out and back again, 30 frames: each frame is worked out from the
        // group as it was when the drag began, so it lands exactly where it began.
        let doubledFrames = try members.map { try #require(board.frame(of: $0)) }
        let (item, placement) = try #require(board.store.resolve(g))
        let drags = CanvasDrags()
        board.model.drags = drags
        let owner = CanvasDrags.Owner()
        let reach = Array(1...15) + Array((0...14).reversed())
        for (index, step) in reach.enumerated() {
            let translation = CGSize(width: CGFloat(step) * 4, height: CGFloat(step) * 3)
            drags.moveElement(g, from: item.frame, placement: placement, by: translation, startingAt: CGPoint(x: 1, y: 1), findsNewHome: false, owner: owner, model: board.model) {
                { origin, translation in
                    (ElementLayout.resizedProportionally(origin, degrees: item.resolvedRotation, from: .bottomRight, by: translation), [])
                }
            }
            if index == 14 {
                // Out at its furthest: 60 across the glass, 120 of the screen's own, so a fifth
                // as large again, from the top-left.
                #expect(board.frame(of: g).map { close($0, CGRect(x: 40, y: 190, width: 720, height: 960), within: 0.001) } == true)
                #expect(board.frame(of: board.b).map { abs($0.width - 720) < 0.001 && abs($0.height - 240) < 0.001 } == true)
                #expect(board.undo.undoActionName == "Resize")
            }
        }
        drags.dropElement(g, findsNewHome: false, owner: owner, model: board.model)
        #expect(try members.map { try #require(board.frame(of: $0)) } == doubledFrames)
        #expect(board.frame(of: g) == doubled)
        #expect(!board.store.isEditing)
    }

    @Test func aTurnedGroupResizesWithoutShear() throws {
        let board = OrderBoard()
        board.store.update(board.b) { $0.setRotation(10) }
        let g = board.group(board.b, board.d) { $0.setRotation(30) }
        let (item, placement) = try #require(board.store.resolve(g))
        let fixed = TurnedRect(rect: placement.canvasRect(for: item.frame), degrees: 30).corner(.topLeft)
        let (b, d) = (try #require(board.frame(of: board.b)), try #require(board.frame(of: board.d)))

        let frame = ElementLayout.resizedProportionally(item.frame, degrees: 30, from: .bottomRight, by: CGSize(width: 60, height: 20))
        let s = frame.width / item.frame.width
        #expect(s > 1)
        #expect(abs(frame.height / item.frame.height - s) < 0.000_001)
        board.store.resizeGroup(g, to: frame)

        #expect(board.store.element(board.b.element)?.rotation == 10)
        #expect(board.store.element(board.d.element)?.rotation == nil)
        #expect(board.store.element(g.element)?.rotation == 30)
        for (ref, was) in [(board.b, b), (board.d, d)] {
            let now = try #require(board.frame(of: ref))
            #expect(abs(now.width - was.width * s) < 0.000_1 && abs(now.height - was.height * s) < 0.000_1)
        }
        // Fitted round them again, the box is the one asked for, taken out to whole points of its own by the engine's rule
        // (`LayoutEngine.shapesBox`): in proportion, with its top-left corner where it was on the canvas, where its own
        // points start.
        let now = try #require(board.store.canvasShape(of: .element(g)))
        let shapes = try [board.b, board.d].map { ref in
            let element = try #require(board.store.element(ref.element))
            return TurnedRect(rect: element.frame, degrees: element.resolvedRotation)
        }
        let exact = try #require(TurnedRect.enclosing(shapes, at: 30))
        let start = TurnedRect(rect: frame, degrees: 30).corner(.topLeft)
        #expect(close(now.rect, placement.canvasRect(for: wholePointBox(round: exact.corners, at: 30, ownPointsFrom: start))))
        #expect(isNear(now.corner(.topLeft), fixed, within: 0.001))
    }
}

/// A group as one thing: copied whole with everything in it, deleted with everything in it,
/// hidden and locked by its own flags, and formatted from a panel of its own, whose box
/// moves and resizes everything in it in proportion and whose angle turns it as one piece.
@MainActor
@Suite("A group as one thing")
struct GroupAsOneThingTests {
    // MARK: Duplicate

    /// Carried from Task 4 (M5): Duplicate on a selected group copies it whole, as one step,
    /// and selects the copy. A member locked on its own is copied as it is.
    @Test func duplicatingANestedGroupCopiesItWhole() throws {
        let board = OrderBoard()
        board.store.update(board.e) { $0.isLocked = true }
        let i = board.group(board.c, board.e, named: "I")
        let g = board.group(board.a, i, named: "G")
        #expect(board.screenOrder == ["B", "D", "A", "C", "E", "I", "G"])
        let before = board.store.content
        board.model.selection = .element(g)

        board.model.duplicateSelection()

        // The copied block is on top of the screen, in its own order.
        #expect(board.screenOrder == ["B", "D", "A", "C", "E", "I", "G", "A", "C", "E", "I", "G"])
        let copies = Array(board.store.content.children(of: board.screen).suffix(5))
        let originals = Set(before.elements.map(\.id))
        #expect(copies.allSatisfy { !originals.contains($0.id) }, "every copy is new")
        let copy = Dictionary(copies.map { ($0.name ?? "", $0) }, uniquingKeysWith: { first, _ in first })
        let copiedG = try #require(copy["G"]?.id)
        let copiedI = try #require(copy["I"]?.id)
        #expect(board.model.selection == .element(.init(host: g.host, element: copiedG)), "the copy is selected")
        #expect(copy["G"]?.group == nil)
        #expect(copy["A"]?.group == copiedG && copy["I"]?.group == copiedG)
        #expect(copy["C"]?.group == copiedI && copy["E"]?.group == copiedI)
        #expect(copy["E"]?.isLocked == true, "a member locked on its own is copied as it is")
        for name in ["A", "C", "E"] {
            let original = try #require(before.children(of: board.screen).first { $0.name == name })
            #expect(copy[name]?.frame == original.frame.offsetBy(dx: 16, dy: 16), "\(name) is copied 16 points down and to the right")
        }
        // The original is as it was.
        for element in before.elements {
            #expect(board.store.element(element.id) == element)
        }

        board.undo.undo()
        #expect(board.store.content == before, "one step")
    }

    /// Carried from Task 3 (M3): a member's copy goes just in front of it, in its group, in
    /// one step. Put on top of the screen, it pulled the whole group to the front with it.
    /// A group in a group is copied just in front of itself the same way.
    @Test func duplicatingAMemberPutsTheCopyJustInFrontOfItInItsGroup() throws {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        #expect(board.screenOrder == ["A", "C", "B", "D", "G", "E"])
        let before = board.store.content
        board.model.selection = .element(board.b)

        board.model.duplicateSelection()

        #expect(board.screenOrder == ["A", "C", "B", "B", "D", "G", "E"])
        guard case .element(let copy)? = board.model.selection else {
            Issue.record("the copy should be selected")
            return
        }
        #expect(copy != board.b)
        #expect(board.store.element(copy.element)?.group == g.element)
        #expect(board.frame(of: copy) == before.element(board.b.element)?.frame.offsetBy(dx: 16, dy: 16))
        board.undo.undo()
        #expect(board.store.content == before, "one step")

        let nested = OrderBoard()
        let i = nested.group(nested.c, nested.e, named: "I")
        let outer = nested.group(nested.a, i, named: "G")
        nested.model.selection = .element(i)
        nested.model.duplicateSelection()
        #expect(nested.screenOrder == ["B", "D", "A", "C", "E", "I", "C", "E", "I", "G"])
        guard case .element(let copiedI)? = nested.model.selection else {
            Issue.record("the copy should be selected")
            return
        }
        #expect(nested.store.element(copiedI.element)?.group == outer.element)
        #expect(nested.store.content.members(of: copiedI.element).map { $0.name ?? "" } == ["C", "E"])
    }

    /// Carried from Task 3: a screen's copy has copies of its groups, with new ids, their
    /// members pointing at them and nested as they were, each with its own lock and hide, in
    /// one step. They came out ungrouped, with the groups' lock and hide set on the members.
    @Test func duplicatingAScreenCopiesItsGroups() throws {
        let board = OrderBoard()
        let i = board.group(board.c, board.e, named: "I") { $0.isHidden = true }
        board.group(board.a, i, named: "G") { $0.isLocked = true }
        let before = board.store.content
        board.model.selection = .screen(board.screen)

        board.model.duplicateSelection()

        guard case .screen(let copyID)? = board.model.selection else {
            Issue.record("the copy should be selected")
            return
        }
        #expect(copyID != board.screen)
        let copied = board.store.content.children(of: copyID)
        #expect(copied.map { $0.name ?? "" } == board.screenOrder)
        let originals = Set(before.elements.map(\.id))
        #expect(copied.allSatisfy { !originals.contains($0.id) }, "every copy is new")
        let copy = Dictionary(copied.map { ($0.name ?? "", $0) }, uniquingKeysWith: { first, _ in first })
        #expect(copy["G"]?.kind == .group && copy["I"]?.kind == .group)
        #expect(copy["G"]?.group == nil && copy["B"]?.group == nil)
        #expect(copy["A"]?.group == copy["G"]?.id && copy["I"]?.group == copy["G"]?.id)
        #expect(copy["C"]?.group == copy["I"]?.id && copy["E"]?.group == copy["I"]?.id)
        #expect(copy["G"]?.isLocked == true && copy["I"]?.isHidden == true, "the groups keep their own lock and hide")
        #expect(copy["A"]?.isLocked == false && copy["C"]?.isHidden == false, "and the members theirs")
        #expect(board.store.content.children(of: board.screen) == before.children(of: board.screen))

        board.undo.undo()
        #expect(board.store.content == before, "one step")
    }

    // MARK: Delete

    /// Carried from Task 4 (M5): Delete on a selected group deletes it and everything in it,
    /// a member locked on its own too, in one step. A locked group stays.
    @Test func deletingAGroupDeletesItsMembersEvenLockedOnes() {
        let board = OrderBoard()
        board.store.update(board.e) { $0.isLocked = true }
        let i = board.group(board.c, board.e, named: "I")
        let g = board.group(board.a, i, named: "G")
        let before = board.store.content
        board.model.selection = .element(g)

        board.model.deleteSelection()

        #expect(board.screenOrder == ["B", "D"])
        #expect(board.model.selection == nil)
        board.undo.undo()
        #expect(board.store.content == before, "one step")

        // Locked, by itself or by a group above it, a group isn't deleted.
        board.store.update(g) { $0.isLocked = true }
        let locked = board.store.content
        board.model.selection = .element(g)
        board.model.deleteSelection()
        board.store.delete(.element(g))
        board.model.selection = .element(i)
        board.model.deleteSelection()
        #expect(board.store.content == locked)

        // Several things with a group among them: it goes with everything in it.
        board.store.update(g) { $0.isLocked = false }
        board.model.selection = board.selection(board.b, g)
        board.model.deleteSelection()
        #expect(board.screenOrder == ["D"])
    }

    // MARK: Hide

    /// A hidden group's members aren't drawn, keeping their own flags; and hiding it lets go
    /// of it and of anything selected inside it.
    @Test func hidingAGroupHidesItsMembersOnTheBoard() {
        let board = OrderBoard()
        let i = board.group(board.c, board.e, named: "I")
        let g = board.group(board.b, board.d)
        board.model.selection = .element(board.b)

        board.model.toggleHidden(g)

        #expect(board.store.element(g.element)?.isHidden == true, "the group's own flag")
        #expect(board.store.screens[0].elements.filter(\.isHidden).map { $0.name ?? "" } == ["B", "D"])
        #expect(board.store.element(board.b.element)?.isHidden == false && board.store.element(board.d.element)?.isHidden == false)
        #expect(board.model.selection == nil, "the member selected is let go of")

        // Among several things, only what is in the group hidden is let go of.
        board.model.toggleHidden(g)
        board.model.selection = board.selection(board.a, board.c)
        board.model.toggleHidden(i)
        #expect(board.model.selection == .element(board.a))
        // Shown again, nothing is selected again.
        board.model.toggleHidden(i)
        #expect(board.model.selection == .element(board.a))
    }

    // MARK: The Format panel

    /// D3: the W field resizes a group in proportion, from its top-left, through the one entry
    /// point the panel's fields call, in the panel's own step.
    @Test func aGroupsWidthFieldResizesInProportion() throws {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        let box = try #require(board.frame(of: g))
        #expect(box == CGRect(x: 40, y: 190, width: 300, height: 400))

        board.model.setGroupBox(g, width: box.width * 2)

        #expect(board.frame(of: g) == CGRect(x: 40, y: 190, width: 600, height: 800))
        #expect(board.frame(of: board.b) == CGRect(x: 40, y: 190, width: 600, height: 200))
        #expect(board.frame(of: board.d) == CGRect(x: 40, y: 790, width: 600, height: 200))
        #expect(board.undo.undoActionName == "Format")
    }

    /// The model alone, given widths one after another as digits would give them (down to
    /// what it can hold, then up to 706): the group stays selected and comes to the last
    /// width. It covers `setGroupBox`, not the typed field, which now sets once as typing ends.
    @Test func setGroupBoxGivenSuccessiveWidthsKeepsTheGroupSelectedAndEndsAtTheLast() throws {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        board.model.selection = .element(g)
        let box = try #require(board.frame(of: g))

        for width: CGFloat in [box.width / 10, 3, 7, 70, 706] {
            board.model.setGroupBox(g, width: width)
            #expect(board.model.selection == .element(g), "the group stays selected after \(width)")
            #expect(board.store.element(g.element) != nil)
        }

        let frame = try #require(board.frame(of: g))
        #expect(abs(frame.width - 706) < 1, "the group should be 706 wide, not \(frame.width)")
    }

    /// L8: the H field does too. Given to `resizeGroup` as it is, it would scale nothing,
    /// since a group is scaled by the ratio of its widths.
    @Test func aGroupsHeightFieldResizesInProportion() throws {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        let box = try #require(board.frame(of: g))

        board.model.setGroupBox(g, height: box.height * 2)

        #expect(board.frame(of: g) == CGRect(x: 40, y: 190, width: 600, height: 800))
        #expect(board.frame(of: board.b) == CGRect(x: 40, y: 190, width: 600, height: 200))
        #expect(board.frame(of: board.d) == CGRect(x: 40, y: 790, width: 600, height: 200))
    }

    /// L8: the X and Y fields are in the screen's points, as the panel shows them: 10 more is
    /// 10 of the half-scale screen's points, 5 on the canvas. Taken as canvas points it would
    /// move everything 20.
    @Test func aGroupsXFieldMovesItInTheScreensPoints() throws {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        let box = try #require(board.frame(of: g))
        let canvas = try #require(board.store.canvasShape(of: .element(g))?.rect)

        board.model.setGroupBox(g, x: box.minX + 10)

        #expect(board.frame(of: board.b)?.minX == 50)
        #expect(board.frame(of: board.d)?.minX == 50)
        #expect(board.frame(of: g) == box.offsetBy(dx: 10, dy: 0))
        #expect(board.store.canvasShape(of: .element(g))?.rect == canvas.offsetBy(dx: 5, dy: 0))

        board.model.setGroupBox(g, y: box.minY - 20)
        #expect(board.frame(of: board.b)?.minY == 170)
        #expect(board.frame(of: board.d)?.minY == 470)
        #expect(board.undo.undoActionName == "Format")
    }

    /// A locked group's fields change nothing.
    @Test func aLockedGroupsFieldsChangeNothing() {
        let board = OrderBoard()
        let g = board.group(board.b, board.d) { $0.isLocked = true }
        board.model.selection = .element(g)
        let before = board.store.content

        board.model.setGroupBox(g, x: 0, y: 0)
        board.model.setGroupBox(g, width: 30)
        board.model.setGroupRotation(g, to: 45)

        #expect(board.store.content == before)
    }

    /// Carried from Task 6: the Rotation field turns a group as one piece about its middle,
    /// to the angle typed, in the panel's own step; set on the item alone, the members stayed
    /// as they were.
    @Test func aGroupsRotationFieldTurnsItAsOnePiece() throws {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        board.model.selection = .element(g)
        let middle = try #require(board.store.canvasShape(of: .element(g))?.centre)
        let starts = try [board.b, board.d].map { try #require(board.canvasCentre(of: $0)) }

        board.model.setGroupRotation(g, to: 90)

        #expect(board.store.element(g.element)?.rotation == 90)
        #expect(board.store.element(board.b.element)?.rotation == 90)
        #expect(board.store.element(board.d.element)?.rotation == 90)
        for (ref, start) in zip([board.b, board.d], starts) {
            #expect(isNear(board.canvasCentre(of: ref), Rotation.rotate(start, about: middle, by: 90), within: 0.5))
        }
        #expect(board.undo.undoActionName == "Format")

        // Typed again, it turns to the angle typed, not by it.
        board.model.setGroupRotation(g, to: 45)
        #expect(board.store.element(g.element)?.rotation == 45)
        #expect(board.store.element(board.b.element)?.rotation == 45)
    }

    /// Carried from Task 6: Align lines a group up with its screen as one block: everything
    /// in it moves by as much as its box. Set on the item alone, its box was fitted back.
    @Test func aGroupAlignsWithItsScreenAsOneBlock() throws {
        let board = OrderBoard()
        board.store.update(board.d) { $0.frame.origin.x = 80 }
        let g = board.group(board.b, board.d)
        let offsets = board.offsets(in: g, of: [board.b, board.d])
        let width = try #require(board.store.screen(board.screen)?.size.width)

        board.store.align(g, .right)

        #expect(board.frame(of: g)?.maxX == width)
        #expect(board.offsets(in: g, of: [board.b, board.d]) == offsets)
        board.store.align(g, .top)
        #expect(board.frame(of: g)?.minY == 0)
        #expect(board.frame(of: board.b)?.minY == 0)
    }

    /// The panel's style settings for a group, and for several things with a group among
    /// them, are set on what is in the groups, at any depth.
    @Test func aGroupIsStyledThroughItsMembers() {
        let board = OrderBoard()
        let i = board.group(board.c, board.e, named: "I")
        let g = board.group(board.b, i)
        board.model.selection = .element(g)
        #expect(board.model.selectedLeaves.map(\.ref) == [board.b, board.c, board.e])

        board.model.selection = board.selection(board.a, g)
        #expect(board.model.selectedLeaves.map(\.ref) == [board.a, board.b, board.c, board.e])
        let red = RGBColor(hex: 0xFF0000)
        board.model.changeElements(board.model.selectedLeaves.map(\.ref), where: \.hasFill) { $0.tint = red }
        for ref in [board.a, board.b, board.c, board.e] {
            #expect(board.store.element(ref.element)?.tint == red)
        }
        #expect(board.store.element(board.d.element)?.tint != red)
        #expect(board.undo.undoActionName == "Format")
    }

    /// Several things' Rotation field turns each on its own pivot, and a group among them as
    /// one piece about its middle, everything in it going round with it.
    @Test func severalThingsTurnAGroupAmongThemAsOnePiece() throws {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        board.model.selection = board.selection(board.a, g)
        let middle = try #require(board.store.canvasShape(of: .element(g))?.centre)
        let (a, b) = (try #require(board.canvasCentre(of: board.a)), try #require(board.canvasCentre(of: board.b)))

        board.model.setAngle(of: [board.a, g], to: 90)

        #expect(board.store.element(board.a.element)?.rotation == 90)
        #expect(isNear(board.canvasCentre(of: board.a), a, within: 0.5), "A turns on its own pivot")
        #expect(board.store.element(g.element)?.rotation == 90)
        #expect(board.store.element(board.b.element)?.rotation == 90)
        #expect(isNear(board.canvasCentre(of: board.b), Rotation.rotate(b, about: middle, by: 90), within: 0.5), "B goes round G's middle")
        #expect(board.undo.undoActionName == "Format")
    }
}

/// The Layers panel as a tree: groups with their members under them, drawings apart.
@MainActor
@Suite("The layers tree")
struct LayerTreeTests {
    /// The rows of a host with every container open, as `LayerRows` lists them: clause (i) re-expresses the old
    /// nested layers tree on them (the list's, deleted in plan 4's Task 12). Each line's depth says what it is under, and its flags are read from
    /// `isDimmed` (was `isHiddenWithItsGroups`) and `isLocked || isLockedByAncestor` (was `isLockedWithItsGroups`).
    private func rows(_ board: OrderBoard, on host: TreeIndex.Host) -> [LayerLine] {
        let tree = board.store.tree
        func containers(_ node: LayerNode) -> [UUID] { (node.isContainer ? [node.id] : []) + node.children.flatMap(containers) }
        let open = Set((tree.screens.map(\.root) + tree.canvas).flatMap(containers))
        return LayerRows.lines(on: host, in: tree, index: board.store.index, open: open)
    }

    private func names(_ lines: [LayerLine]) -> [String] {
        lines.map(\.name)
    }

    @Test func theTreeListsTopmostFirstWithMembersUnderTheirGroup() throws {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        let outer = board.group(board.a, g, named: "H")
        let lines = rows(board, on: .screen(board.screen))
        // Was: top level ["E", "H", "C"]; under H ["G", "A"]; under G ["D", "B"]: each under its container by depth.
        #expect(names(lines) == ["E", "H", "G", "D", "B", "A", "C"])
        #expect(lines.map(\.depth) == [0, 0, 1, 2, 2, 1, 0])
        #expect(lines.map(\.id) == [board.e, outer, g, board.d, board.b, board.a, board.c].map(\.element))
        // Was: the canvas's tree's names.
        #expect(names(rows(board, on: .canvas)) == ["note 2", "note 1"])
    }

    @Test func rowsKnowWhatIsHiddenAndLockedAboveThem() throws {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        board.store.update(g) { $0.isLocked = true; $0.isHidden = true }
        let lines = rows(board, on: .screen(board.screen))
        let node = try #require(lines.first { $0.ref == g })
        #expect(node.isDimmed && (node.isLocked || node.isLockedByAncestor))
        for child in lines.filter({ $0.list == .node(g.element) }) {
            #expect(child.isDimmed && (child.isLocked || child.isLockedByAncestor))
            #expect(!child.isHidden && !child.isLocked, "its own flags are its own")
        }
        #expect(lines.filter { $0.list == .node(g.element) }.count == 2)
        let other = try #require(lines.first { $0.name == "E" })
        #expect(!other.isDimmed && !(other.isLocked || other.isLockedByAncestor))
    }

    @Test func drawingsAreNotInTheTree() {
        let board = OrderBoard()
        #expect(!rows(board, on: .canvas).contains { $0.ref == board.drawing })
        #expect(LayerRows.drawings(in: board.store.tree) == [board.drawing.element])
        board.addNote(named: "note 3", at: CGPoint(x: 900, y: 100))
        #expect(LayerRows.drawings(in: board.store.tree) == [board.drawing.element])
    }

    @Test func aRowTapAddsOrTakesOutExactlyThatThing() {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)

        board.model.selection = .element(g)
        board.model.pickInList(.element(board.b))
        #expect(board.model.selection == .element(board.b), "the group is B's container, so B replaces it")

        board.model.selection = .element(board.a)
        board.model.pickInList(.element(board.b))
        #expect(board.model.selection == board.selection(board.a, board.b))

        board.model.pickInList(.element(board.b))
        #expect(board.model.selection == .element(board.a), "a selected thing is taken out")

        board.model.selection = .element(board.b)
        board.model.pickInList(.element(g))
        #expect(board.model.selection == .element(g), "adding the group folds B into it")
        #expect(board.model.tool == .select)
    }

    @Test func addingAGroupFoldsInWhatIsSelectedAtAnyDepth() {
        let board = OrderBoard()
        let i = board.group(board.c, board.e, named: "I")
        let g = board.group(board.a, i, named: "G")
        board.model.selection = board.selection(board.c, board.b)
        board.model.pickInList(.element(g))
        #expect(board.model.selection == board.selection(board.b, g))
    }

    @Test func aGroupAddedFromThePanelIsNeverDuplicatedWithItsMember() {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        board.model.selection = .element(board.b)
        board.model.pickInList(.element(g))
        board.model.duplicateSelection()
        #expect(board.screenOrder.filter { $0 == "B" }.count == 2, "B is copied once, with its group")
        #expect(board.screenOrder.filter { $0 == "D" }.count == 2)
        #expect(board.screenOrder.filter { $0 == "G" }.count == 2)
    }

    @Test func aCanvasTapOnAGroupFoldsItsSelectedMembersToo() {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        board.model.selection = board.selection(board.a, board.b)
        // A tap in the gap between the group's members is on the group itself.
        board.model.pick(.element(g))
        #expect(board.model.selection == board.selection(board.a, g), "the tap picks the group, and B goes into it")
    }

    @Test func unlockingAMemberLockedOnlyByItsGroupUnlocksTheGroup() {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        board.store.update(g) { $0.isLocked = true }
        #expect(board.store.isLockedWithItsGroups(board.store.element(board.b.element)!))
        board.model.toggleLock(board.b)
        #expect(board.store.element(g.element)?.isLocked == false)
        #expect(board.store.element(board.b.element)?.isLocked == false, "never locks the member it was asked to unlock")
        board.model.toggleLock(board.b)
        #expect(board.store.element(board.b.element)?.isLocked == true)
    }

    @Test func aLockedDrawingIsTouchedAboveTheNoteItIsDrawnAbove() throws {
        let board = OrderBoard()
        board.store.update(board.drawing) { $0.isLocked = true }
        let note = board.addNote(named: "note 3", at: CGPoint(x: 540, y: 380))
        let ink = try #require(board.store.element(board.drawing.element))
        let point = CGPoint(x: ink.frame.midX, y: ink.frame.midY)
        #expect(board.store.element(note.element)?.frame.contains(point) == true, "they overlap there")

        #expect(board.model.hoverTarget(at: point) == .element(board.drawing))
        let targets = board.store.treeTargets(entered: []).refs(on: .canvas)
        let drawingIndex = try #require(targets.firstIndex(of: board.drawing))
        let noteIndex = try #require(targets.firstIndex(of: note))
        #expect(drawingIndex > noteIndex, "the targets lie as the canvas draws")
        let elements = try #require(board.store.treeTargets(entered: []).byHost[.canvas])
        #expect(elements.last?.id == board.drawing.element)
    }
}
