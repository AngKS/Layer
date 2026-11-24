import CoreGraphics
import Foundation
import Testing
@testable import Layer

// PROJECTION: deleted in plan 6
/// The tree read as today's flat list: each host lowered block by block, containers as group
/// items just in front of their children, with absolute poses and the flags the views show.
@Suite struct TreeProjectionTests {
    private static func node(_ kind: ElementKind, _ frame: CGRect, _ children: [LayerNode] = []) -> LayerNode {
        var node = LayerNode(kind: kind)
        node.frame = frame
        node.children = children
        return node
    }

    private static func leaf(_ kind: ElementKind = .text) -> LayerNode {
        node(kind, CGRect(x: 10, y: 10, width: 40, height: 20))
    }

    private static func screen(_ children: [LayerNode], name: String = "S") -> TreeScreen {
        var screen = TreeScreen(name: name, origin: CGPoint(x: 400, y: 100), scale: 0.5, deviceID: nil)
        screen.root.children = children
        return screen
    }

    private static func content(screens: [TreeScreen] = [], canvas: [LayerNode] = []) -> TreeContent {
        var content = TreeContent()
        content.screens = screens
        content.canvas = canvas
        return content
    }

    private static func element(_ id: UUID, in elements: [DesignElement]) throws -> DesignElement {
        try #require(elements.first { $0.id == id })
    }

