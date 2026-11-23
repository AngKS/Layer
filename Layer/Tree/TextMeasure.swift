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

    private struct Cache {
        var sizes: [Key: CGSize] = [:]
        /// Oldest first.
        var order: [Key] = []
        var misses = 0
    }

    private static let capacity = 2_000
    private let cache = OSAllocatedUnfairLock(initialState: Cache())

    /// Whole points (rounded up). `width` nil = one line's natural width. Empty text = zero
    /// width, one line high. A `width` that is not finite, or is zero or negative, reads as nil.
    func size(of text: String, fontSize: CGFloat, weight: FontWeightChoice, width: CGFloat?) -> CGSize {
        let fontSize = fontSize.isFinite && fontSize > 0 ? fontSize : 17
        let width = width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let key = Key(text: text, fontSize: fontSize, weight: weight, width: width)
        if let hit = cache.withLock({ $0.sizes[key] }) { return hit }
        let size = Self.measure(key)
        cache.withLock { cache in
            cache.misses += 1
            if cache.sizes.updateValue(size, forKey: key) == nil {
                cache.order.append(key)
                if cache.order.count > Self.capacity {
                    cache.sizes[cache.order.removeFirst()] = nil
                }
            }
        }
        return size
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
