import CoreGraphics
import Foundation
import Testing
@testable import Layer

// The SwiftUI export on the tree (plan 3, Task 3). A free screen's Structure code is today's
// reading-order inference, byte for byte (`Goldens/Code/sketch-structure.swift.txt`, recorded
// from the generator before it was rewritten, and never recorded again). Laid-out containers,
// cards and column roots are written as §7's table says, with the design's token names.
//
// The profile's goldens are made again by running this suite with the environment variable
// TEST_RUNNER_LAYER_RECORD_CODE set to a folder on this Mac, then copying the files written
// there into `Goldens/Code/`.

private final class ExportBundleMarker {}

@Suite("The SwiftUI export on the tree")
struct SwiftUIExportTests {
    typealias Generator = SwiftUICodeGenerator

    // MARK: - Making designs

    /// A leaf sized as a generated one of its kind is, or fixed at `frame` when one is given.
    static func leaf(_ kind: ElementKind, _ text: String? = nil, frame: CGRect? = nil) -> LayerNode {
        var node = LayerNode(kind: kind)
        node.content.text = text ?? kind.placeholder
        if let frame {
            node.frame = frame
        } else {
            (node.width, node.height) = NaturalSize.defaultSizing(for: kind)
        }
        return node
    }

    static func text(_ words: String, frame: CGRect? = nil) -> LayerNode { leaf(.text, words, frame: frame) }

    static func container(_ kind: ElementKind = .group, _ layout: LayerNode.Layout, _ children: [LayerNode],
                          width: LayerNode.Sizing.Mode = .fill(weight: 1), height: LayerNode.Sizing.Mode = .fit) -> LayerNode {
        var node = LayerNode(kind: kind)
        node.layout = layout
        node.children = children
        node.width = LayerNode.Sizing(width)
        node.height = LayerNode.Sizing(height)
        return node
    }

    static func stack(_ axis: LayerNode.Axis, spacing: CGFloat, alignment: LayerNode.CrossAlignment = .start,
                      justify: LayerNode.Justify = .start) -> LayerNode.Layout {
        .stack(LayerNode.Stack(axis: axis, spacing: spacing, alignment: alignment, justify: justify))
    }

    /// A free container at `frame`, fixed there, holding `children` at their frames.
    static func free(_ kind: ElementKind = .group, at frame: CGRect, _ children: [LayerNode]) -> LayerNode {
        var node = LayerNode(kind: kind)
        node.layout = .free
        node.frame = frame
        node.children = children
        return node
    }

    /// A design of one screen per root, laid out by the rules as the store lays out a design it opens.
    static func design(_ roots: [(layout: LayerNode.Layout, children: [LayerNode])], devices: [String?]? = nil,
                       names: [String]? = nil, tokens: DesignTokens = .standard,
                       customDevices: [DeviceFrame] = [], appliesRules: Bool = true) -> TreeContent {
        var content = TreeContent()
        content.settings.tokens = tokens
        content.settings.customDevices = customDevices
        for (index, root) in roots.enumerated() {
            var screen = TreeScreen(name: names?[index] ?? "Screen \(index + 1)", origin: CGPoint(x: CGFloat(index) * 1000, y: 0),
                                    scale: 1, deviceID: devices?[index] ?? nil)
            screen.root.layout = root.layout
            screen.root.children = root.children
            content.screens.append(screen)
        }
        if appliesRules { TreeRules.apply(to: &content, after: nil) }
        return content
    }

    static func design(_ layout: LayerNode.Layout, _ children: [LayerNode], device: String? = nil,
                       tokens: DesignTokens = .standard) -> TreeContent {
        design([(layout, children)], devices: [device], tokens: tokens)
    }

    static func code(_ content: TreeContent, screen index: Int = 0, settings: CodeSettings = CodeSettings()) -> String {
        Generator.code(for: content.screens[index], in: Generator.Context(content), settings: settings)
    }

    static func lines(_ code: String) -> [String] {
        code.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }

