import A2UICore
import CoreGraphics
import Foundation
import Testing
@testable import Layer

@Suite struct ParsersTakeTokensTests {
    private static let basic = "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"

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

    private var custom: DesignTokens {
        var tokens = DesignTokens()
        tokens.rhythm = [4, 10, 20, 40]
        tokens.card.padding = 20
        return tokens
    }

    private func all(_ node: LayerNode) -> [LayerNode] { [node] + node.children.flatMap(all) }
    private func leaves(_ node: LayerNode) -> [LayerNode] { all(node).filter { !$0.isContainer } }

    private func stackSpacing(_ node: LayerNode) -> CGFloat? {
        if case .stack(let stack) = node.resolvedLayout { return stack.spacing }
        return nil
    }

    private func gaps(_ node: LayerNode) -> [CGFloat] {
        if case .grid(let grid) = node.resolvedLayout { return [grid.columnSpacing, grid.rowSpacing] }
        return []
    }

    // MARK: - Outline

    @Test func theStandardTokensGiveTodaysSpacing() {
        let plain = Outline.parse(specExample, isComplete: true)
        let standard = Outline.parse(specExample, isComplete: true, tokens: .standard)
        let a = all(plain), b = all(standard)
        #expect(a.count == b.count)
        for (x, y) in zip(a, b) {
            #expect(x.layout == y.layout)
            #expect(x.padding == y.padding)
        }
        #expect(stackSpacing(plain) == 24)
        #expect(all(plain).first { $0.kind == .card }?.padding == LayerNode.Padding(all: 16))
    }

