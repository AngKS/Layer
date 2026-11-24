import CoreGraphics
import Foundation

/// The numbers a design is laid out and styled by, kept with the design: the spacing steps,
/// the corner radii, what a card is, and the sizes of text. `standard` is Layer's own, which
/// the rest of the app reads where it once had the numbers written in.
struct DesignTokens: Equatable, Sendable, Codable {
    struct CornerRadii: Equatable, Sendable, Codable {
        var small: CGFloat = 8
        var medium: CGFloat = 12
        var large: CGFloat = 16
    }

    struct Card: Equatable, Sendable, Codable {
        var padding: CGFloat = 16
        var radius: CGFloat = 16
        var fill = RGBColor(hex: 0xF2F2F7)
    }

    struct TextSizes: Equatable, Sendable, Codable {
        var title: CGFloat = 28
        var body: CGFloat = 15
        var text: CGFloat = 17
    }

    /// The steps the space between things is made of, smallest first.
    var rhythm: [CGFloat] = [8, 12, 16, 24, 32]
    var cornerRadii = CornerRadii()
    var card = Card()
    var textSizes = TextSizes()
    /// What a newer Layer saved with the tokens that this version doesn't know.
    var unknownKeys = UnknownKeys()

    static let standard = DesignTokens()

    /// The rhythm step nearest `standard`, the smaller on a tie: how the standard 24, 12 and 8 carry over to a
    /// design's own rhythm. Standard tokens give `standard` back.
    func spacing(nearest standard: CGFloat) -> CGFloat {
        Self.step(nearest: standard, in: rhythm)
    }

    /// The step of `rhythm` nearest `value`, the smaller on a tie; `value` itself when the rhythm has none.
    static func step(nearest value: CGFloat, in rhythm: [CGFloat]) -> CGFloat {
        var best = value
        var distance = CGFloat.infinity
        for step in rhythm.sorted() {
            let gap = abs(step - value)
            if gap < distance { best = step; distance = gap }
        }
        return best
    }

    enum CodingKeys: String, CodingKey {
        case rhythm, cornerRadii, card, textSizes
    }

    init() {}

    // MARK: Reading

    /// A rhythm as the design keeps it: its steps that are finite and above zero, sorted and each once; the
    /// standard's when none is. A file's rhythm is read this way, and so is one typed in the canvas settings (F25).
    static func reading(rhythm: [CGFloat]) -> [CGFloat] {
        let kept = Array(Set(rhythm.filter { $0.isFinite && $0 > 0 })).sorted()
        return kept.isEmpty ? standard.rhythm : kept
    }

    /// A radius, padding or text size as the design keeps it: `size` when it is finite and above zero, else
    /// `standard`. A file's are read this way, and so are those typed in the canvas settings (F25).
    static func reading(size: CGFloat, standard: CGFloat) -> CGFloat {
        size.isFinite && size > 0 ? size : standard
    }

    /// These tokens with every number read as a file's are (`reading(rhythm:)`, `reading(size:standard:)`): what a
    /// design holding them keeps.
    var asRead: DesignTokens {
        let standard = Self.standard
        var tokens = self
        tokens.rhythm = Self.reading(rhythm: rhythm)
        tokens.cornerRadii.small = Self.reading(size: cornerRadii.small, standard: standard.cornerRadii.small)
        tokens.cornerRadii.medium = Self.reading(size: cornerRadii.medium, standard: standard.cornerRadii.medium)
        tokens.cornerRadii.large = Self.reading(size: cornerRadii.large, standard: standard.cornerRadii.large)
        tokens.card.padding = Self.reading(size: card.padding, standard: standard.card.padding)
        tokens.card.radius = Self.reading(size: card.radius, standard: standard.card.radius)
        tokens.textSizes.title = Self.reading(size: textSizes.title, standard: standard.textSizes.title)
        tokens.textSizes.body = Self.reading(size: textSizes.body, standard: standard.textSizes.body)
        tokens.textSizes.text = Self.reading(size: textSizes.text, standard: standard.textSizes.text)
        return tokens
    }

    /// Reads leniently: a number that isn't finite and above zero, or a part that can't be
    /// read, is the standard's. The rhythm is sorted and made unique, and the standard's
    /// when nothing in it is usable. The rules are `reading(rhythm:)` and `reading(size:standard:)`.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let standard = DesignTokens.standard
        let steps = ((try? container.decodeIfPresent([CGFloat].self, forKey: .rhythm)) ?? nil) ?? standard.rhythm
        rhythm = Self.reading(rhythm: steps)
        cornerRadii = ((try? container.decodeIfPresent(CornerRadii.self, forKey: .cornerRadii)) ?? nil) ?? standard.cornerRadii
        card = ((try? container.decodeIfPresent(Card.self, forKey: .card)) ?? nil) ?? standard.card
        textSizes = ((try? container.decodeIfPresent(TextSizes.self, forKey: .textSizes)) ?? nil) ?? standard.textSizes
        unknownKeys = try UnknownKeys(from: decoder, besides: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        try unknownKeys.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rhythm, forKey: .rhythm)
        try container.encode(cornerRadii, forKey: .cornerRadii)
        try container.encode(card, forKey: .card)
        try container.encode(textSizes, forKey: .textSizes)
    }
}

private extension KeyedDecodingContainer {
    /// A number that is finite and above zero, or the standard's (`DesignTokens.reading(size:standard:)`).
    func size(_ key: Key, standard: CGFloat) -> CGFloat {
        guard let value = (try? decodeIfPresent(CGFloat.self, forKey: key)) ?? nil else { return standard }
        return DesignTokens.reading(size: value, standard: standard)
    }
}

extension DesignTokens.CornerRadii {
    enum CodingKeys: String, CodingKey { case small, medium, large }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let standard = Self()
        small = container.size(.small, standard: standard.small)
        medium = container.size(.medium, standard: standard.medium)
        large = container.size(.large, standard: standard.large)
    }
}

extension DesignTokens.Card {
    enum CodingKeys: String, CodingKey { case padding, radius, fill }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let standard = Self()
        padding = container.size(.padding, standard: standard.padding)
        radius = container.size(.radius, standard: standard.radius)
        fill = ((try? container.decodeIfPresent(RGBColor.self, forKey: .fill)) ?? nil) ?? standard.fill
    }
}

extension DesignTokens.TextSizes {
    enum CodingKeys: String, CodingKey { case title, body, text }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let standard = Self()
        title = container.size(.title, standard: standard.title)
        body = container.size(.body, standard: standard.body)
        text = container.size(.text, standard: standard.text)
    }
}

extension DesignTokens: KeepsUnknownKeys {}
