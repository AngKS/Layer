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
        let f = board.store.setElements([OrderBoard.element(.button, named: "F", CGRect(x: 40, y: 40, width: 300, height: 100))], on: other.id, replacing: true)[0]
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

        // On the open canvas the drawing keeps its slot, though it is between members.
        let canvas = OrderBoard()
        let note3 = canvas.addNote(named: "note 3", at: CGPoint(x: 900, y: 100))
        let notes = canvas.group(canvas.note1, note3)
        #expect(canvas.canvasOrder == ["note 2", "note 1", "drawing", "note 3", "G"])
        canvas.store.arrange(.element(notes), .back)
        #expect(canvas.canvasOrder == ["note 1", "note 3", "drawing", "G", "note 2"])
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
        #expect(board.store.leaf(at: gap, in: g.element) == nil)

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
        #expect(board.store.targets(on: host, entered: []) == [board.a, board.c, g, board.e])

        board.model.selection = .element(board.b)
        #expect(board.model.enteredGroups == [g.element])
        #expect(board.store.targets(on: host, entered: board.model.enteredGroups) == [board.a, board.c, board.b, board.d, board.e])

        // Inside a group gone into, a group in it is one target, and the rest are their own.
        let g2 = board.group(g, board.c, named: "G2")
        #expect(board.store.targets(on: host, entered: []) == [board.a, g2, board.e])
        #expect(board.store.targets(on: host, entered: [g2.element]) == [board.a, board.c, g, board.e])

        // A hidden group has none, and nor do its members.
        board.store.update(g2) { $0.isHidden = true }
        #expect(board.store.targets(on: host, entered: []) == [board.a, board.e])
        #expect(board.store.targets(on: host, entered: [g.element, g2.element]) == [board.a, board.e])

        // On the open canvas a drawing is picked by its ink, and has no target.
        #expect(board.store.targets(on: .canvas, entered: []) == [board.note1, board.note2])
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

    /// The thing under a tap on a group's target is looked for in the group's own block,
    /// which a drawing keeping its slot can lie inside.
    @Test func aMemberIsFoundPastADrawingInsideItsGroupsBlock() {
        let board = OrderBoard()
        let note3 = board.addNote(named: "note 3", at: CGPoint(x: 900, y: 100))
        let g = board.group(board.note1, note3)
        #expect(board.canvasOrder == ["note 2", "note 1", "drawing", "note 3", "G"])
        #expect(board.store.leaf(at: board.middle(of: board.note1), in: g.element) == board.note1)
        #expect(board.store.leaf(at: board.middle(of: note3), in: g.element) == note3)
        #expect(board.store.leaf(at: board.middle(of: board.note2), in: g.element) == nil)
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