    @Test func aDesignsRhythmSetsTheOutlinesSpacing() throws {
        let root = Outline.parse(specExample, isComplete: true, tokens: custom)
        #expect(stackSpacing(root) == 20)
        for section in root.children { #expect(stackSpacing(section) == 10 || section.kind == .card || !gaps(section).isEmpty) }
        let column = try #require(root.children.first)
        #expect(stackSpacing(column) == 10)
        let row = try #require(all(root).first { if case .stack(let s) = $0.resolvedLayout { return s.axis == .horizontal } else { return false } })
        #expect(stackSpacing(row) == 10)
        let grid = try #require(all(root).first { !gaps($0).isEmpty })
        #expect(gaps(grid) == [10, 10])
        let card = try #require(all(root).first { $0.kind == .card })
        #expect(stackSpacing(card) == 10)
        #expect(card.padding == LayerNode.Padding(all: 20))
    }

    @Test func spacingNearestTakesTheCloserStepAndTheSmallerOnATie() {
        var tokens = DesignTokens()
        tokens.rhythm = [8, 16]
        #expect(tokens.spacing(nearest: 12) == 8)
        #expect(DesignTokens.standard.spacing(nearest: 24) == 24)
        #expect(DesignTokens.standard.spacing(nearest: 8) == 8)
    }

    @Test func theBlueprintsOtherRowSpellingsStillRead() throws {
        for text in ["row - button: A | button: B", "side by side: text: Wi-Fi | toggle"] {
            let root = Outline.parse(text, isComplete: true)
            let row = try #require(all(root).first { if case .stack(let s) = $0.resolvedLayout { return s.axis == .horizontal } else { return false } })
            #expect(row.children.count == 2, "\(text)")
        }
    }

    /// Read as a hand-written outline is read, every look number and all. Build Screen reads the same lines as a
    /// model's outline and passes the numbers over (`BuildScreenTests.shortcutsWrittenForTheBlueprintStillBuild`).
    @Test func aHandWrittenOutlineReadsWhatTheBlueprintRead() throws {
        let login = Outline.parse("title: Welcome back\ntext field: Email\ntext field: Password\nbutton: Sign in", isComplete: true)
        #expect(leaves(login).map(\.kind) == [.title, .textField, .textField, .button])
        #expect(leaves(login).map(\.content.text) == ["Welcome back", "Email", "Password", "Sign in"])

        let settings = Outline.parse(
            "heading: Settings\n\nrow: button: Cancel | button: Done [blue, bold, radius 12]\n---\nbody: Tap a row to change it [text #333333, 15pt]",
            isComplete: true)
        #expect(settings.children.count == 3)
        let second = settings.children[1]
        #expect(second.children.count == 1)
        let done = try #require(all(second).first { $0.content.text == "Done" })
        #expect(done.style.tint == ColourWords.named["blue"])
        #expect(done.style.fontWeight == .bold)
        #expect(done.style.cornerRadius == 12)
        let body = try #require(all(settings).first { $0.kind == .body })
        #expect(body.style.textColor == RGBColor(hex: 0x333333))
        #expect(body.style.fontSize == 15)
        let built = Outline.parse(
            "heading: Settings\n\nrow: button: Cancel | button: Done [blue, bold, radius 12]\n---\nbody: Tap a row to change it [text #333333, 15pt]",
            isComplete: true, tokens: .standard, readsLookNumbers: false)
        #expect(all(built).first { $0.content.text == "Done" }?.style.cornerRadius == nil)
        #expect(all(built).first { $0.kind == .body }?.style.fontSize == nil)

        let mixed = Outline.parse("icon: heart.fill; switch; separator; Just some words", isComplete: true)
        #expect(leaves(mixed).map(\.kind) == [.symbol, .toggle, .divider, .text])
        #expect(leaves(mixed)[0].content.symbol == "heart.fill")
        #expect(leaves(mixed)[3].content.text == "Just some words")

        #expect(Outline.parse("   \n---\n", isComplete: true).children.isEmpty)
    }

    @Test func onePrimaryActionWorksOnAnyTree() {
        var root = LayerNode(kind: .group)
        root.layout = .stack(LayerNode.Stack(axis: .vertical, spacing: 12))
        var one = LayerNode(kind: .button), two = LayerNode(kind: .button)
        one.content.buttonLook = nil
        two.content.buttonLook = nil
        root.children = [one, two]
        let fixed = Outline.withOnePrimaryAction(root)
        #expect(fixed.children.map(\.content.buttonLook) == [nil, .bordered])
    }

    // MARK: - A2UI

    private func login() throws -> Data {
        let url = try #require(Bundle(for: TokensBundleMarker.self).url(forResource: "a2ui-scaffold-simple-login-form", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    @Test func importedSpacingComesFromTheTokens() throws {
        let data = try login()
        let imported = A2UIImporter.importJSON(data, tokens: custom, trustsLayerLook: true)
        let root = try #require(imported.screens.first?.root)
        let spacings = all(root).compactMap(stackSpacing).filter { $0 != 0 }
        #expect(!spacings.isEmpty)
        for spacing in spacings { #expect(custom.rhythm.contains(spacing), "\(spacing)") }

        let standard = A2UIImporter.importJSON(data, tokens: .standard, trustsLayerLook: true)
        let plain = A2UIImporter.importJSON(data)
        #expect(standard.screens.map(\.root.layout) == plain.screens.map(\.root.layout))
        #expect(all(try #require(standard.screens.first?.root)).map(\.layout) == all(try #require(plain.screens.first?.root)).map(\.layout))
    }

    private func surface(_ components: String, layerName: String? = nil, catalog: String = LayerCatalog.id) -> Data {
        let metadata = layerName.map { #","metadata":{"extensions":{"layer":{"name":"\#($0)","deviceID":"ipad"}}}"# } ?? ""
        return Data("""
            [{"version":"1.0","createSurface":{"surfaceId":"s","catalogId":"\(catalog)"\(metadata)}},
             {"version":"1.0","updateComponents":{"surfaceId":"s","components":[\(components)]}}]
            """.utf8)
    }

    @Test func aModelsLayerLookIsIgnored() throws {
        let text = surface(#"""
            {"id":"root","component":"Column","children":["t"]},
            {"id":"t","component":"Text","text":"Hi","@metadata":{"extensions":{"layer":{"style":{"fontSize":60}}}}}
            """#, layerName: "Mine")
        for trusts in [false, true] {
            let result = A2UIImporter.importJSON(text, tokens: .standard, trustsLayerLook: trusts)
            let screen = try #require(result.screens.first)
            #expect(all(screen.root).first { $0.kind != .group }?.style.fontSize == (trusts ? 60 : nil))
            #expect(screen.name == (trusts ? "Mine" : nil))
            #expect(screen.deviceID == (trusts ? "ipad" : nil))
        }

        let grid = surface(#"""
            {"id":"root","component":"LayerGrid","columns":2,"columnSpacing":37,"rowSpacing":5,"children":["a","b"]},
            {"id":"a","component":"Text","text":"A"},
            {"id":"b","component":"Text","text":"B"}
            """#)
        for trusts in [false, true] {
            let root = try #require(A2UIImporter.importJSON(grid, tokens: custom, trustsLayerLook: trusts).screens.first?.root)
            // A grid is not a screen root, so a column is added round it.
            let found = try #require(all(root).first { !gaps($0).isEmpty })
            guard case .grid(let layout) = found.resolvedLayout else { continue }
            #expect(layout.columnSpacing == (trusts ? 37 : custom.spacing(nearest: 12)))
            #expect(layout.rowSpacing == (trusts ? 5 : custom.spacing(nearest: 12)))
        }
    }

    @Test func a2uiIsToldFromAnOutline() {
        #expect(A2UIImporter.looksLikeA2UI("  {\"version\":\"1.0\"}"))
        #expect(A2UIImporter.looksLikeA2UI("[{}]"))
        #expect(!A2UIImporter.looksLikeA2UI("title: Hi"))
        #expect(!A2UIImporter.looksLikeA2UI(""))
    }
}

private final class TokensBundleMarker {}
