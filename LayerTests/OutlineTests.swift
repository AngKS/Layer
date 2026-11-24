import CoreGraphics
import Foundation
import Testing
@testable import Layer

@Suite struct OutlineTests {
    /// The spec's example, written as §6 gives it.
    private let specExample = """
        column:
          title: Profile
          row:
            avatar
            text: Alex Tan [bold]
          card:
            text: About me
            body: Designing better experiences.
          grid 2:
            text: 24 Projects
            text: 8 Teams
          button: Edit profile
        row: text: Wi-Fi | toggle [on]
        """

    /// A tree as kinds and layouts: `group(column)[title,group(row)[avatar,text]]`.
    private func shape(_ node: LayerNode) -> String {
        guard node.isContainer else { return node.kind.rawValue }
        let layout: String
        switch node.resolvedLayout {
        case .free: layout = "free"
        case .overlay: layout = "overlay"
        case .grid(let grid): layout = "grid\(grid.columns)"
        case .stack(let stack): layout = stack.axis == .horizontal ? "row" : "column"
        }
        return "\(node.kind.rawValue)(\(layout))[\(node.children.map(shape).joined(separator: ","))]"
    }

    private func keys(_ node: LayerNode) -> [String] {
        [node.source?.key ?? "?"] + node.children.flatMap(keys)
    }

    private func all(_ node: LayerNode) -> [LayerNode] {
        [node] + node.children.flatMap(all)
    }

    private func stack(_ node: LayerNode) -> LayerNode.Stack? {
        if case .stack(let stack) = node.resolvedLayout { return stack }
        return nil
    }

