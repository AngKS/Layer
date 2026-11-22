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
        #expect(close(item.frame, screen.placement.localRect(for: box.rect)))
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

    /// D2: the item starts in front of E, so it has to move back to between D and E.
    @Test func membersAreGatheredWithTheGroupInFrontOfThem() {
        let board = OrderBoard()
        var content = board.store.content
        _ = OrderBoard.addGroup(named: "G", holding: [board.b.element, board.d.element], to: board.screen, in: &content)
        #expect(names(content, on: board.screen) == ["A", "B", "C", "D", "E", "G"])

        content.keepGroupsSound()

        #expect(names(content, on: board.screen) == ["A", "C", "B", "D", "G", "E"])
        // What is on the open canvas doesn't move.
        #expect(names(content, on: nil) == ["note 1", "note 2", "drawing"])
    }

    /// Drawings are in no layer order, so gathering leaves each in the slot it holds, as
    /// arranging does (F7): only the things around it move.
    @Test func aDrawingAmongMembersKeepsItsSlot() {
        let board = OrderBoard()
        board.addNote(named: "note 3", at: CGPoint(x: 900, y: 100))
        var content = board.store.content
        let note3 = content.children(of: nil).last!.id
        _ = OrderBoard.addGroup(named: "G", holding: [board.note1.element, note3], to: nil, in: &content)

        content.keepGroupsSound()

        #expect(names(content, on: nil) == ["note 2", "note 1", "drawing", "note 3", "G"])
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

    // MARK: Files

    /// Review Focus 4.
    @Test func aMemberOfAMissingGroupIsUngrouped() throws {
        let board = OrderBoard()
        var content = board.store.content
        let missing = UUID()
        content.update(board.c.element) { $0.group = missing }
        let data = try JSONEncoder().encode(content)
        // As written: C points at a group the design hasn't got.
        let written = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entry = try #require((written["elements"] as? [[String: Any]])?.first { $0["id"] as? String == board.c.element.uuidString })
        #expect(entry["group"] as? String == missing.uuidString)

        let read = try JSONDecoder().decode(DesignContent.self, from: data)

        #expect(read.element(board.c.element)?.group == nil)
        #expect(names(read, on: board.screen) == ["A", "B", "C", "D", "E"])
    }

    @Test(.timeLimit(.minutes(1)))
    func aGroupOfADrawingOrALoopIsUndone() throws {
        let board = OrderBoard()
        var content = board.store.content
        // A drawing pointing at a group of two notes.
        let notes = OrderBoard.addGroup(named: "N", holding: [board.note1.element, board.note2.element, board.drawing.element], to: nil, in: &content)
        // Two groups pointing at each other, each holding two buttons.
        let first = OrderBoard.addGroup(named: "G1", holding: [board.a.element, board.b.element], to: board.screen, in: &content)
        let second = OrderBoard.addGroup(named: "G2", holding: [board.c.element, board.d.element], to: board.screen, in: &content)
        content.update(first) { $0.group = second }
        content.update(second) { $0.group = first }

        let read = try JSONDecoder().decode(DesignContent.self, from: JSONEncoder().encode(content))

        #expect(read.element(board.drawing.element)?.group == nil)
        #expect(read.members(of: notes).map { $0.name ?? "" } == ["note 1", "note 2"])
        // The loop is broken: nothing is inside itself, and the buttons are still grouped.
        #expect(!(read.element(first)?.group == second && read.element(second)?.group == first))
        for element in read.elements {
            #expect(!read.ancestors(of: element.id).contains(element.id))
        }
        #expect(read.members(of: first).contains { $0.id == board.a.element })
        #expect(read.members(of: second).contains { $0.id == board.c.element })
        for item in read.elements where item.kind == .group {
            #expect(read.members(of: item.id).count >= 2)
        }
    }

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

        // A member's group is written; nothing else says it is in one.
        let written = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(board.store.content)) as? [String: Any])
        let entries = try #require(written["elements"] as? [[String: Any]])
        let pointing = entries.filter { $0["group"] != nil }.compactMap { $0["name"] as? String }
        #expect(Set(pointing) == ["B", "D", "note 1", "note 2"])
    }

    /// Conflict A, build 0.2.0 (4) and later: neither the kind nor the key is known there, so
    /// both are simulated as unknown: the item is an unread element, and the members' key one
    /// that isn't read. Both are written back unchanged, in place.
    @Test func aDesignSavedByABuildThatKnowsNoGroupsKeepsThem() throws {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        var root = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(board.store.content)) as? [String: Any])
        var elements = try #require(root["elements"] as? [[String: Any]])
        for index in elements.indices {
            if elements[index]["id"] as? String == g.element.uuidString { elements[index]["kind"] = "futureGroup" }
            if let pointer = elements[index].removeValue(forKey: "group") { elements[index]["futureGroupID"] = pointer }
        }
        root["elements"] = elements

        let read = try JSONDecoder().decode(DesignContent.self, from: JSONSerialization.data(withJSONObject: root))

        // Here: the item is unread, the members ungrouped, and everything else in place.
        #expect(read.element(g.element) == nil)
        #expect(names(read, on: board.screen) == ["A", "C", "B", "D", "E"])
        #expect(read.elements.allSatisfy { $0.group == nil })
        #expect(read.element(board.b.element)?.unknownKeys.values["futureGroupID"] != nil)

        let again = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(read)) as? [String: Any])
        let written = try #require(again["elements"] as? [[String: Any]])
        #expect(NSArray(array: written) == NSArray(array: elements))
    }

    /// Builds up to 0.2.0 (3) drop keys they don't know when they save: the item comes back,
    /// as an element they couldn't read, but nothing points at it.
    @Test func aDesignWhoseMembersLostTheirPointersOpensUngrouped() throws {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        var root = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(board.store.content)) as? [String: Any])
        var elements = try #require(root["elements"] as? [[String: Any]])
        for index in elements.indices { elements[index].removeValue(forKey: "group") }
        root["elements"] = elements

        let read = try JSONDecoder().decode(DesignContent.self, from: JSONSerialization.data(withJSONObject: root))

        #expect(read.element(g.element) == nil)
        #expect(names(read, on: board.screen) == ["A", "C", "B", "D", "E"])
        #expect(names(read, on: nil) == ["note 1", "note 2", "drawing"])
        #expect(read.elements.allSatisfy { $0.group == nil && $0.kind != .group })
    }

    // MARK: What doesn't know about groups

    @Test func groupItemsAreLeftOutOfWhatIsDrawnExportedAndDescribed() throws {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        let notes = board.group(board.note1, board.note2, named: "N")
        let content = board.store.content

        #expect(content.screens[0].elements.map { $0.name ?? "" } == ["A", "C", "B", "D", "E"])
        #expect(content.floating.map { $0.element.name ?? "" } == ["note 1", "note 2", "drawing"])
        #expect(!content.screens.flatMap(\.elements).contains { $0.kind == .group })
        #expect(!content.floating.contains { $0.element.kind == .group })

        // The code is that of the same design without the group items.
        var plain = content
        plain.remove([g.element, notes.element])
        for member in [board.b, board.d, board.note1, board.note2] { plain.update(member.element) { $0.group = nil } }
        #expect(plain.screens[0].elements.map(\.id) == content.screens[0].elements.map(\.id))
        #expect(SwiftUICodeGenerator.code(for: content.screens[0], typeName: nil, settings: CodeSettings())
            == SwiftUICodeGenerator.code(for: plain.screens[0], typeName: nil, settings: CodeSettings()))

        // Voice's picture of the board lists the members, and no group.
        let picture = CanvasPicture.capture(from: board.model, handles: VoiceHandles())
        #expect(picture.screens.first?.elements.count == 5)
        #expect(picture.loose.count == 2)
        #expect(!(picture.screens.flatMap(\.elements) + picture.loose).contains { $0.kind == ElementKind.group.layerName.lowercased() })

        // Siri's elements are the members too.
        let entities = DesignSnapshot(id: "design", name: "Design", content: content, modified: nil).elements
        #expect(entities.count == 8)
        #expect(!entities.contains { $0.ref?.element == g.element || $0.ref?.element == notes.element })
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
}
