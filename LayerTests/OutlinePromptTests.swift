import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// The outline a model is taught to write: the grammar's own lines and the example library
/// read back as the parser reads them, fit a phone, and become the library's templates.
@Suite("The outline a model is taught to write")
struct OutlinePromptTests {
    @Test func everyExampleIsAnOutlineWithOnePrimaryAction() {
        for example in ScreenPrompt.library {
            let root = outline(example.lines)
            #expect(Outline.withOnePrimaryAction(root) == root, "\(example.name) should already have one primary action")
            // The parse polishes as it reads, so the looks as written are compared as well: the polish changed none.
            let buttons = leaves(root).filter { $0.kind == .button }
            #expect(buttons.map(\.content.buttonLook) == writtenButtonLooks(example.lines),
                    "\(example.name) is written with a button look the polish changes")
            #expect(buttons.count { ($0.content.buttonLook ?? .filled) == .filled } <= 1, "\(example.name) has more than one filled button")
            #expect(!leaves(root).contains { $0.kind == .text && LookWords.kind(named: $0.content.text) != nil },
                    "\(example.name) has a line that didn't read as its kind")
            #expect(!leaves(root).contains { $0.kind == .text && $0.content.text.hasSuffix(":") },
                    "\(example.name) has a container line that didn't read as one")
            #expect(root.leafCount <= 14, "\(example.name) has \(root.leafCount) elements")
        }
    }

    @Test func theLibraryShowsEachContainer() throws {
        let product = outline(try example("product").lines)
        #expect(product.children.contains { $0.kind == .card })

        // The heading is written straight above the grid, and so is in its section (Task 12's ruling).
        let profile = outline(try example("profile").lines)
        #expect(profile.children.contains { section in
            section.children.first?.content.text == "Recent work" && section.children.dropFirst().contains { child in
                if case .grid(let grid) = child.resolvedLayout { return grid.columns == 3 }
                return false
            }
        })

        // The row is written among the fields, and so is in their section.
        let form = try example("form")
        #expect(outline(form.lines).children.contains { section in
            section.children.map(\.kind) == [.textField, .textField, .group, .textField] && section.children.contains { child in
                guard case .stack(let stack) = child.resolvedLayout, stack.axis == .horizontal else { return false }
                return child.children.map(\.kind) == [.textField, .textField]
            }
        })
        #expect(form.lines.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "row:" },
                "the form's row is written indented, on lines of its own")
    }

    /// No example carries a colour, so the compact prompt, whose rules forbid colour words, never shows one, and the
    /// full prompt's examples keep to its rule of red only for something destructive (Task 12's fix rounds). "text
    /// grey" colours the words, not the element, and is allowed.
    @Test func noExampleCarriesAColour() {
        let colours = ColourWords.named.keys
        for example in ScreenPrompt.library {
            let looks = example.lines.split(separator: "[").dropFirst().map { $0.prefix { $0 != "]" } }
            let coloured = looks.filter { look in
                look.split(separator: ",").contains { colours.contains($0.trimmingCharacters(in: .whitespaces).lowercased()) }
            }
            #expect(coloured.isEmpty, "\(example.name): \(coloured)")
            #expect(!nodes(in: outline(example.lines)).contains { $0.style.tint != nil }, "\(example.name)")
        }
        let settings = ScreenPrompt.instructions(.compact, for: "a settings screen")
        #expect(settings.contains("button: Turn off all notifications [plain]\n"))
        #expect(settings.contains("row: text: Quiet hours | text: 22:00 – 07:00 [right, text grey]"))
    }

    /// No model picks a number (spec §14), so neither prompt teaches a text size, a radius, a border width or an
    /// opacity. A progress bar's `40%` is what it shows, and stays.
    @Test func thePromptsTeachNoLookNumber() {
        for room in [ScreenPrompt.Room.compact, .full] {
            let prompt = ScreenPrompt.instructions(room, for: "a settings screen")
            for number in [/[0-9] ?pt\b/, /radius ?[0-9]/, /border ?[0-9]/, /opacity ?[0-9]/] {
                #expect(!prompt.contains(number), "\(room)")
            }
            #expect(prompt.contains("40% for a progress bar"), "\(room)")
        }
    }

    @Test func everyExampleFitsAPhone() {
        for example in ScreenPrompt.library {
            let laidOut = TreeRules.laidOut(outline(example.lines), deviceID: "iphone", settings: CanvasSettings(), previous: nil)
            let issues = TreeValidator.check(laidOut, on: .iPhone)
            #expect(issues.isEmpty, "\(example.name): \(issues)")
        }
    }

    @Test func theGrammarTeachesTheContainers() {
        let grammar = ScreenPrompt.grammar
        for words in ["row:", "card:", "grid 2:", "two spaces"] {
            #expect(grammar.contains(words), "the grammar should say \(words)")
        }
        for name in ScreenPrompt.kindNames {
            #expect(grammar.contains(name), "the grammar should name \(name)")
        }
    }

    /// The lines the grammar shows its form with are outlines too: each is in the grammar,
    /// reads as what it shows and fits a phone.
    @Test func theGrammarsOwnLinesAreOutlines() throws {
        let grammar = ScreenPrompt.grammar
        let shown = [
            "text field: Card number\nbutton: Skip [plain]",
            "card:\n  text: Arrives Thursday [semibold]\n  body: Free delivery to your door.",
            "row: text: Wi-Fi | toggle [on]",
        ]
        for lines in shown {
            #expect(grammar.contains(lines), "the grammar should show \(lines.debugDescription)")
            let root = outline(lines)
            let laidOut = TreeRules.laidOut(root, deviceID: "iphone", settings: CanvasSettings(), previous: nil)
            #expect(TreeValidator.check(laidOut, on: .iPhone).isEmpty, "\(lines.debugDescription)")
            #expect(!leaves(root).contains { $0.kind == .text && LookWords.kind(named: $0.content.text) != nil })
        }
        #expect(leaves(outline(shown[0])).map(\.kind) == [.textField, .button])
        let card = try #require(outline(shown[1]).children.first)
        #expect(card.kind == .card)
        #expect(card.children.map(\.kind) == [.text, .body])
        let row = try #require(outline(shown[2]).children.first?.children.first)
        #expect(row.children.map(\.kind) == [.text, .toggle])
    }

    @MainActor
    @Test func aTemplateKeepsItsStructure() throws {
        let product = try #require(AssetLibrary.template(named: "Product"))
        #expect(product.children.contains { $0.kind == .card })
        #expect(nodes(in: product).allSatisfy { $0.source?.origin == .template }, "every node is the template's")

        let model = AppModel(document: LayerDocument())
        model.canvasSize = CGSize(width: 1210, height: 834)
        model.viewport = Viewport(offset: .zero, scale: 1)
        model.addAsset(try #require(AssetLibrary.asset(id: "template:Product")), at: CGPoint(x: 600, y: 400))
        let screen = try #require(model.store.tree.screens.first)
        #expect(screen.name == "Product")
        guard case .stack(let stack) = screen.root.resolvedLayout else {
            Issue.record("the template's root is \(screen.root.resolvedLayout), not a stack")
            return
        }
        #expect(stack.axis == .vertical)
        #expect(screen.root.children.contains { $0.kind == .card })
    }

    #if DEBUG
    @Test func aTemplatePreviewIsMadeOnce() {
        let before = AssetLibrary.templatePreviewsMade(named: "Settings")
        let first = AssetLibrary.templatePreview(named: "Settings")
        let afterFirst = AssetLibrary.templatePreviewsMade(named: "Settings")
        // Another test, or the library's view, may have made it already.
        #expect(afterFirst - before <= 1)
        let second = AssetLibrary.templatePreview(named: "Settings")
        #expect(AssetLibrary.templatePreviewsMade(named: "Settings") == afterFirst)
        #expect(afterFirst == 1)
        #expect(first == second)
        #expect(first.contains { $0.kind == .toggle })
        // Laid out on the iPhone: everything inside its screen, below its safe area.
        let phone = CGRect(origin: .zero, size: DeviceFrame.iPhone.size)
        #expect(first.allSatisfy { phone.contains($0.frame) && $0.frame.minY >= DeviceFrame.iPhone.safeTop })
    }
    #endif

    // MARK: Helpers

    private func outline(_ lines: String) -> LayerNode {
        Outline.parse(lines, isComplete: true, tokens: .standard)
    }

    private func example(_ name: String) throws -> ScreenPrompt.Example {
        try #require(ScreenPrompt.library.first { $0.name == name }, "no example named \(name)")
    }

    /// The leaves under `node`, in reading order.
    private func leaves(_ node: LayerNode) -> [LayerNode] {
        node.children.flatMap { $0.isContainer ? leaves($0) : [$0] }
    }

    /// `node` and everything under it.
    private func nodes(in node: LayerNode) -> [LayerNode] {
        [node] + node.children.flatMap(nodes(in:))
    }

    /// The look each button is written with, in reading order, read from its line or its part of a one-line row.
    private func writtenButtonLooks(_ lines: String) -> [ButtonLook?] {
        lines.split(separator: "\n").flatMap { line -> [Substring] in
            let line = line.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("row:") ? line.dropFirst(4).split(separator: "|") : [Substring(line)]
        }
        .flatMap { item -> [ButtonLook?] in
            let item = item.trimmingCharacters(in: .whitespaces)
            guard let colon = item.firstIndex(of: ":"), LookWords.kind(named: String(item[..<colon])) == .button else { return [] }
            let words = item.firstIndex(of: "[").map { item[item.index(after: $0)...].dropLast().split(separator: ",").map(String.init) } ?? []
            return [LookWords.look(from: words).buttonLook]
        }
    }
}