    @Test func theSpecsExampleParses() throws {
        let root = Outline.parse(specExample, isComplete: true)
        #expect(shape(root) == "group(column)[group(column)[title,group(row)[avatar,text],card(column)[text,body],group(grid2)[text,text],button],group(column)[group(row)[text,toggle]]]")
        #expect(stack(root)?.spacing == 24)
        #expect(root.padding == LayerNode.Padding())
        let column = root.child(0)
        #expect(stack(column)?.spacing == 12)
        let card = column.child(2)
        #expect(stack(card)?.spacing == 8)
        #expect(card.padding == LayerNode.Padding(all: 16))
        let section = root.child(1)
        #expect(stack(section)?.spacing == 12)
        #expect(all(root).allSatisfy { $0.source?.origin == .generated })
        #expect(all(root).filter { !$0.isContainer }.allSatisfy {
            $0.width == NaturalSize.defaultSizing(for: $0.kind).width && $0.height == NaturalSize.defaultSizing(for: $0.kind).height
        })
    }

    @Test func consecutiveLeavesFormOneSectionAndABlankLineStartsAnother() {
        let root = Outline.parse("title: A\nbody: B\n\nbutton: C", isComplete: true)
        #expect(shape(root) == "group(column)[group(column)[title,body],group(column)[button]]")
    }

    @Test func looksApply() throws {
        let root = Outline.parse("text: Alex Tan [bold]\nbutton: Skip [plain]\nbutton: Go [red]\ntext: Hi [red, 20pt, text white]", isComplete: true)
        let nodes = root.child(0).children
        #expect(nodes.at(0).style.fontWeight == .bold)
        #expect(nodes.at(0).content.text == "Alex Tan")
        #expect(nodes.at(1).content.buttonLook == .plain)
        #expect(nodes.at(2).style.tint == ColourWords.parse("red"))
        #expect(nodes.at(3).style.fontSize == 20)
        #expect(nodes.at(3).style.textColor == ColourWords.parse("white"))
    }

    @Test func aLineWithoutAKindIsText() {
        let root = Outline.parse("Just some words here", isComplete: true)
        let node = root.child(0).child(0)
        #expect(node.kind == .text)
        #expect(node.content.text == "Just some words here")
        let colon = Outline.parse("Time: 5pm sharp", isComplete: true).child(0).child(0)
        #expect(colon.kind == .text && colon.content.text == "Time: 5pm sharp")
    }

    @Test func fencesHeadingsAndSemicolonsAreTolerated() {
        let root = Outline.parse("```\n# Screen\n- title: A; body: B\n• button: C\n```", isComplete: true)
        #expect(shape(root) == "group(column)[group(column)[title,body,button]]")
    }

    @Test func anUnfinishedLastLineWaits() {
        let root = Outline.parse("title: A\nbutton: Go", isComplete: false)
        #expect(root.children.count == 1)
        #expect(shape(root) == "group(column)[group(column)[title]]")
        #expect(shape(Outline.parse("title: A\nbutton: Go\n", isComplete: false)) == "group(column)[group(column)[title,button]]")
        #expect(shape(Outline.parse("title: A\nbutton: Go", isComplete: true)) == "group(column)[group(column)[title,button]]")
    }

    @Test func keysAreStableWhenLinesAreAdded() {
        let lines = specExample.components(separatedBy: "\n") + ["", "button: Done", "button: Later"]
        var previous = Set<String>()
        for count in 1...lines.count {
            let root = Outline.parse(lines.prefix(count).joined(separator: "\n"), isComplete: true)
            let now = keys(root)
            #expect(Set(now).count == now.count, "keys are unique at \(count) lines")
            #expect(previous.isSubset(of: Set(now)), "keys changed adding line \(count)")
            previous = Set(now)
        }
        let root = Outline.parse("title: A\n\nrow:\n  avatar\n  text: T", isComplete: true)
        #expect(root.child(0).source?.key == "group:0")
        #expect(root.child(1).child(0).source?.key == "row:0/avatar:0")
        let joined = Outline.parse("title: A\nrow:\n  avatar\n  text: T", isComplete: true)
        #expect(joined.child(0).child(1).child(0).source?.key == "group:0/row:0/avatar:0")
        let inline = Outline.parse("title: A\nrow: avatar | text: T", isComplete: true)
        #expect(inline.child(0).child(1).child(0).source?.key == "group:0/row:0/avatar:0")
    }

    /// A container written straight after a section's lines, with no blank line between, joins that section: a form's
    /// fields stay together round the row among them, and a heading stays with the grid under it, 12 points apart rather
    /// than 24. A container that starts a section, first or after a blank line, is still a section of its own.
    @Test func aContainerWrittenStraightAfterASectionsLinesJoinsIt() {
        let form = """
            title: Delivery address

            text field: Full name
            text field: Street and number
            row:
              text field: Postcode
              text field: City
            text field: Phone, for the courier

            button: Continue to payment
            """
        let root = Outline.parse(form, isComplete: true)
        #expect(shape(root) == "group(column)[group(column)[title],group(column)[textField,textField,group(row)[textField,textField],textField],group(column)[button]]")
        #expect(stack(root.child(1))?.spacing == 12)
        #expect(root.child(1).child(2).source?.key == "group:1/row:0")

        let profile = Outline.parse("avatar\ntitle: Maya Okafor\n\ntext: Recent work [semibold]\ngrid 3:\n  image\n  image\n  image", isComplete: true)
        #expect(shape(profile) == "group(column)[group(column)[avatar,title],group(column)[text,group(grid3)[image,image,image]]]")

        let cardFirst = Outline.parse("title: A\n\ncard:\n  text: B\nbutton: C", isComplete: true)
        #expect(shape(cardFirst) == "group(column)[group(column)[title],card(column)[text],group(column)[button]]")

        // Decided as the container opens, so streaming the form a line at a time never changes a key.
        let lines = form.components(separatedBy: "\n")
        var previous = Set<String>()
        for count in 1...lines.count {
            let now = keys(Outline.parse(lines.prefix(count).joined(separator: "\n"), isComplete: false))
            #expect(Set(now).count == now.count, "keys are unique at \(count) lines")
            #expect(previous.isSubset(of: Set(now)), "keys changed adding line \(count)")
            previous = Set(now)
        }
    }

    /// No model picks a number (spec §14): an outline a model writes is read without its text sizes, so a `28pt` leaves
    /// the kind's token size, while its other looks apply. One written by hand still reads them.
    @Test func aGeneratedOutlinesTextSizeLeavesTheTokenSize() throws {
        let written = "body: Arrives Thursday [28pt, bold]\nrow: text: Total | text: £12 [32pt, right]\n"
        var stream = OutlineStream(tokens: .standard)
        let taken = stream.take(written, isComplete: true)
        let generated = try #require(taken)
        let leaves = all(generated).filter { !$0.isContainer }
        #expect(leaves.map(\.style.fontSize) == [nil, nil, nil])
        #expect(leaves.map(NaturalSize.fontSize(of:)) == [DesignTokens.standard.textSizes.body, DesignTokens.standard.textSizes.text,
                                                        DesignTokens.standard.textSizes.text])
        #expect(leaves[0].style.fontWeight == .bold)
        #expect(leaves[2].style.textAlignment == .trailing)
        let byHand = all(Outline.parse(written, isComplete: true)).filter { !$0.isContainer }
        #expect(byHand.map(\.style.fontSize) == [28, nil, 32])
    }

    @Test func awkwardIndentationIsTolerated() {
        let tabbed = Outline.parse("column:\n\ttitle: A\n\trow:\n\t\tavatar\n\t\ttext: T", isComplete: true)
        #expect(shape(tabbed) == "group(column)[group(column)[title,group(row)[avatar,text]]]")

        let threeSpaces = Outline.parse("column:\n   title: A\n   body: B", isComplete: true)
        #expect(shape(threeSpaces) == "group(column)[group(column)[title,body]]")

        let tooDeep = Outline.parse("column:\n          title: A\n                  body: B", isComplete: true)
        #expect(shape(tooDeep) == "group(column)[group(column)[title,body]]")

        let inline = Outline.parse("row: text: a | text: b\n  text: c\ntext: d", isComplete: true)
        #expect(shape(inline) == "group(column)[group(column)[group(row)[text,text,text],text]]")
        #expect(inline.child(0).child(0).children.map(\.content.text) == ["a", "b", "c"])

        let leafUnderLeaf = Outline.parse("title: A\n    body: B", isComplete: true)
        #expect(shape(leafUnderLeaf) == "group(column)[group(column)[title,body]]")

        #expect(shape(Outline.parse("column:\nrow:\n", isComplete: true)) == "group(column)[]")
        #expect(shape(Outline.parse("", isComplete: true)) == "group(column)[]")
    }

    @Test func aVeryDeepOutlineIsBounded() {
        let text = (0..<200).map { String(repeating: "  ", count: $0) + "column:" }.joined(separator: "\n") + "\n" + String(repeating: "  ", count: 200) + "text: deep"
        let root = Outline.parse(text, isComplete: true)
        var depth = 0
        var node = root
        while let child = node.children.first { node = child; depth += 1 }
        #expect(depth <= 33)
        #expect(all(root).contains { $0.content.text == "deep" })
    }

    @Test func gridColumnsAreClamped() throws {
        func columns(_ text: String) -> Int? {
            let root = Outline.parse(text, isComplete: true)
            guard case .grid(let grid) = root.child(0).resolvedLayout else { return nil }
            return grid.columns
        }
        #expect(columns("grid 0:\n  text: a") == 1)
        #expect(columns("grid 40:\n  text: a") == 12)
        #expect(columns("grid 3:\n  text: a") == 3)
    }

    @Test func oneFilledButton() {
        func looks(_ text: String) -> [ButtonLook?] {
            all(Outline.parse(text, isComplete: true)).filter { $0.kind == .button }.map(\.content.buttonLook)
        }
        #expect(looks("button: A\nbutton: B\nbutton: C") == [nil, .bordered, .bordered])
        #expect(looks("button: A\nbutton: B [filled]\nbutton: C") == [.bordered, .filled, .bordered])
        #expect(looks("row: button: A | button: B [filled]") == [.plain, .filled])
        #expect(looks("row: button: A | button: B") == [nil, .plain])
        #expect(looks("button: A [bordered]\nbutton: B [bordered]") == [.bordered, nil])
        #expect(looks("button: A [plain]") == [.plain])
        #expect(looks("button: A [bordered]\nrow: button: B [bordered] | button: C [plain]") == [nil, .bordered, .plain])
    }

    @Test func lookWordsReadTodaysVocabulary() {
        let look = LookWords.look(from: ["Bordered", "#112233", "20pt", "border 3", "radius 12", "fit", "off", "40%", "shadow", "opacity 50%", "centre"])
        #expect(look.buttonLook == .bordered)
        #expect(look.tint == RGBColor(hex: 0x112233))
        #expect(look.fontSize == 20)
        #expect(look.borderWidth == 3)
        #expect(look.cornerRadius == 12)
        #expect(look.width == .fit)
        #expect(look.isOn == false)
        #expect(look.value == 0.4)
        #expect(look.hasShadow == true)
        #expect(look.opacity == 0.5)
        #expect(look.alignment == .center)
        #expect(LookWords.look(from: ["gibberish"]) == Look())
        #expect(LookWords.kind(named: " Button ") == .button)
        #expect(LookWords.kind(named: "group") == nil)
        #expect(ColourWords.named["accent"] == Theme.accent)
    }

    @Test func lookWordsKeepNumbersToSizesThatCanBeDrawn() {
        // Words that read as numbers that aren't any are left out.
        let wild = LookWords.look(from: ["infpt", "radius nan", "border inf", "opacity nan", "nan%"])
        #expect(wild.fontSize == nil)
        #expect(wild.cornerRadius == nil)
        #expect(wild.borderWidth == nil)
        #expect(wild.opacity == nil)
        #expect(wild.value == nil)
        // Ones far too large are brought into range.
        let huge = LookWords.look(from: ["1e308pt", "radius 1e308", "border 1e308", "opacity 1e308"])
        #expect(huge.fontSize == 1_000)
        #expect(huge.cornerRadius == 10_000)
        #expect(huge.borderWidth == 10_000)
        #expect(huge.opacity == 1)
        let small = LookWords.look(from: ["0pt", "radius -4"])
        #expect(small.fontSize == 1)
        #expect(small.cornerRadius == 0)
    }

    @Test func theBlueprintStillReadsItsLooks() throws {
        let blueprint = try #require(ScreenBlueprint.parse("button: Go [bordered, 20pt]"))
        let item = try #require(blueprint.sections.first?.items.first)
        #expect(item.kind == .button)
        #expect(item.text == "Go")
        #expect(item.buttonLook == .bordered)
        #expect(item.fontSize == 20)
        #expect(item.colour == nil)
    }
}

private extension LayerNode {
    /// The child at an index, or an empty placeholder, so a wrong tree fails its expectations and doesn't trap.
    func child(_ index: Int) -> LayerNode {
        children.indices.contains(index) ? children[index] : LayerNode(kind: .shape)
    }
}

private extension Array where Element == LayerNode {
    func at(_ index: Int) -> LayerNode {
        indices.contains(index) ? self[index] : LayerNode(kind: .shape)
    }
}
