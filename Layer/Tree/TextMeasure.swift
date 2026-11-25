import CoreGraphics
import CoreText
import Foundation
import os

/// Measures text with Core Text, so the layout engine can size text on any platform and off
/// the main thread. Sizes are whole points, rounded up, so a box is never a hair too small.
final class TextMeasure: Sendable {
    static let shared = TextMeasure()

    /// For tests that need a cache of their own; everything else uses `shared`.
    init() {}

    private struct Key: Hashable {
        var text: String
        var fontSize: CGFloat
        var weight: FontWeightChoice
        var width: CGFloat?
    }

    private struct Cache<Value: Sendable>: Sendable {
        var values: [Key: Value] = [:]
        /// Oldest first.
        var order: [Key] = []
        var misses = 0

        /// Keeps `value`, letting the oldest go past `capacity`.
        mutating func keep(_ value: Value, for key: Key) {
            misses += 1
            guard values.updateValue(value, forKey: key) == nil else { return }
            order.append(key)
            if order.count > TextMeasure.capacity { values[order.removeFirst()] = nil }
        }
    }

    fileprivate static let capacity = 2_000
    private let cache = OSAllocatedUnfairLock(initialState: Cache<CGSize>())
    /// The widest word of each text, by the text, kept apart so that words never push the texts
    /// the layout measures out of `cache`.
    private let widestWords = OSAllocatedUnfairLock(initialState: Cache<CGFloat>())

    /// Whole points (rounded up). `width` nil = one line's natural width. Empty text = zero
    /// width, one line high. A `width` that is not finite, or is zero or negative, reads as nil.
    /// Text wraps at the whole points within `width`, the most a frame is ever given of it, so
    /// a frame snapped to whole points is never narrower than the width its text was measured at.
    /// A font size that isn't one reads as 17, and one past 1,000 points as 1,000.
    func size(of text: String, fontSize: CGFloat, weight: FontWeightChoice, width: CGFloat?) -> CGSize {
        let key = Key(text: text, fontSize: Self.fontSize(fontSize), weight: weight,
                      width: width.flatMap { $0.isFinite && $0 > 0 ? ($0 >= 1 ? $0.rounded(.down) : $0) : nil })
        if let hit = cache.withLock({ $0.values[key] }) { return hit }
        let size = Self.measure(key)
        cache.withLock { $0.keep(size, for: key) }
        return size
    }

    /// How wide the widest word in `text` is on its own, in whole points; 0 for text without words.
    /// Each text's words are measured once, and none of them is kept in the cache of texts.
    func widestWord(in text: String, fontSize: CGFloat, weight: FontWeightChoice) -> CGFloat {
        let key = Key(text: text, fontSize: Self.fontSize(fontSize), weight: weight, width: nil)
        if let hit = widestWords.withLock({ $0.values[key] }) { return hit }
        var words = Set<String>()
        text.enumerateSubstrings(in: text.startIndex..., options: .byWords) { word, _, _, _ in
            if let word { words.insert(word) }
        }
        let widest = words.map { Self.measure(Key(text: $0, fontSize: key.fontSize, weight: weight, width: nil)).width }.max() ?? 0
        widestWords.withLock { $0.keep(widest, for: key) }
        return widest
    }

    /// A font size as text is measured at: from 1 to 1,000 points, and 17 for one that isn't a size.
    private static func fontSize(_ size: CGFloat) -> CGFloat {
        size.isFinite && size > 0 ? min(max(size, 1), 1_000) : 17
    }

    #if DEBUG
    /// Measurements not found in the cache.
    var misses: Int { cache.withLock { $0.misses } }
    #endif

    private static func measure(_ key: Key) -> CGSize {
        let font = font(size: key.fontSize, weight: key.weight)
        guard !key.text.isEmpty else {
            return CGSize(width: 0, height: wholeUp(lineHeight(of: font)))
        }
        let attributed = NSAttributedString(string: key.text, attributes: [.init(kCTFontAttributeName as String): font])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let limit = CGSize(width: key.width ?? 100_000, height: 100_000)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil, limit, nil)
        var width = wholeUp(suggested.width)
        if let offered = key.width { width = min(width, offered.rounded(.down)) }
        let height = max(linesHeight(framesetter, width: limit.width) ?? suggested.height, lineHeight(of: font))
        return CGSize(width: width, height: wholeUp(height))
    }

    /// The lines' heights added up at their true, unrounded metrics. The framesetter's own
    /// suggestion rounds every line up, which over a long text is well over a point too tall.
    private static func linesHeight(_ framesetter: CTFramesetter, width: CGFloat) -> CGFloat? {
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 100_000), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        guard !lines.isEmpty else { return nil }
        var total: CGFloat = 0
        for line in lines {
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            total += ascent + descent + leading
        }
        return total
    }

    private static func lineHeight(of font: CTFont) -> CGFloat {
        CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
    }

    private static func wholeUp(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(0, value.rounded(.up)) : 0
    }

    private static func font(size: CGFloat, weight: FontWeightChoice) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let trait: CGFloat = switch weight {
        case .regular: 0
        case .medium: 0.23
        case .semibold: 0.3
        case .bold: 0.4
        }
        let attributes: [CFString: Any] = [kCTFontTraitsAttribute: [kCTFontWeightTrait: trait]]
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(base), attributes as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }
}
