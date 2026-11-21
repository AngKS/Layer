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

    @Test func theCodeDrawsTheSameIconAsTheCanvas() {
        var screen = DesignScreen(name: "Footer", origin: .zero, scale: 1)
        var mail = DesignStore.newElement(.symbol, symbol: "Email")
        mail.frame = CGRect(x: 40, y: 700, width: 28, height: 28)
        var github = DesignStore.newElement(.symbol, symbol: "GitHub")
        github.frame = CGRect(x: 100, y: 700, width: 28, height: 28)
        var heart = DesignStore.newElement(.symbol, symbol: "heart.fill")
        heart.frame = CGRect(x: 160, y: 700, width: 28, height: 28)
        screen.elements = [mail, github, heart]

        for layout in CodeSettings.Layout.allCases {
            let code = SwiftUICodeGenerator.code(for: screen, settings: CodeSettings(layout: layout))
            #expect(code.contains(#"Image(systemName: "envelope")"#), "\(layout)")
            #expect(code.contains(#"Image(systemName: "link")"#), "\(layout)")
            #expect(code.contains(#"Image(systemName: "heart.fill")"#), "\(layout)")
            #expect(!code.contains(#"systemName: "Email""#) && !code.contains(#"systemName: "GitHub""#), "\(layout)")
        }
        // The elements keep the names they were given, for a later model or system to know.
        #expect(screen.elements.map(\.symbol) == ["Email", "GitHub", "heart.fill"])
    }
}
