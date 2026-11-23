import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// Writes the code the generator makes for a spread of designs into the folder named by
/// `LAYER_CODE_OUT`, so `scripts/check-generated-swiftui.sh` can typecheck it with swiftc.
/// xcodebuild forwards the variable as `TEST_RUNNER_LAYER_CODE_OUT`. Without it, nothing runs.
@Suite
struct GeneratedCodeExportTests {
    private static let outputFolder = ProcessInfo.processInfo.environment["LAYER_CODE_OUT"]

    private static func element(_ kind: ElementKind, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, text: String? = nil) -> DesignElement {
        DesignElement(kind: kind, frame: CGRect(x: x, y: y, width: width, height: height), text: text ?? kind.placeholder, tint: Theme.accent)
    }

    /// One screen per device family, every leaf kind, a row of three, turned elements, a
    /// hidden one, names with quotes and emoji, and two screens whose names clash.
    private static func screens() -> [DesignScreen] {
        let leafKinds = ElementKind.allCases.filter { $0 != .group && $0 != .card }
        var everyKind: [DesignElement] = []
        for (index, kind) in leafKinds.enumerated() {
            var item = element(kind, 20, 80 + CGFloat(index) * 44, 300, 40)
            if kind == .symbol { item.symbol = "star.fill" }
            if kind == .shape { item.shape = .star }
            everyKind.append(item)
        }

        let row = [
            element(.button, 20, 700, 100, 44, text: "One"),
            element(.button, 140, 700, 100, 44, text: "Two"),
            element(.button, 260, 700, 100, 44, text: "Three"),
        ]

        var turned = element(.body, 40, 620, 200, 40)
        turned.rotation = 30
        var turnedImage = element(.image, 200, 560, 120, 120)
        turnedImage.rotation = 270
        var hidden = element(.body, 20, 520, 200, 40, text: "Not in the code")
        hidden.isHidden = true

        var quoted = element(.title, 20, 70, 300, 40, text: #"Say "hi" \ 👋"#)
        quoted.name = #"The "big" one 🎉"#
        var emoji = element(.body, 20, 130, 300, 40, text: "Line one\nLine two 🧪")
        emoji.name = "Cards 🃏\nsecond line"

        return [
            DesignScreen(name: "Phone", origin: .zero, scale: 1, deviceID: "iphone", elements: everyKind + [hidden, turned, turnedImage]),
            DesignScreen(name: "Tablet", origin: .zero, scale: 1, deviceID: "ipad", elements: [quoted, emoji] + row),
            DesignScreen(name: "Desktop", origin: .zero, scale: 1, deviceID: "macbook-air", elements: row + [turned]),
            DesignScreen(name: "Sign In", origin: .zero, scale: 1, elements: [quoted]),
            DesignScreen(name: "Sign-In", origin: .zero, scale: 1, elements: [emoji]),
            DesignScreen(name: "Say \"hi\" 👋", origin: .zero, scale: 1, elements: [emoji]),
            DesignScreen(name: "Empty", origin: .zero, scale: 1, elements: []),
        ]
    }

    @Test(.enabled(if: outputFolder != nil))
    func writesGeneratedCodeForTheCheck() throws {
        let root = URL(fileURLWithPath: try #require(Self.outputFolder), isDirectory: true)
        let screens = Self.screens()
        var written = 0
        for layout in CodeSettings.Layout.allCases {
            for usesNavigationTitle in [false, true] {
                let settings = CodeSettings(layout: layout, includesPreview: true, usesNavigationTitle: usesNavigationTitle)
                let folder = root.appendingPathComponent("\(layout.rawValue)-\(usesNavigationTitle ? "title" : "plain")", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for file in SwiftUICodeGenerator.files(for: screens, settings: settings) {
                    try file.source.write(to: folder.appendingPathComponent(file.name), atomically: true, encoding: .utf8)
                    written += 1
                }
            }
        }
        #expect(written == screens.count * 4)
    }
}