    private static func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1e-9 }

    @Test func aScreensLeavesAreItsElementsInDrawingOrder() throws {
        let title = Self.node(.title, CGRect(x: 20, y: 80, width: 228, height: 40))
        let image = Self.node(.image, CGRect(x: 200, y: 140, width: 160, height: 120))
        var screen = Self.screen([title, image], name: "Home")
        screen.deviceID = "iphone-17-pro-max"
        screen.isLocked = true
        screen.unknownKeys["future"] = .string("kept")
        let lowered = TreeProjection.lower(Self.content(screens: [screen]))

        let view = try #require(lowered.screens.first)
        #expect(lowered.screens.count == 1)
        #expect(view.elements.map(\.kind) == [.title, .image])
        #expect(view.elements.map(\.frame) == [title.frame, image.frame])
        #expect(view.elements.map(\.id) == [title.id, image.id])
        for element in view.elements {
            #expect(element.parent == screen.id)
            #expect(element.scale == nil)
            #expect(element.group == nil)
        }
        // The view is the screen itself, as it is kept.
        #expect(view.id == screen.id)
        #expect(view.name == "Home")
        #expect(view.origin == screen.origin)
        #expect(view.scale == screen.scale)
        #expect(view.deviceID == "iphone-17-pro-max")
        #expect(view.isLocked == true)
        #expect(view.unknownKeys == screen.unknownKeys)
        #expect(view.resolvedDevice == nil)
    }

    @Test func aContainerIsAGroupItemJustInFrontOfItsChildren() throws {
        let a = Self.leaf(), b = Self.leaf(), c = Self.leaf(), d = Self.leaf()
        let g = Self.node(.group, CGRect(x: 0, y: 0, width: 100, height: 100), [b, c])
        let screen = Self.screen([a, g, d])
        let lowered = TreeProjection.lower(Self.content(screens: [screen]))

        #expect(lowered.elements.map(\.id) == [a.id, b.id, c.id, g.id, d.id])
        #expect(try Self.element(b.id, in: lowered.elements).group == g.id)
        #expect(try Self.element(c.id, in: lowered.elements).group == g.id)
        let item = try Self.element(g.id, in: lowered.elements)
        #expect(item.group == nil)
        #expect(item.kind == .group)
        #expect(try Self.element(a.id, in: lowered.elements).group == nil)
        #expect(lowered.screens.first?.elements.map(\.id) == [a.id, b.id, c.id, d.id])
        #expect(lowered.position == [a.id: 0, b.id: 1, c.id: 2, g.id: 3, d.id: 4])
    }

    @Test func aCardLowersAsAGroupItem() throws {
        let text = Self.leaf(.text)
        let card = Self.node(.card, CGRect(x: 20, y: 20, width: 200, height: 120), [text])
        let lowered = TreeProjection.lower(Self.content(screens: [Self.screen([card])]))

        #expect(lowered.elements.map(\.id) == [text.id, card.id])
        #expect(try Self.element(card.id, in: lowered.elements).kind == .group)
        #expect(try Self.element(text.id, in: lowered.elements).group == card.id)
        #expect(lowered.screens.first?.elements.map(\.id) == [text.id])
    }

    @Test func absolutePosesAddUpTranslationsExactly() throws {
        let child = Self.node(.text, CGRect(x: 10, y: 20, width: 30, height: 40))
        let g = Self.node(.group, CGRect(x: 100, y: 200, width: 50, height: 50), [child])
        let lowered = TreeProjection.lower(Self.content(screens: [Self.screen([g])]))

        #expect(try Self.element(child.id, in: lowered.elements).frame == CGRect(x: 110, y: 220, width: 30, height: 40))
        #expect(lowered.screens.first?.elements.first?.frame == CGRect(x: 110, y: 220, width: 30, height: 40))
    }

    @Test func absolutePosesTurnWithTheirContainerAndNeverScale() throws {
        let child = Self.node(.text, CGRect(x: 0, y: 0, width: 20, height: 20))
        var g = Self.node(.group, CGRect(x: 100, y: 100, width: 200, height: 100), [child])
        g.rotation = 90
        var onCanvas = g
        onCanvas.scale = 0.5
        // On a screen, and on the canvas at half size: the same in the host's own points.
        let lowerings = [
            TreeProjection.lower(Self.content(screens: [Self.screen([g])])),
            TreeProjection.lower(Self.content(canvas: [onCanvas])),
        ]
        for lowered in lowerings {
            let turned = try Self.element(child.id, in: lowered.elements)
            #expect(Self.close(turned.frame.midX, 240) && Self.close(turned.frame.midY, 60))
            #expect(turned.frame.size == CGSize(width: 20, height: 20))
            #expect(turned.rotation == 90)
        }
    }

    /// A pose is composed through every turned container above it, each about its own centre,
    /// innermost first, and the angles add up. Worked by hand: the leaf's centre is (10, 5) in
    /// I, (70, -15) in O, and (315, 170) on the screen; its angle is 90 + 90 + 30.
    @Test func absolutePosesComposeThroughSeveralTurnedContainers() throws {
        var leaf = Self.node(.text, CGRect(x: 0, y: 0, width: 20, height: 10))
        leaf.rotation = 30
        var inner = Self.node(.group, CGRect(x: 0, y: 0, width: 100, height: 50), [leaf])
        inner.rotation = 90
        var outer = Self.node(.group, CGRect(x: 100, y: 100, width: 200, height: 200), [inner])
        outer.rotation = 90
        var onCanvas = outer
        onCanvas.scale = 0.5
        let screens = Self.content(screens: [Self.screen([outer])]), canvas = Self.content(canvas: [onCanvas])

        // On a screen, and on the canvas at half size: the same in the host's own points.
        for lowered in [TreeProjection.lower(screens), TreeProjection.lower(canvas)] {
            let turned = try Self.element(leaf.id, in: lowered.elements)
            #expect(Self.close(turned.frame.midX, 315) && Self.close(turned.frame.midY, 170))
            #expect(turned.frame.size == CGSize(width: 20, height: 10))
            #expect(turned.rotation == 210)
        }
        // The index the store reads agrees, in the host's points: the canvas's are drawn at half size.
        let onScreen = try #require(TreeIndex(screens)[leaf.id]?.hostShape)
        #expect(Self.close(onScreen.centre.x, 315) && Self.close(onScreen.centre.y, 170))
        #expect(onScreen.degrees == 210)
        let drawn = try #require(TreeIndex(canvas)[leaf.id]?.hostShape)
        #expect(Self.close(drawn.centre.x, 157.5) && Self.close(drawn.centre.y, 85))
        #expect(drawn.rect.size == CGSize(width: 10, height: 5))
    }

    @Test func canvasDescendantsShareTheirTopLevelsScale() throws {
        let child = Self.node(.text, CGRect(x: 10, y: 10, width: 40, height: 40))
        var g = Self.node(.group, CGRect(x: 100, y: 100, width: 200, height: 200), [child])
        g.scale = 0.5
        let lowered = TreeProjection.lower(Self.content(canvas: [g]))

        let floating = try #require(lowered.floating.first)
        #expect(lowered.floating.map(\.id) == [child.id])
        #expect(floating.element.frame == CGRect(x: 110, y: 110, width: 40, height: 40))
        #expect(floating.scale == 0.5)
        #expect(floating.element.scale == 0.5)
        #expect(floating.element.parent == nil)
        #expect(try Self.element(g.id, in: lowered.elements).scale == 0.5)
    }

    @Test func shownFlagsComeFromContainersButNotTheScreen() throws {
        let member = Self.leaf(), inHidden = Self.leaf()
        var locked = Self.node(.group, CGRect(x: 0, y: 0, width: 100, height: 100), [member])
        locked.isLocked = true
        var hidden = Self.node(.card, CGRect(x: 0, y: 0, width: 100, height: 100), [inHidden])
        hidden.isHidden = true
        let alone = Self.leaf()
        var lockedScreen = Self.screen([alone], name: "Locked")
        lockedScreen.isLocked = true
        let lowered = TreeProjection.lower(Self.content(screens: [Self.screen([locked, hidden]), lockedScreen]))

        let views = lowered.screens.flatMap(\.elements)
        #expect(try Self.element(member.id, in: views).isLocked)
        #expect(try !Self.element(member.id, in: lowered.elements).isLocked)
        #expect(try Self.element(inHidden.id, in: views).isHidden)
        #expect(try !Self.element(inHidden.id, in: lowered.elements).isHidden)
        #expect(try !Self.element(alone.id, in: views).isLocked)
        #expect(try !Self.element(alone.id, in: lowered.elements).isLocked)
        // The containers keep their own flags in the list.
        #expect(try Self.element(locked.id, in: lowered.elements).isLocked)
        #expect(try Self.element(hidden.id, in: lowered.elements).isHidden)
    }

    @Test func screensComeFirstThenTheCanvas() throws {
        let one = Self.leaf(), two = Self.leaf(), three = Self.leaf()
        var note = Self.leaf(.stickyNote)
        note.scale = 0.75
        let first = Self.screen([one, two], name: "One"), second = Self.screen([three], name: "Two")
        let lowered = TreeProjection.lower(Self.content(screens: [first, second], canvas: [note]))

        #expect(lowered.elements.map(\.id) == [one.id, two.id, three.id, note.id])
        #expect(lowered.elements.map(\.parent) == [first.id, first.id, second.id, nil])
        #expect(lowered.elements.map(\.scale) == [nil, nil, nil, 0.75])
        #expect(lowered.screens.map(\.id) == [first.id, second.id])
        #expect(lowered.floating.map(\.id) == [note.id])
        #expect(lowered.children(of: first.id).map(\.id) == [one.id, two.id])
        #expect(lowered.children(of: nil).map(\.id) == [note.id])
    }

    @Test func aLeafRoundTripsThroughAnElement() throws {
        var e = DesignElement(kind: .button, frame: CGRect(x: 12, y: 34, width: 56, height: 78), text: "Go",
                              tint: RGBColor(hex: 0x123456))
        e.parent = UUID()
        e.scale = 0.75
        e.rotation = 30
        e.symbol = "star.fill"
        e.shape = .star
        e.imageID = UUID()
        e.fontSize = 19
        e.fontWeight = .bold
        e.textColor = RGBColor(hex: 0x654321)
        e.cornerRadius = 6
        e.opacity = 0.5
        e.textAlignment = .trailing
        e.borderColor = RGBColor(hex: 0xABCDEF)
        e.borderWidth = 2
        e.hasShadow = true
        e.name = "Go button"
        e.isLocked = true
        e.isHidden = true
        e.group = UUID()
        e.isOn = false
        e.value = 0.25
        e.buttonLook = .bordered
        e.ink = Data([1, 2, 3])
        e.unknownKeys["future"] = .string("kept")
        // Every field is set away from what a new element has, so none goes unchecked.
        let plain = DesignElement(kind: .title, frame: .zero, text: "", tint: RGBColor(hex: 0x000000))
        let unset = zip(Mirror(reflecting: e).children, Mirror(reflecting: plain).children)
            .filter { String(describing: $0.value) == String(describing: $1.value) }.compactMap { $0.0.label }
        #expect(unset.isEmpty)

        let node = LayerNode(element: e)
        #expect(DesignElement(node: node, frame: e.frame, rotation: e.rotation, parent: e.parent, scale: e.scale, group: e.group) == e)
        #expect(node.width == LayerNode.Sizing(.fixed) && node.height == LayerNode.Sizing(.fixed))
        #expect(node.frame == e.frame)
    }

    @Test func aGroupElementBecomesAFreeContainerSizedToFit() {
        let item = DesignElement(kind: .group, frame: CGRect(x: 5, y: 6, width: 70, height: 80), text: "",
                                 tint: ElementKind.group.spec.tint)
        let node = LayerNode(element: item)
        #expect(node.kind == .group)
        #expect(node.resolvedLayout == .free)
        #expect(node.width == LayerNode.Sizing(.fit) && node.height == LayerNode.Sizing(.fit))
        #expect(node.frame == item.frame)
    }

    @Test func aNodeWithoutATintTakesItsKindsTint() throws {
        let button = Self.leaf(.button)
        #expect(button.style.tint == nil)
        let lowered = TreeProjection.lower(Self.content(screens: [Self.screen([button])]))
        #expect(try Self.element(button.id, in: lowered.elements).tint == ElementKind.button.spec.tint)
    }

    @Test func aPendingPointerIsLoweredAsTheGroup() throws {
        let x = Self.leaf(), b = Self.leaf(), c = Self.leaf()
        let g = Self.node(.group, CGRect(x: 0, y: 0, width: 100, height: 100), [b, c])
        let content = Self.content(screens: [Self.screen([x, g])])
        let lowered = TreeProjection.lower(content, pending: [x.id: g.id])

        #expect(try Self.element(x.id, in: lowered.elements).group == g.id)
        #expect(try Self.element(b.id, in: lowered.elements).group == g.id)
        #expect(try Self.element(x.id, in: TreeProjection.lower(content).elements).group == nil)
    }

    @Test func takingAnUnchangedElementChangesNothing() throws {
        var card = Self.node(.card, CGRect(x: 20, y: 20, width: 200, height: 120), [Self.leaf()])
        card.layout = .stack(LayerNode.Stack(axis: .vertical, spacing: 12))
        card.padding = LayerNode.Padding(all: 16)
        card.width = LayerNode.Sizing(.fill(weight: 1))
        card.height = LayerNode.Sizing(.fit)
        let button = Self.leaf(.button)
        let lowered = TreeProjection.lower(Self.content(screens: [Self.screen([card, button])]))

        for original in [card, button] {
            let element = try Self.element(original.id, in: lowered.elements)
            var taken = original
            taken.take(element, shown: element)
            #expect(taken == original)
            // As a new node takes everything: its own lowering still changes nothing.
            var fresh = original
            fresh.take(element, shown: nil)
            #expect(fresh == original)
        }
    }

    @Test func takingWritesOnlyWhatDiffersFromTheShownElement() throws {
        var text = Self.leaf(.text)
        text.content.text = "Before"
        text.width = LayerNode.Sizing(.fit)
        text.source = LayerNode.Source(origin: .sketch, key: "k")
        text.accessibility = LayerNode.Accessibility(label: "Label", hint: nil)
        var group = Self.node(.group, CGRect(x: 0, y: 0, width: 100, height: 100), [text, Self.leaf()])
        group.isLocked = true
        let lowered = TreeProjection.lower(Self.content(screens: [Self.screen([group])]))
        let shown = try Self.element(text.id, in: lowered.screens.flatMap(\.elements))
        #expect(shown.isLocked)

        // Locked as it was shown, through its group: the node's own lock stays off.
        var edited = shown
        edited.text = "After"
        edited.fontSize = 22
        var taken = text
        taken.take(edited, shown: shown)
        #expect(taken.content.text == "After")
        #expect(taken.style.fontSize == 22)
        #expect(!taken.isLocked)
        #expect(taken.width == text.width && taken.source == text.source && taken.accessibility == text.accessibility)

        // Hidden where it was shown showing: that is written. So is unlocked where it was shown locked.
        edited.isHidden = true
        taken.take(edited, shown: shown)
        #expect(taken.isHidden && !taken.isLocked)
        var lockedItself = text
        lockedItself.isLocked = true
        var unlocked = shown
        unlocked.isLocked = false
        lockedItself.take(unlocked, shown: shown)
        #expect(!lockedItself.isLocked)

        // A tint changed is written.
        var tinted = shown
        tinted.tint = RGBColor(hex: 0xFF0000)
        taken.take(tinted, shown: shown)
        #expect(taken.style.tint == RGBColor(hex: 0xFF0000))
    }

    @Test func aHostLoweredAloneIsItsPartOfTheWholeList() {
        let a = Self.leaf(), b = Self.leaf(), c = Self.leaf()
        let g = Self.node(.group, CGRect(x: 30, y: 40, width: 100, height: 100), [b, c])
        var note = Self.leaf(.stickyNote)
        note.scale = 0.5
        let first = Self.screen([a]), second = Self.screen([g])
        let content = Self.content(screens: [first, second], canvas: [note])
        let lowered = TreeProjection.lower(content, pending: [a.id: g.id])

        #expect(TreeProjection.lowerHost(.screen(second.id), in: content) == lowered.children(of: second.id))
        #expect(TreeProjection.lowerHost(.screen(first.id), in: content, pending: [a.id: g.id]) == lowered.children(of: first.id))
        #expect(TreeProjection.lowerHost(.canvas, in: content) == lowered.children(of: nil))
        #expect(TreeProjection.lowerHost(.screen(UUID()), in: content).isEmpty)
    }

    /// What the lift reads to write over each node only what differs: the lowering's own record of where
    /// each element came from, so nothing restates its walk or how it shows lock and hide.
    @Test func aHostLoweredWithItsNodesPairsEachElementWithTheNodeItCameFrom() throws {
        let a = Self.leaf(), b = Self.leaf(), c = Self.leaf(.button)
        var g = Self.node(.group, CGRect(x: 30, y: 40, width: 100, height: 100), [b, c])
        g.isLocked = true
        g.isHidden = true
        let screen = Self.screen([a, g])
        var note = Self.leaf(.stickyNote)
        note.scale = 0.5
        let content = Self.content(screens: [screen], canvas: [note])
        let pending = [a.id: g.id]
        let lowered = TreeProjection.lowerHostNodes(.screen(screen.id), in: content, pending: pending)

        #expect(lowered.map(\.element) == TreeProjection.lowerHost(.screen(screen.id), in: content, pending: pending))
        #expect(lowered.map(\.node.id) == [a.id, b.id, c.id, g.id])
        #expect(lowered.last?.node == g)
        // The container that holds each node in the tree, whatever pointer is waiting for it.
        #expect(lowered.map(\.holder) == [nil, g.id, g.id, nil])
        #expect(lowered.first?.element.group == g.id)
        // Shown as the views show it: a leaf with its containers' lock and hide, a container as it is kept.
        #expect(lowered.filter { !$0.node.isContainer }.map(\.shown) == TreeProjection.lower(content, pending: pending).screens[0].elements)
        let item = try #require(lowered.last)
        #expect(item.shown == item.element)
        #expect(TreeProjection.lowerHostNodes(.canvas, in: content).map(\.element) == TreeProjection.lowerHost(.canvas, in: content))
        #expect(TreeProjection.lowerHostNodes(.screen(UUID()), in: content).isEmpty)
    }

    @Test func aPoseIsWhereTheLoweringPutsIt() throws {
        let child = Self.node(.text, CGRect(x: 0, y: 0, width: 20, height: 20))
        var turned = Self.node(.group, CGRect(x: 100, y: 100, width: 200, height: 100), [child])
        turned.rotation = 90
        let inner = Self.node(.text, CGRect(x: 10, y: 10, width: 40, height: 40))
        var g = Self.node(.group, CGRect(x: 100, y: 100, width: 200, height: 200), [inner])
        g.scale = 0.5
        let content = Self.content(screens: [Self.screen([turned])], canvas: [g])
        let lowered = TreeProjection.lower(content)

        for id in [child.id, turned.id, inner.id, g.id] {
            let element = try Self.element(id, in: lowered.elements)
            let pose = try #require(TreeProjection.pose(of: id, in: content))
            #expect(pose == TreeProjection.Pose(frame: element.frame, rotation: element.rotation, scale: element.scale))
        }
        #expect(TreeProjection.pose(of: inner.id, in: content)?.scale == 0.5)
        #expect(TreeProjection.pose(of: UUID(), in: content) == nil)
    }

    #if DEBUG
    @MainActor
    @Test func onlyAWholeLoweringIsCounted() {
        let a = Self.leaf()
        let screen = Self.screen([a])
        let content = Self.content(screens: [screen])
        let before = TreeProjection.lowerings
        _ = TreeProjection.lower(content)
        #expect(TreeProjection.lowerings == before + 1)
        _ = TreeProjection.lowerHost(.screen(screen.id), in: content)
        _ = TreeProjection.pose(of: a.id, in: content)
        #expect(TreeProjection.lowerings == before + 1)
    }
    #endif
}