    /// The lines of the first view that starts with `prefix`, as written: its first line, every
    /// line indented further, and its own closing braces and modifiers.
    private static func rawBlock(startingWith prefix: String, in code: String) -> [String] {
        let raw = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = raw.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) }) else { return [] }
        let depth = indent(raw[start])
        var found = [raw[start]]
        for line in raw[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let sameDepthPart = indent(line) == depth && (trimmed.hasPrefix("}") || trimmed.hasPrefix("."))
            guard !trimmed.isEmpty, indent(line) > depth || sameDepthPart else { break }
            found.append(line)
        }
        return found
    }

    /// `rawBlock`, trimmed.
    static func block(startingWith prefix: String, in code: String) -> [String] {
        rawBlock(startingWith: prefix, in: code).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The lines between the opening line of the first view that starts with `prefix` and its
    /// own closing brace, trimmed: what a stack holds.
    static func inside(startingWith prefix: String, in code: String) -> [String] {
        let raw = rawBlock(startingWith: prefix, in: code)
        guard let first = raw.first else { return [] }
        let depth = indent(first)
        return raw.dropFirst()
            .prefix { !(indent($0) == depth && $0.trimmingCharacters(in: .whitespaces).hasPrefix("}")) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The modifiers after the closing brace of the first view that starts with `prefix`, trimmed.
    static func modifiers(startingWith prefix: String, in code: String) -> [String] {
        let raw = rawBlock(startingWith: prefix, in: code)
        guard let first = raw.first,
              let close = raw.lastIndex(where: { indent($0) == indent(first) && $0.trimmingCharacters(in: .whitespaces).hasPrefix("}") })
        else { return [] }
        return raw[(close + 1)...].map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func number(_ value: CGFloat) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(Double(rounded))
    }

    // MARK: - Fixtures and goldens

    static func fixture(_ name: String) throws -> TreeContent {
        let url = try #require(Bundle(for: ExportBundleMarker.self).url(forResource: name, withExtension: "json"))
        var content = try TreeManifest.decode(try Data(contentsOf: url)).content
        TreeRules.apply(to: &content, after: nil)
        return content
    }

    static func golden(_ name: String) throws -> String {
        let url = try #require(Bundle(for: ExportBundleMarker.self).url(forResource: name, withExtension: "txt"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Rows, columns, grids, overlays and cards

    @Test func aRowOrColumnIsAStack() {
        let row = Self.container(.group, Self.stack(.horizontal, spacing: 12, alignment: .center), [Self.text("Name"), Self.text("Value")])
        let lines = Self.lines(Self.code(Self.design(Self.stack(.vertical, spacing: 16, alignment: .start), [row])))
        #expect(lines.contains("VStack(alignment: .leading, spacing: DesignTokens.rhythm[2]) {"))
        #expect(lines.contains("HStack(alignment: .center, spacing: DesignTokens.rhythm[1]) {"))
    }

    @Test func aSpacingOffTheRhythmIsANumber() {
        let code = Self.code(Self.design(Self.stack(.vertical, spacing: 10), [Self.text("One"), Self.text("Two")]))
        #expect(code.contains("spacing: 10)"))
        #expect(Self.lines(code).contains("VStack(alignment: .leading, spacing: 10) {"))
    }

    @Test func crossAxisFillStretchesAllButFixedShapes() {
        var field = Self.leaf(.textField)
        field.width = LayerNode.Sizing(.fit)
        let toggle = Self.leaf(.toggle)
        let code = Self.code(Self.design(Self.stack(.vertical, spacing: 16, alignment: .fill), [field, toggle]))
        #expect(Self.lines(code).contains { $0.hasPrefix("VStack(alignment: .leading, spacing:") })
        let fieldLines = Self.block(startingWith: "TextField(", in: code)
        let toggleLines = Self.block(startingWith: "Toggle(", in: code)
        #expect(!fieldLines.isEmpty && !toggleLines.isEmpty)
        #expect(fieldLines.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        #expect(!toggleLines.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        #expect(!toggleLines.contains { $0.hasPrefix(".frame(") })
    }

    /// Words stretched across a `.fill` column keep their alignment in the room, as the canvas draws
    /// them; centred is SwiftUI's default, so its frame names none. Anything else sits at the start (F6).
    @Test func centredTextInAStretchedColumnExportsCentred() {
        var title = Self.leaf(.title, "Centred")
        title.width = LayerNode.Sizing(.fit)
        var trailing = Self.leaf(.body, "Trailing")
        trailing.style.textAlignment = .trailing
        var leading = Self.text("Leading")
        leading.width = LayerNode.Sizing(.fit)
        var field = Self.leaf(.textField)
        field.width = LayerNode.Sizing(.fit)
        var button = Self.leaf(.button, "Continue")
        button.width = LayerNode.Sizing(.fit)
        let code = Self.code(Self.design(Self.stack(.vertical, spacing: 16, alignment: .fill), [title, trailing, leading, field, button]))

        let centred = Self.block(startingWith: "Text(\"Centred\")", in: code)
        #expect(centred.contains(".frame(maxWidth: .infinity)"))
        #expect(!centred.contains { $0.hasPrefix(".frame(maxWidth: .infinity, alignment:") })
        #expect(Self.block(startingWith: "Text(\"Trailing\")", in: code).contains(".frame(maxWidth: .infinity, alignment: .trailing)"))
        #expect(Self.block(startingWith: "Text(\"Leading\")", in: code).contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        #expect(Self.block(startingWith: "TextField(", in: code).contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        // A stretched button's capsule spans the column, its title in the middle, as the canvas draws it.
        let stretchedButton = Self.block(startingWith: "Button {", in: code)
        #expect(stretchedButton.contains(".frame(maxWidth: .infinity)"))
        #expect(!stretchedButton.contains { $0.hasPrefix(".frame(maxWidth: .infinity, alignment:") })
    }

    /// SwiftUI's stacks grow to the room they're offered when a child can, and the engine's hug what
    /// they hold (review, Important 1). A stretching row that fits its height stays its tallest
    /// child's height, and a stretching column that fits its width its widest child's, unless its own
    /// stack stretches it; a stretched button in the row keeps its title in the middle (Important 2).
    @Test func aStretchingStackThatFitsKeepsItsSize() {
        // A row of words and a button, filling the column's width, fitting its height.
        let row = Self.container(.group, Self.stack(.horizontal, spacing: 8, alignment: .fill),
                                 [Self.text("One"), Self.text("Two"), Self.leaf(.button, "Go")])
        // A stretching column that fits its width, beside words in a row.
        let column = Self.container(.group, Self.stack(.vertical, spacing: 4, alignment: .fill),
                                    [Self.text("Short"), Self.text("A longer line")], width: .fit)
        let holder = Self.container(.group, Self.stack(.horizontal, spacing: 12), [column, Self.text("Beside")])
        // The same rows, but held by their own sizes or stretched by their parent.
        var tall = Self.container(.group, Self.stack(.horizontal, spacing: 24, alignment: .fill), [Self.text("Tall")], height: .fixed)
        tall.frame.size.height = 80
        let code = Self.code(Self.design(Self.stack(.vertical, spacing: 16), [row, holder, tall]))

        let rowModifiers = Self.modifiers(startingWith: "HStack(alignment: .top, spacing: DesignTokens.rhythm[0])", in: code)
        #expect(rowModifiers.first == ".fixedSize(horizontal: false, vertical: true)")
        #expect(rowModifiers.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        let goButton = Self.block(startingWith: "Button {", in: code)
        #expect(goButton.contains(".frame(height: 50)"))
        #expect(goButton.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"))
        #expect(!goButton.contains { $0.contains("alignment: .top") })

        let columnModifiers = Self.modifiers(startingWith: "VStack(alignment: .leading, spacing: 4)", in: code)
        #expect(columnModifiers.first == ".fixedSize(horizontal: true, vertical: false)")
        // The row that holds the column fits, and nothing in it grows: nothing holds it.
        #expect(!Self.modifiers(startingWith: "HStack(alignment: .top, spacing: DesignTokens.rhythm[1])", in: code)
            .contains { $0.hasPrefix(".fixedSize(") })
        // A row of fixed height is held by its frame.
        let tallModifiers = Self.modifiers(startingWith: "HStack(alignment: .top, spacing: DesignTokens.rhythm[3])", in: code)
        #expect(tallModifiers.contains(".frame(height: 80, alignment: .top)"))
        #expect(!tallModifiers.contains { $0.hasPrefix(".fixedSize(") })

        // Under a stretching column, the column is stretched across, so only the row's height is held.
        let stretched = Self.code(Self.design(Self.stack(.vertical, spacing: 16, alignment: .fill), [row, column]))
        #expect(Self.modifiers(startingWith: "HStack(alignment: .top, spacing: DesignTokens.rhythm[0])", in: stretched).first
            == ".fixedSize(horizontal: false, vertical: true)")
        let stretchedColumn = Self.modifiers(startingWith: "VStack(alignment: .leading, spacing: 4)", in: stretched)
        #expect(!stretchedColumn.contains { $0.hasPrefix(".fixedSize(") })
        #expect(stretchedColumn.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
    }

    @Test func justifyBecomesSpacers() {
        func row(_ justify: LayerNode.Justify, filling: Bool = false) -> [String] {
            var children = ["One", "Two", "Three"].map { Self.leaf(.button, $0, frame: CGRect(x: 0, y: 0, width: 60, height: 44)) }
            if filling { children[1].width = LayerNode.Sizing(.fill(weight: 1)) }
            let row = Self.container(.group, Self.stack(.horizontal, spacing: 8, alignment: .center, justify: justify), children)
            let code = Self.code(Self.design(Self.stack(.vertical, spacing: 16), [row]))
            return Self.inside(startingWith: "HStack(", in: code)
        }
        #expect(row(.spaceBetween).filter { $0 == "Spacer()" }.count == 2)
        let centred = row(.center)
        #expect(centred.first == "Spacer()" && centred.last == "Spacer()")
        #expect(!row(.spaceBetween, filling: true).contains("Spacer()"))
        #expect(!row(.center, filling: true).contains("Spacer()"))
        #expect(!row(.start).contains("Spacer()"))
    }

    @Test func sizingBecomesFrames() {
        let filling = Self.leaf(.body, "Fills the column")
        let fixed = Self.leaf(.button, "Fixed", frame: CGRect(x: 0, y: 0, width: 120, height: 44))
        var fitting = Self.text("Fits its words")
        fitting.width = LayerNode.Sizing(.fit)
        let code = Self.code(Self.design(Self.stack(.vertical, spacing: 16), [filling, fixed, fitting]))
        #expect(Self.block(startingWith: "Text(\"Fills the column\")", in: code).contains(".frame(maxWidth: .infinity)"))
        #expect(Self.block(startingWith: "Button {", in: code).contains(".frame(width: 120, height: 44)"))
        let fits = Self.block(startingWith: "Text(\"Fits its words\")", in: code)
        #expect(!fits.isEmpty)
        #expect(!fits.contains { $0.hasPrefix(".frame(") })
    }

    @Test func aGridIsAGridOfRows() {
        let layout = LayerNode.Layout.grid(LayerNode.Grid(columns: 2, columnSpacing: 12, rowSpacing: 8))
        let grid = Self.container(.group, layout, ["A", "B", "C", "D"].map { Self.text($0) })
        let lines = Self.lines(Self.code(Self.design(Self.stack(.vertical, spacing: 16), [grid])))
        #expect(lines.contains("Grid(horizontalSpacing: DesignTokens.rhythm[1], verticalSpacing: DesignTokens.rhythm[0]) {"))
        #expect(lines.filter { $0 == "GridRow {" }.count == 2)
    }

    @Test func anOverlayIsAZStackWithItsAlignment() {
        let overlay = Self.container(.group, .overlay(LayerNode.Alignment(horizontal: .end, vertical: .end)),
                                     [Self.leaf(.image), Self.text("Caption")])
        let lines = Self.lines(Self.code(Self.design(Self.stack(.vertical, spacing: 16), [overlay])))
        #expect(lines.contains("ZStack(alignment: .bottomTrailing) {"))
    }

    @Test func aCardIsAPaddedStackWithItsBackground() throws {
        var card = Self.container(.card, Self.stack(.vertical, spacing: 8), [Self.text("About"), Self.leaf(.body, "Words")])
        card.padding = LayerNode.Padding(all: 16)
        let standard = Self.lines(Self.code(Self.design(Self.stack(.vertical, spacing: 24), [card])))
        #expect(standard.contains(".padding(DesignTokens.cardPadding)"))
        #expect(standard.contains(".background(.background.secondary, in: .rect(cornerRadius: DesignTokens.cardRadius))"))

        var tokens = DesignTokens.standard
        tokens.card.fill = RGBColor(hex: 0x112233)
        let content = Self.design(Self.stack(.vertical, spacing: 24), [card], tokens: tokens)
        #expect(Self.lines(Self.code(content)).contains(".background(DesignTokens.cardFill, in: .rect(cornerRadius: DesignTokens.cardRadius))"))
        let file = Generator.tokensFile(in: Generator.Context(content))
        #expect(file.name == "DesignTokens.swift")
        #expect(Self.lines(file.source).contains("static let cardFill = Color(red: 0.07, green: 0.13, blue: 0.20)"))
    }

    // MARK: - Free containers: today's reading-order inference

    @Test func theSketchedScreensCodeIsTodays() throws {
        let sketch = try Self.fixture("design-sketch")
        let code = Self.code(sketch)
        #expect(code == (try Self.golden("sketch-structure.swift")))
        #expect(!code.contains("DesignTokens"))
        #expect(!Self.lines(code).contains("ZStack(alignment: .topLeading) {"))

        let exact = Self.lines(Self.code(sketch, settings: CodeSettings(layout: .absolute)))
        // Today's exact positions write a title's frame with its alignment: `.frame(width: 228, height: 40, alignment: .center)`.
        #expect(exact.contains { $0.hasPrefix(".frame(width: 228, height: 40") })
        #expect(exact.contains(".offset(x: 20, y: 80)"))
    }

    @Test func aFreeGroupInAFreeScreenDoesNotChangeTheCode() throws {
        let a = Self.leaf(.title, "Top", frame: CGRect(x: 20, y: 80, width: 228, height: 40))
        let b = Self.text("B", frame: CGRect(x: 10, y: 10, width: 120, height: 24))
        let c = Self.leaf(.button, "C", frame: CGRect(x: 150, y: 40, width: 120, height: 44))
        let d = Self.leaf(.button, "D", frame: CGRect(x: 20, y: 700, width: 353, height: 50))
        let group = Self.free(at: CGRect(x: 40, y: 200, width: 300, height: 100), [b, c])
        let grouped = Self.design([(.free, [a, group, d])])

        var hostB = b, hostC = c
        hostB.frame.origin = CGPoint(x: 50, y: 210)
        hostC.frame.origin = CGPoint(x: 190, y: 240)
        let flat = Self.design([(.free, [a, hostB, hostC, d])])
        for layout in CodeSettings.Layout.allCases {
            let settings = CodeSettings(layout: layout)
            #expect(Self.code(grouped, settings: settings) == Self.code(flat, settings: settings), "\(layout)")
        }

        var turnedGroup = group
        turnedGroup.rotation = 30
        turnedGroup.children[0].rotation = 10
        let turned = Self.code(Self.design([(.free, [a, turnedGroup, d])]))
        #expect(Self.block(startingWith: "Text(\"B\")", in: turned).contains(".rotationEffect(.degrees(40))"))
    }

    @Test func aLaidOutContainerInAFreeScreenIsOneItem() throws {
        let title = Self.leaf(.title, "Settings", frame: CGRect(x: 20, y: 80, width: 353, height: 40))
        var row = Self.container(.group, Self.stack(.horizontal, spacing: 12, alignment: .center), [Self.text("Name"), Self.text("Alex")])
        row.frame = CGRect(x: 20, y: 200, width: 353, height: 24)
        (row.width, row.height) = (LayerNode.Sizing(.fixed), LayerNode.Sizing(.fixed))
        let code = Self.code(Self.design([(.free, [title, row])]))
        let lines = Self.lines(code)
        let body = try #require(lines.firstIndex(of: "var body: some View {"))
        #expect(lines[body + 1] == "VStack(alignment: .leading, spacing: 16) {")
        let titleLine = try #require(lines.firstIndex(of: "Text(\"Settings\")"))
        let rowLine = try #require(lines.firstIndex(of: "HStack(alignment: .center, spacing: DesignTokens.rhythm[1]) {"))
        #expect(titleLine < rowLine)

        // The view, then the tokens it uses, then the preview.
        let raw = code.components(separatedBy: "\n")
        let viewEnd = try #require(raw.firstIndex(of: "}"))
        let tokens = try #require(raw.firstIndex(of: "enum DesignTokens {"))
        let tokensEnd = try #require(raw[tokens...].firstIndex(of: "}"))
        #expect(viewEnd < tokens)
        #expect(Array(raw[(tokensEnd + 1)...]) == ["", "#Preview {", "    Screen1()", "}"])
    }

    @Test func aFreeCardIsInferredInsideItsPadding() throws {
        var card = Self.free(.card, at: CGRect(x: 20, y: 100, width: 353, height: 120), [
            Self.text("Left", frame: CGRect(x: 16, y: 16, width: 150, height: 24)),
            Self.text("Right", frame: CGRect(x: 187, y: 16, width: 150, height: 24)),
        ])
        card.padding = LayerNode.Padding(all: 16)
        let lines = Self.lines(Self.code(Self.design([(.free, [card])])))
        let row = try #require(lines.firstIndex(of: "HStack(alignment: .center, spacing: 21) {"))
        let padding = try #require(lines.firstIndex(of: ".padding(DesignTokens.cardPadding)"))
        let frame = try #require(lines.firstIndex(of: ".frame(width: 353, height: 120, alignment: .topLeading)"))
        let background = try #require(lines.firstIndex(of: ".background(.background.secondary, in: .rect(cornerRadius: DesignTokens.cardRadius))"))
        #expect(row < padding && padding < frame && frame < background)
    }

    @Test func aFreeGroupInAColumnIsInferredInsideItsBox() throws {
        let group = Self.free(at: CGRect(x: 0, y: 0, width: 353, height: 100), [
            Self.text("Left", frame: CGRect(x: 0, y: 0, width: 150, height: 24)),
            Self.text("Right", frame: CGRect(x: 200, y: 0, width: 150, height: 24)),
        ])
        let code = Self.code(Self.design(Self.stack(.vertical, spacing: 16), [group]))
        // The root's stack holds one block: the group, read in reading order.
        let inner = Self.inside(startingWith: "VStack(alignment: .leading, spacing: DesignTokens.rhythm[2])", in: code)
        #expect(inner.first == "VStack(alignment: .leading, spacing: 16) {")
        #expect(inner.contains { $0.hasPrefix("HStack(alignment: .center, spacing:") })
        #expect(inner.last == ".frame(width: 353, height: 100, alignment: .topLeading)")
    }

    // MARK: - Exact positions and column screens

    @Test func exactPositionsFlattenTheProfile() throws {
        let profile = try Self.fixture("design-profile")
        let lines = Self.lines(Self.code(profile, settings: CodeSettings(layout: .absolute)))
        #expect(!lines.contains { $0.hasPrefix("HStack(") || $0.hasPrefix("VStack(") || $0.hasPrefix("Grid(") })
        let index = TreeIndex(profile)
        var leaves: [LayerNode] = []
        func visit(_ node: LayerNode) {
            guard !node.isHidden else { return }
            if node.isContainer { node.children.forEach(visit) } else { leaves.append(node) }
        }
        visit(profile.screens[0].root)
        #expect(leaves.count == 10)
        for leaf in leaves {
            let rect = try #require(index[leaf.id]).hostShape.rect
            #expect(lines.contains(".offset(x: \(Self.number(rect.minX)), y: \(Self.number(rect.minY)))"), "\(leaf.kind) at \(rect)")
        }
    }

    @Test func aColumnScreenRespectsTheSafeArea() throws {
        let profile = try Self.fixture("design-profile")
        let code = Self.code(profile)
        let root = Self.block(startingWith: "VStack(", in: code)
        let close = try #require(root.lastIndex(of: "}"))
        #expect(root.indices.contains(close + 1) && root[close + 1] == ".padding(DesignTokens.margin)")
        #expect(!Self.lines(code).contains(".ignoresSafeArea()"))
        #expect(!Self.lines(code).contains(".frame(maxWidth: DesignTokens.maxContentWidth)"))

        var desktop = profile
        desktop.screens[0].deviceID = "macbook-air"
        TreeRules.apply(to: &desktop, after: nil)
        #expect(Self.lines(Self.code(desktop)).contains(".frame(maxWidth: DesignTokens.maxContentWidth)"))
        #expect(Self.lines(Generator.tokensFile(in: Generator.Context(desktop)).source).contains("static let maxContentWidth: CGFloat = 1080"))
    }

    // MARK: - The tokens

    @Test func theTokensFileHoldsTheDesignsTokens() throws {
        var tokens = DesignTokens.standard
        tokens.rhythm = [4, 8]
        tokens.card.padding = 20
        let content = Self.design(Self.stack(.vertical, spacing: 8), [Self.text("One")], tokens: tokens)
        let lines = Self.lines(Generator.tokensFile(in: Generator.Context(content)).source)
        #expect(lines.contains("static let rhythm: [CGFloat] = [4, 8]"))
        #expect(lines.contains("static let cardPadding: CGFloat = 20"))
        #expect(Self.lines(Self.code(content)).contains("VStack(alignment: .leading, spacing: DesignTokens.rhythm[1]) {"))
    }

    @Test func marginsAreNamedForTheirDevicesWhenTheyDiffer() {
        let column = Self.stack(.vertical, spacing: 16)
        let mixed = Self.design([(column, [Self.text("Phone")]), (column, [Self.text("Tablet")])], devices: ["iphone", "ipad"])
        let tokens = Self.lines(Generator.tokensFile(in: Generator.Context(mixed)).source)
        #expect(tokens.contains("static let marginIPhone: CGFloat = 20"))
        #expect(tokens.contains("static let marginIPad: CGFloat = 32"))
        #expect(!tokens.contains("static let margin: CGFloat = 20"))
        #expect(Self.lines(Self.code(mixed, screen: 1)).contains(".padding(DesignTokens.marginIPad)"))
        #expect(Self.lines(Self.code(mixed, screen: 0)).contains(".padding(DesignTokens.marginIPhone)"))

        let phones = Self.design([(column, [Self.text("One")]), (column, [Self.text("Two")])], devices: ["iphone", "iphone"])
        let same = Self.lines(Generator.tokensFile(in: Generator.Context(phones)).source)
        #expect(same.contains("static let margin: CGFloat = 20"))
        #expect(!same.contains { $0.hasPrefix("static let marginIPhone") })
    }

    @Test func aCustomFramesPreviewHasItsSize() {
        let frame = DeviceFrame.custom(name: "Badge", size: CGSize(width: 198, height: 242), family: .watch)
        let content = Self.design([(.free, [Self.text("Hi", frame: CGRect(x: 8, y: 8, width: 100, height: 24))]),
                                   (.free, [Self.text("Hi", frame: CGRect(x: 20, y: 80, width: 100, height: 24))])],
                                  devices: [frame.id, "iphone"], customDevices: [frame])
        #expect(Self.lines(Self.code(content, screen: 0)).contains("#Preview(traits: .fixedLayout(width: 198, height: 242)) {"))
        let phone = Self.lines(Self.code(content, screen: 1))
        #expect(phone.contains("#Preview {"))
        #expect(!phone.contains { $0.hasPrefix("#Preview(traits:") })
    }

    @Test func hiddenNodesDrawingsAndTheCanvasAreLeftOut() {
        var secret = Self.text("Secret")
        secret.isHidden = true
        var hiddenRow = Self.container(.group, Self.stack(.horizontal, spacing: 8), [Self.text("Hidden row")])
        hiddenRow.isHidden = true
        var hiddenFree = Self.text("Hidden sketch", frame: CGRect(x: 20, y: 300, width: 200, height: 24))
        hiddenFree.isHidden = true
        func ink() -> LayerNode {
            var ink = LayerNode(kind: .drawing)
            ink.frame = CGRect(x: 20, y: 400, width: 100, height: 100)
            ink.name = "Ink"
            return ink
        }
        // Not laid out by the rules, which would move the drawings to the canvas.
        var content = Self.design([
            (Self.stack(.vertical, spacing: 16), [Self.text("Shown"), secret, hiddenRow, ink()]),
            (.free, [Self.text("Sketched", frame: CGRect(x: 20, y: 80, width: 200, height: 24)), hiddenFree, ink()]),
        ], appliesRules: false)
        var note = Self.leaf(.stickyNote, "Canvas note", frame: CGRect(x: 900, y: 0, width: 150, height: 150))
        note.scale = 1
        content.canvas = [note, Self.text("On the canvas", frame: CGRect(x: 900, y: 300, width: 200, height: 24))]

        for layout in CodeSettings.Layout.allCases {
            let files = Generator.files(for: content, settings: CodeSettings(layout: layout))
            let all = files.map(\.source).joined(separator: "\n")
            #expect(all.contains("Text(\"Shown\")") && all.contains("Text(\"Sketched\")"), "\(layout)")
            for word in ["Secret", "Hidden row", "Hidden sketch", "Canvas note", "On the canvas", "// Ink"] {
                #expect(!all.contains(word), "\(word) in \(layout)")
            }
            #expect(files.map(\.name).filter { $0 != "DesignTokens.swift" } == ["Screen1.swift", "Screen2.swift"])
        }
    }

    // MARK: - One screen's code, the files and their names

    @Test func oneScreensCodeCarriesItsTokensWhenItUsesThem() throws {
        let profile = try Self.fixture("design-profile")
        let code = Self.code(profile)
        let raw = code.components(separatedBy: "\n")
        #expect(raw.filter { $0 == "enum DesignTokens {" }.count == 1)
        let viewEnd = try #require(raw.firstIndex(of: "}"))
        let tokens = try #require(raw.firstIndex(of: "enum DesignTokens {"))
        #expect(viewEnd < tokens)

        let sketch = try Self.fixture("design-sketch")
        let sketchCode = Self.code(sketch)
        #expect(!sketchCode.contains("DesignTokens"))
        #expect(sketchCode.hasSuffix("\n\n#Preview {\n    Sketch()\n}"))

        let files = Generator.files(for: profile, settings: CodeSettings())
        #expect(files.map(\.name) == ["DesignTokens.swift", "Profile.swift"])
        #expect(files.dropFirst().allSatisfy { !$0.source.contains("enum DesignTokens") })
        #expect(files.first?.source.contains("enum DesignTokens {") == true)
        #expect(Generator.files(for: sketch, settings: CodeSettings()).map(\.name) == ["Sketch.swift"])
    }

    @Test func viewNamesStayUnique() {
        let screens = ["Sign In", "Sign-In", "Sign in", "Design Tokens", "Grid Row"].map {
            TreeScreen(name: $0, origin: .zero, scale: 1, deviceID: nil)
        }
        let names = Generator.typeNames(for: screens)
        #expect(screens.map { names[$0.id] } == ["SignIn", "SignIn2", "Signin3", "DesignTokensScreen", "GridRowScreen"])
        var content = TreeContent()
        content.screens = screens
        let context = Generator.Context(content)
        #expect(Generator.fileName(for: screens[1], in: context) == "SignIn2.swift")
        #expect(Generator.fileName(for: screens[3], in: context) == "DesignTokensScreen.swift")
    }

    @Test func theNavigationTitleComesFromTheFirstTitle() throws {
        let profile = try Self.fixture("design-profile")
        let lines = Self.lines(Self.code(profile, settings: CodeSettings(usesNavigationTitle: true)))
        #expect(lines.contains("NavigationStack {"))
        #expect(lines.contains(".navigationTitle(\"Profile\")"))
        #expect(!lines.contains("Text(\"Profile\")"))
    }

    @Test func structureIsTheDefaultAndStackStillReads() throws {
        #expect(CodeSettings().layout == .structure)
        let stack = try JSONDecoder().decode(CodeSettings.self, from: Data(#"{"layout":"stack"}"#.utf8))
        #expect(stack.layout == .structure)
        let structure = try JSONDecoder().decode(CodeSettings.self, from: Data(#"{"layout":"structure"}"#.utf8))
        #expect(structure.layout == .structure)
        let written = String(decoding: try JSONEncoder().encode(CodeSettings()), as: UTF8.self)
        #expect(written.contains(#""layout":"structure""#))
        #expect(CodeSettings.Layout.structure.name == "Structure")
        #expect(CodeLayoutOption.stack.layout == .structure)
        #expect(CodeLayoutOption.absolute.layout == .absolute)
    }

    @MainActor @Test func shareThePanelAndSiriWriteTheSameCode() throws {
        let profile = try Self.fixture("design-profile")
        let screen = profile.screens[0]
        let context = Generator.Context(profile)
        let settings = profile.settings.code
        let shared = SharedSwiftUICode(screen: screen, context: context, settings: settings).source
        let panel = CodePreview.Shown(screen: screen, context: context, settings: settings).source
        let siri = try #require(GenerateSwiftUICodeIntent.code(for: screen.id, in: profile))
        #expect(shared == panel)
        #expect(shared == siri)
        #expect(shared == Self.code(profile, settings: settings))
        #expect(GenerateSwiftUICodeIntent.code(for: UUID(), in: profile) == nil)
    }

    // MARK: - The structures fixture

    /// Every screen's code in one text, each after a line naming its screen.
    private static func everyScreensCode(_ content: TreeContent, settings: CodeSettings) -> String {
        content.screens.indices
            .map { "// ----- \(content.screens[$0].name)\n" + code(content, screen: $0, settings: settings) }
            .joined(separator: "\n")
    }

    @Test func theStructuresFixtureReadsAndHoldsEachStructure() throws {
        let content = try Self.fixture("design-structures")
        #expect(content.screens.count == 3)

        let first = content.screens[0].root
        #expect(first.resolvedLayout != .free)
        let layouts = first.children.map(\.resolvedLayout)
        func isRow(_ node: LayerNode) -> Bool {
            if case .stack(let stack) = node.resolvedLayout { return stack.axis == .horizontal }
            return false
        }
        #expect(first.children.contains { isRow($0) && $0.children.count == 3 && $0.children.contains { $0.width.mode != .fit } })
        #expect(layouts.contains { if case .grid(let grid) = $0 { return grid.columns == 3 } else { return false } })
        #expect(first.children.contains { $0.resolvedLayout == .overlay(LayerNode.Alignment()) && $0.children.count == 2 })
        let freeGroup = try #require(first.children.first { $0.kind == .group && $0.resolvedLayout == .free })
        #expect(freeGroup.children.contains { $0.isHidden })
        #expect(freeGroup.children.contains { $0.rotation == 30 })
        let outer = try #require(first.children.first { $0.kind == .card })
        #expect(outer.children.contains { $0.kind == .card })
        let fillColumn = try #require(first.children.first {
            if case .stack(let stack) = $0.resolvedLayout { return stack.axis == .vertical && stack.alignment == .fill }
            return false
        })
        #expect(fillColumn.children.map(\.kind) == [.textField, .toggle])
        #expect(first.children.contains { isRow($0) && $0.children.isEmpty })
        #expect(first.children.contains { $0.name == "Say \"hi\" \u{1F44B}" })
        #expect(Set(first.children.filter { $0.kind == .button }.compactMap(\.content.buttonLook)) == [.filled, .bordered, .plain])

        #expect(content.device(of: content.screens[1]).isCustom)
        #expect(content.device(of: content.screens[1]).size == CGSize(width: 198, height: 242))
        #expect(content.screens[1].root.resolvedLayout != .free)

        let sketched = content.screens[2].root
        #expect(sketched.resolvedLayout == .free)
        #expect(sketched.children.contains { $0.kind == .group && $0.resolvedLayout == .free && $0.children.count == 2 })
        #expect(sketched.children.contains { isRow($0) })
        #expect(sketched.children.contains { $0.kind == .card && $0.resolvedLayout == .free })
        #expect(content.settings.tokens.rhythm == [4, 8, 12, 20, 28])
        #expect(content.settings.tokens.card.padding == 12)
        #expect(content.settings.tokens.card.fill == RGBColor(hex: 0xE5F0FF))
    }

    @Test func aFreeScreenWithStructureInsideReadsInReadingOrder() throws {
        let content = try Self.fixture("design-structures")
        let code = Self.code(content, screen: 2)
        let lines = Self.lines(code)
        #expect(lines.contains { $0.hasPrefix("VStack(alignment: .leading, spacing:") })
        #expect(!code.contains("ZStack(alignment: .topLeading)"))
        // The two buttons are one row.
        let buttons = Self.block(startingWith: "HStack(", in: code)
        #expect(!buttons.isEmpty)
        // The laid-out row of a text and a toggle keeps its own stack, with the design's rhythm.
        #expect(lines.contains { $0.hasPrefix("HStack(alignment: .center, spacing: DesignTokens.rhythm[") })
        // The free group's texts are items of the root's inference: no block of their own.
        #expect(code.contains("Text(\"Status\")") && code.contains("Text(\"Tilted\")"))
        #expect(code.contains(".rotationEffect(.degrees(15))"))
    }

    // MARK: - Goldens

    @Test func theGoldensAreWhatIsWritten() throws {
        let profile = try Self.fixture("design-profile")
        let structures = try Self.fixture("design-structures")
        let written = [
            "structures-structure.swift": Self.everyScreensCode(structures, settings: CodeSettings()),
            "structures-exact.swift": Self.everyScreensCode(structures, settings: CodeSettings(layout: .absolute)),
            "profile-structure.swift": Self.code(profile),
            "profile-exact.swift": Self.code(profile, settings: CodeSettings(layout: .absolute)),
            "DesignTokens-standard.swift": Generator.tokensFile(in: Generator.Context(profile)).source,
        ]
        if let folder = ProcessInfo.processInfo.environment["LAYER_RECORD_CODE"] {
            for (name, source) in written {
                try source.write(toFile: (folder as NSString).appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
            }
            return
        }
        for (name, source) in written {
            #expect(source == (try Self.golden(name)), "\(name)")
        }
    }
}
