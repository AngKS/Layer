import SwiftUI
import Testing
import UIKit
@testable import Layer

/// Icons named by a model, which aren't always SF Symbols: drawn blank, with a complaint in
/// the log, until they fall back to one that is.
@Suite("Icons named loosely")
struct SystemSymbolTests {
    /// The names the iPad's log said there was no symbol for, from generated designs.
    @Test(arguments: ["arrow down", "arrow", "Email", "LinkedIn", "Dribbble", "GitHub"])
    func aNameTheSystemDoesntKnowFallsBackToOneItDoes(name: String) {
        #expect(UIImage(systemName: name) == nil, "already a symbol")
        let symbol = SystemSymbol.resolve(name)
        #expect(UIImage(systemName: symbol) != nil, "\(name) became \(symbol)")
        #expect(symbol != SystemSymbol.placeholder, "\(name) should be something, not the placeholder")
    }

    @Test func aRealSymbolIsLeftAsItIs() {
        for name in ["heart.fill", "envelope", "person.crop.circle", "arrow.down", "map", "questionmark.square.dashed"] {
            #expect(SystemSymbol.resolve(name) == name)
        }
    }

    @Test func aNameSpelledLooselyIsTheSymbolMeant() {
        #expect(SystemSymbol.resolve("arrow down") == "arrow.down")
        #expect(SystemSymbol.resolve("chevron_right") == "chevron.right")
        #expect(SystemSymbol.resolve(" Heart-Fill ") == "heart.fill")
        #expect(SystemSymbol.resolve("arrowDown") == "arrow.down")
        // A word left over at the end is dropped.
        #expect(SystemSymbol.resolve("heart.outline") == "heart")
    }

    @Test func commonWordsAreTheirSymbols() {
        #expect(SystemSymbol.resolve("Email") == "envelope")
        #expect(SystemSymbol.resolve("email_icon") == "envelope")
        #expect(SystemSymbol.resolve("e-mail") == "envelope")
        #expect(SystemSymbol.resolve("arrow") == "arrow.right")
        #expect(SystemSymbol.resolve("search") == "magnifyingglass")
        #expect(SystemSymbol.resolve("Settings") == "gearshape")
        #expect(SystemSymbol.resolve("user") == "person.crop.circle")
        #expect(SystemSymbol.resolve("home") == "house")
        #expect(SystemSymbol.resolve("back") == "chevron.left")
        #expect(SystemSymbol.resolve("menu") == "line.3.horizontal")
        #expect(SystemSymbol.resolve("close") == "xmark")
        #expect(SystemSymbol.resolve("share") == "square.and.arrow.up")
        #expect(SystemSymbol.resolve("address") == "mappin.and.ellipse")
        #expect(SystemSymbol.resolve("website") == "globe")
    }

    /// Names as other icon sets write them, Material's among them: an arrow points the
    /// way the name says, and a first word that is a symbol of its own isn't taken for it.
    @Test func anArrowPointsTheWayItsNameSays() {
        #expect(SystemSymbol.resolve("keyboard_arrow_down") == "arrow.down")
        #expect(SystemSymbol.resolve("arrow_back") == "arrow.left")
        #expect(SystemSymbol.resolve("arrow_back_ios") == "arrow.left")
        #expect(SystemSymbol.resolve("arrow_upward") == "arrow.up")
        #expect(SystemSymbol.resolve("arrow_downward") == "arrow.down")
        #expect(SystemSymbol.resolve("arrow_forward") == "arrow.forward")
        #expect(SystemSymbol.resolve("arrowRight") == "arrow.right")
        // Without an arrow, a way is a chevron.
        #expect(SystemSymbol.resolve("go_back") == "chevron.left")
        #expect(SystemSymbol.resolve("caret_down") == "chevron.down")
        #expect(SystemSymbol.resolve("nav_upward") == "chevron.up")
    }

    @Test func aNameWrittenApartIsOneWord() {
        #expect(SystemSymbol.resolve("magnifying glass") == "magnifyingglass")
        #expect(SystemSymbol.resolve("paper plane") == "paperplane")
        #expect(SystemSymbol.resolve("person.circle.outline") == "person.circle")
    }

    /// A word that is a symbol itself, and nothing better, is drawn as that symbol.
    @Test func aWordThatIsASymbolIsTheLastResort() {
        #expect(SystemSymbol.resolve("camera_outline") == "camera")
        #expect(SystemSymbol.resolve("keyboard_alt") == "keyboard")
    }

    @Test func aBrandWithoutASymbolIsALink() {
        for brand in ["GitHub", "LinkedIn", "Dribbble", "Twitter", "Facebook", "Instagram", "YouTube", "github-logo"] {
            #expect(SystemSymbol.resolve(brand) == "link", "\(brand)")
        }
    }

    @Test func aNameNothingFitsIsThePlaceholder() {
        #expect(SystemSymbol.resolve("zqxv blorp") == SystemSymbol.placeholder)
        #expect(SystemSymbol.resolve("") == SystemSymbol.placeholder)
        #expect(UIImage(systemName: SystemSymbol.placeholder) != nil)
    }

    @Test func everyWordStandsForARealSymbol() {
        let missing = SystemSymbol.words.filter { UIImage(systemName: $0.value) == nil }
        #expect(missing.isEmpty, "not SF Symbols: \(missing)")
    }

    /// The canvas draws an element named as the model named it: something, where the name
    /// as given would draw nothing at all.
    @MainActor
    @Test func theCanvasDrawsAnIconForANameTheSystemDoesntKnow() throws {
        var github = LayerNode.standard(.symbol, symbol: "GitHub")
        github.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        let asGiven = try Self.inkedPixels(Image(systemName: "GitHub").resizable().scaledToFit())
        let drawn = try Self.inkedPixels(ElementView(node: github).environment(ImageLibrary([:])))
        #expect(asGiven == 0, "the name as given draws nothing")
        #expect(drawn > 40, "the element should draw an icon")
    }

    /// How many of a 44-point view's pixels have anything drawn in them.
    @MainActor
    private static func inkedPixels(_ view: some View) throws -> Int {
        let renderer = ImageRenderer(content: view.frame(width: 44, height: 44))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 3, to: pixels.count, by: 4).count { pixels[$0] > 0 }
    }

    @Test func theCodeDrawsTheSameIconAsTheCanvas() {
        var mail = LayerNode.standard(.symbol, symbol: "Email")
        mail.frame = CGRect(x: 40, y: 700, width: 28, height: 28)
        var github = LayerNode.standard(.symbol, symbol: "GitHub")
        github.frame = CGRect(x: 100, y: 700, width: 28, height: 28)
        var heart = LayerNode.standard(.symbol, symbol: "heart.fill")
        heart.frame = CGRect(x: 160, y: 700, width: 28, height: 28)
        let screen = [mail, github, heart]

        for layout in CodeSettings.Layout.allCases {
            let code = SwiftUICodeGenerator.code(forFreeScreenHolding: screen, named: "Footer", settings: CodeSettings(layout: layout))
            #expect(code.contains(#"Image(systemName: "envelope")"#), "\(layout)")
            #expect(code.contains(#"Image(systemName: "link")"#), "\(layout)")
            #expect(code.contains(#"Image(systemName: "heart.fill")"#), "\(layout)")
            #expect(!code.contains(#"systemName: "Email""#) && !code.contains(#"systemName: "GitHub""#), "\(layout)")
        }
        // The elements keep the names they were given, for a later model or system to know.
        #expect(screen.map(\.content.symbol) == ["Email", "GitHub", "heart.fill"])
    }
}
