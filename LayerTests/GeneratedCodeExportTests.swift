import CoreGraphics
import Foundation
import Testing
@testable import Layer

private final class CodeOutBundleMarker {}

/// Writes the code the generator makes for a spread of the tree's designs into the folder named by
/// `LAYER_CODE_OUT`, so `scripts/check-generated-swiftui.sh` can typecheck it with swiftc.
/// xcodebuild forwards the variable as `TEST_RUNNER_LAYER_CODE_OUT`. Without it, nothing runs.
///
/// Each design is written, for both layouts, with the navigation title on and off and the preview
/// on and off, twice: all its files into one folder, as a target holds them, and each screen's
/// own code, which carries the design's tokens, alone into a folder of its own.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LAYER_CODE_OUT"] != nil))
struct GeneratedCodeExportTests {
    private static let outputFolder = ProcessInfo.processInfo.environment["LAYER_CODE_OUT"]
    private typealias Generator = SwiftUICodeGenerator
    private typealias Tests = SwiftUIExportTests

    // MARK: - The designs

    /// Every design file under `Fixtures/Designs`, read as the app reads it.
    private static func fixtures() throws -> [(name: String, content: TreeContent)] {
        let bundle = Bundle(for: CodeOutBundleMarker.self)
        let urls = (bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("design-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try urls.map { url in
            var content = try TreeManifest.decode(try Data(contentsOf: url)).content
            TreeRules.apply(to: &content, after: nil)
            return (url.deletingPathExtension().lastPathComponent, content)
        }
    }

    /// Every leaf kind: with a symbol and a shape where the kind has them.
    private static func everyLeaf(frames: Bool) -> [LayerNode] {
        let kinds = ElementKind.allCases.filter { $0 != .group && $0 != .card }
        return kinds.enumerated().map { index, kind in
            var node = Tests.leaf(kind, frame: frames ? CGRect(x: 20, y: 80 + CGFloat(index) * 44, width: 300, height: 40) : nil)
            if kind == .symbol { node.content.symbol = "star.fill" }
            if kind == .shape { node.content.shape = .star }
            return node
        }
    }

    private static let column = Tests.stack(.vertical, spacing: 16)
    private static let fillColumn = Tests.stack(.vertical, spacing: 16, alignment: .fill)

    /// A screen at a place of its own, on a device, with a root of the layout given.
    private static func screens(_ specs: [(name: String, device: String?, layout: LayerNode.Layout, children: [LayerNode])],
                                tokens: DesignTokens = .standard) -> TreeContent {
        Tests.design(specs.map { ($0.layout, $0.children) }, devices: specs.map(\.device), names: specs.map(\.name), tokens: tokens)
    }

    /// The reference demo's screen, placed freely: it uses no token, so its folders hold no `DesignTokens.swift`.
    private static func demo() -> TreeContent {
        let frames: [(ElementKind, CGRect)] = [
            (.button, CGRect(x: 20, y: 744, width: 353, height: 50)), (.title, CGRect(x: 82, y: 112, width: 228, height: 40)),
            (.image, CGRect(x: 30, y: 184, width: 333, height: 368)), (.body, CGRect(x: 48, y: 580, width: 297, height: 44)),
        ]
        return screens([("Screen 1", nil, .free, frames.map { Tests.leaf($0.0, frame: $0.1) })])
    }

    /// Turned, hidden, quoted and emoji'd nodes, free and in a column.
    private static func awkwardNodes(frames: Bool) -> [LayerNode] {
        func at(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect? { frames ? CGRect(x: x, y: y, width: width, height: height) : nil }
        var turned = Tests.leaf(.body, frame: at(40, 620, 200, 40))
        turned.rotation = 30
        var turnedImage = Tests.leaf(.image, frame: at(200, 560, 120, 120))
        turnedImage.rotation = 270
        var hidden = Tests.leaf(.body, "Not in the code", frame: at(20, 520, 200, 40))
        hidden.isHidden = true
        var quoted = Tests.leaf(.title, #"Say "hi" \ 👋"#, frame: at(20, 70, 300, 40))
        quoted.name = #"The "big" one 🎉"#
        var emoji = Tests.leaf(.body, "Line one\nLine two 🧪", frame: at(20, 130, 300, 40))
        emoji.name = "Cards 🃏\nsecond line"
        return [quoted, emoji, hidden, turned, turnedImage]
    }

    /// Rows that stretch, fill, justify and fit; columns that stretch; grids and overlays of each alignment.
    private static func stretching() -> [LayerNode] {
        let stretchedRow = Tests.container(.group, Tests.stack(.horizontal, spacing: 8, alignment: .fill),
                                           [Tests.text("One"), Tests.text("Two"), Tests.leaf(.button, "Go")])
        let stretchedColumn = Tests.container(.group, Tests.stack(.vertical, spacing: 4, alignment: .fill),
                                              [Tests.text("Short"), Tests.text("A longer line")], width: .fit)
        let holder = Tests.container(.group, Tests.stack(.horizontal, spacing: 12), [stretchedColumn, Tests.text("Beside")])
        var tall = Tests.container(.group, Tests.stack(.horizontal, spacing: 24, alignment: .fill), [Tests.text("Tall")], height: .fixed)
        tall.frame.size.height = 80
        let fills = Tests.container(.group, Tests.stack(.horizontal, spacing: 8, alignment: .center),
                                    [Tests.text("Left"), Tests.container(.group, Tests.stack(.vertical, spacing: 4, alignment: .fill),
                                                                         [Tests.leaf(.textField), Tests.leaf(.toggle),
                                                                          Tests.leaf(.button, "Save"), Tests.leaf(.button, "Cancel")])])
        let justified = [LayerNode.Justify.spaceBetween, .center, .end, .spaceAround, .spaceEvenly].map { justify in
            Tests.container(.group, Tests.stack(.horizontal, spacing: 8, alignment: .center, justify: justify),
                            [Tests.text("A"), Tests.text("B"), Tests.leaf(.toggle)])
        }
        let grids = [LayerNode.Edge3.start, .center, .end].map { edge in
            Tests.container(.group, .grid(LayerNode.Grid(columns: 2, columnSpacing: 12, rowSpacing: 8,
                                                         alignment: LayerNode.Alignment(horizontal: edge, vertical: edge))),
                            (1...4).map { Tests.text("Cell \($0)") })
        }
        let overlays = [LayerNode.Edge3.start, .center, .end].map { edge in
            Tests.container(.group, .overlay(LayerNode.Alignment(horizontal: edge, vertical: edge)),
                            [Tests.leaf(.image), Tests.leaf(.title, "Over")], height: .fixed)
        }
        let cards = Tests.container(.card, Tests.stack(.vertical, spacing: 8), [Tests.leaf(.title, "Card"),
                                    Tests.container(.card, Tests.stack(.horizontal, spacing: 8), [Tests.leaf(.avatar), Tests.text("Nested")])])
        return [stretchedRow, holder, tall, fills] + justified + grids + overlays + [cards]
    }

    private static func designs() throws -> [(name: String, content: TreeContent)] {
        var designs = try fixtures()

        designs.append(("every-leaf-in-a-column", screens([("Column", nil, column, everyLeaf(frames: false) + awkwardNodes(frames: false))])))
        designs.append(("every-leaf-on-a-free-root", screens([("Free", nil, .free, everyLeaf(frames: true) + awkwardNodes(frames: true))])))
        designs.append(("demo-on-a-free-root", demo()))
        designs.append(("stretching-in-a-start-column", screens([("Start", nil, column, stretching())])))
        designs.append(("stretching-in-a-fill-column", screens([("Fill", "ipad", fillColumn, stretching())])))

        let families: [(String, String?)] = [("Phone", "iphone"), ("Tablet", "ipad"), ("Desktop", "macbook-air")]
        func familyScreens(layout: LayerNode.Layout, frames: Bool) -> TreeContent {
            screens(families.map { name, device in
                (name, device, layout, [Tests.leaf(.title, "Hello", frame: frames ? CGRect(x: 20, y: 80, width: 228, height: 40) : nil),
                                        Tests.leaf(.button, "Continue", frame: frames ? CGRect(x: 20, y: 140, width: 160, height: 50) : nil)])
            })
        }
        designs.append(("each-device-on-a-free-root", familyScreens(layout: .free, frames: true)))
        designs.append(("each-device-in-a-column", familyScreens(layout: column, frames: false)))

        let quoted = Tests.leaf(.title, #"Say "hi" \ 👋"#)
        let emoji = Tests.leaf(.body, "Line one\nLine two 🧪")
        designs.append(("clashing-names", screens([("Sign In", nil, column, [quoted]), ("Sign-In", nil, column, [emoji]),
                                                    ("Say \"hi\" 👋", nil, .free, awkwardNodes(frames: true)), ("Empty", nil, column, [])])))

        // Screens named for the things their code uses: `DesignTokens`, and `GridRow` beside a grid.
        let grid = Tests.container(.group, .grid(LayerNode.Grid(columns: 2, columnSpacing: 12, rowSpacing: 8)),
                                   (1...4).map { Tests.text("Cell \($0)") })
        designs.append(("names-of-things-the-code-uses", screens([("Design Tokens", nil, column, [Tests.leaf(.title, "Tokens"), Tests.leaf(.button, "Go")]),
                                                                  ("Grid Row", nil, column, [grid])])))

        // A design's own text sizes, which aren't SwiftUI's text styles' sizes: its text is written at them.
        var ownSizes = DesignTokens.standard
        ownSizes.textSizes = DesignTokens.TextSizes(title: 30, body: 20, text: 21)
        let words = [Tests.leaf(.title, "Title"), Tests.leaf(.body, "Body"), Tests.text("Text")]
        let placed = zip(words, [CGRect(x: 20, y: 80, width: 300, height: 44), CGRect(x: 20, y: 140, width: 300, height: 40),
                                 CGRect(x: 20, y: 200, width: 300, height: 24)]).map { word, frame -> LayerNode in
            var node = word
            node.frame = frame
            (node.width, node.height) = (LayerNode.Sizing(.fixed), LayerNode.Sizing(.fixed))
            return node
        }
        designs.append(("own-text-sizes", screens([("Column", nil, column, words), ("Free", nil, .free, placed)], tokens: ownSizes)))
        return designs
    }

    // MARK: - Writing

    private static func write(_ files: [(name: String, source: String)], to folder: URL) throws -> Int {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            try file.source.write(to: folder.appendingPathComponent(file.name), atomically: true, encoding: .utf8)
        }
        return files.count
    }

    @Test
    func writesGeneratedCodeForTheCheck() throws {
        let root = URL(fileURLWithPath: try #require(Self.outputFolder), isDirectory: true)
        let designs = try Self.designs()
        // The designs the script finds are the ones here: the fixtures, and those built in code.
        #expect(designs.count >= 12)
        var written = 0
        var expected = 0
        for (name, content) in designs {
            let context = Generator.Context(content)
            for layout in CodeSettings.Layout.allCases {
                for usesNavigationTitle in [false, true] {
                    for includesPreview in [true, false] {
                        let settings = CodeSettings(layout: layout, includesPreview: includesPreview, usesNavigationTitle: usesNavigationTitle)
                        let variant = "\(layout.rawValue)-\(usesNavigationTitle ? "title" : "plain")-\(includesPreview ? "preview" : "bare")"
                        let together = root.appendingPathComponent("\(name)--together--\(variant)", isDirectory: true)
                        let files = Generator.files(for: content, settings: settings)
                        written += try Self.write(files, to: together)
                        expected += content.screens.count + (files.contains { $0.name == "DesignTokens.swift" } ? 1 : 0)
                        for (index, screen) in content.screens.enumerated() {
                            let source = Generator.code(for: screen, in: context, settings: settings)
                            let alone = root.appendingPathComponent("\(name)--alone-\(index + 1)--\(variant)", isDirectory: true)
                            written += try Self.write([(Generator.fileName(for: screen, in: context), source)], to: alone)
                            expected += 1
                        }
                    }
                }
            }
        }
        #expect(written == expected)
        #expect(written >= 100)

        // A free screen of leaves uses no token, so the demo's folders hold no `DesignTokens.swift`.
        let demo = try #require(designs.first { $0.name == "demo-on-a-free-root" })
        #expect(!Generator.files(for: demo.content, settings: CodeSettings()).contains { $0.name == "DesignTokens.swift" })
    }
}
