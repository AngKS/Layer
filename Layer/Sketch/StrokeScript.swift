import CoreGraphics
import Foundation

/// Pen strokes written as text, so that Siri, Shortcuts and language models can draw on
/// the canvas without a pencil. One stroke per line (or split by `;`), either as freehand
/// points or as a named shape:
///
///     120,80 300,80 300,140 120,140 120,80   freehand: x,y pairs, joined in order
///     box 30 200 330 56 12                   x y width height [corner radius]
///     pill 30 700 330 56                     x y width height, fully rounded ends
///     circle 200 300 40                      centre x, centre y, radius
///     oval 30 60 64 64                       x y width height
///     line 20 400 370 400                    x1 y1 x2 y2 [x3 y3 …]: a polyline
///     wave 150 112 96 40 3                   x y width height [humps]: a squiggle
///     cross 34 186 326 364                   x y width height: two diagonals, as two strokes
///     tick 300 640 24 24                     x y width height: a check mark
///     dot 310 650 3                          centre x, centre y [radius]
///     scribble 120 586 150 40 6              x y width height [passes]: a scratch-out
///
/// Words after the shape's name, such as `radius` or `humps`, are ignored, so
/// `box 30 200 330 56 radius 12` reads the same as `box 30 200 330 56 12`. Lines starting
/// with `#` or `//` are comments. A JSON array of strokes, each an array of `[x, y]` pairs
/// or `{"x": …, "y": …}` objects, is read too, optionally wrapped as `{"strokes": […]}`.
///
/// Shapes are drawn with a slight, repeatable wobble, as a hand draws them, since that is
/// what the Magic Pen's reading is tuned on. Freehand points are filled in every few points
/// so that PencilKit draws straight segments between them rather than smoothing them away.
enum StrokeScript {
    struct ParseError: Error, Equatable, Sendable {
        /// The line it couldn't read, numbered from 1, or 0 for JSON.
        var line: Int
        var text: String
        var reason: String
    }

    /// The shape names, for describing the format.
    static let shapeNames = ["box", "pill", "circle", "oval", "line", "wave", "cross", "tick", "dot", "scribble"]

    /// The largest number a script may use for a place or a size, in canvas points: far
    /// past any board. Larger ones trapped working out a stroke's points.
    static let largestNumber: CGFloat = 100_000
    /// The most points one stroke may have once drawn, about 15,000 points long, and the
    /// most humps or passes a shape may have. Past them a script built strokes of hundreds
    /// of millions of points and the app was killed for the memory.
    static let mostPointsPerStroke = 5_000
    static let mostRepeats = 50

    static func parse(_ written: String) throws -> [[CGPoint]] {
        let trimmed = written.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") { return try parseJSON(trimmed) }

        var parsed: [[CGPoint]] = []
        let lines = written.replacingOccurrences(of: ";", with: "\n").components(separatedBy: .newlines)
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { continue }
            do {
                parsed += try drawable(strokes(fromLine: line))
            } catch let reason as Reason {
                throw ParseError(line: index + 1, text: line, reason: reason.text)
            }
        }
        return parsed.filter { !$0.isEmpty }
    }

    // MARK: Lines

    private struct Reason: Error {
        var text: String
    }

    private static func checked(_ numbers: [CGFloat]) throws -> [CGFloat] {
        guard numbers.allSatisfy({ $0.isFinite && abs($0) <= largestNumber }) else {
            throw Reason(text: "Numbers go up to \(Int(largestNumber)) either way.")
        }
        return numbers
    }

    private static func drawable(_ strokes: [[CGPoint]]) throws -> [[CGPoint]] {
        guard strokes.allSatisfy({ $0.count <= mostPointsPerStroke }) else {
            throw Reason(text: "That stroke is too long to draw: keep each under about \(mostPointsPerStroke * 3) points long.")
        }
        return strokes
    }

    /// The number of humps or passes written at `index`, if one is, within the limit.
    private static func repeats(_ numbers: [CGFloat], at index: Int, least: Int, otherwise usual: Int) throws -> Int {
        guard numbers.count > index else { return usual }
        guard numbers[index] <= CGFloat(mostRepeats) else { throw Reason(text: "Up to \(mostRepeats) humps or passes.") }
        return max(least, Int(numbers[index].rounded()))
    }

    private static func strokes(fromLine line: String) throws -> [[CGPoint]] {
        let numbers = try checked(Self.numbers(in: line))
        guard let first = line.first, first.isLetter else {
            guard numbers.count >= 4 else { throw Reason(text: "A freehand stroke needs at least two x,y points.") }
            guard numbers.count.isMultiple(of: 2) else { throw Reason(text: "Points come in x,y pairs, and one number is left over.") }
            let points = stride(from: 0, to: numbers.count, by: 2).map { CGPoint(x: numbers[$0], y: numbers[$0 + 1]) }
            return [densified(points)]
        }

        let name = String(line.prefix { $0.isLetter }).lowercased()
        func need(_ count: Int, _ form: String) throws {
            guard numbers.count >= count else { throw Reason(text: "\(name) needs \(form).") }
        }
        func rect() -> CGRect {
            CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]).standardized
        }

        switch name {
        case "box", "rect", "rectangle", "square":
            try need(4, "x y width height")
            let r = rect()
            let radius = numbers.count > 4 ? numbers[4] : min(r.width, r.height) * 0.12
            return [box(r, radius: radius)]
        case "pill", "capsule":
            try need(4, "x y width height")
            let r = rect()
            return [box(r, radius: min(r.width, r.height) / 2)]
        case "circle":
            try need(3, "centre x, centre y and radius")
            let radius = abs(numbers[2])
            return [box(CGRect(x: numbers[0] - radius, y: numbers[1] - radius, width: radius * 2, height: radius * 2), radius: radius)]
        case "oval", "ellipse":
            try need(4, "x y width height")
            return [ellipse(rect())]
        case "line", "polyline", "path":
            try need(4, "at least two x,y points")
            guard numbers.count.isMultiple(of: 2) else { throw Reason(text: "line's points come in x,y pairs, and one number is left over.") }
            let points = stride(from: 0, to: numbers.count, by: 2).map { CGPoint(x: numbers[$0], y: numbers[$0 + 1]) }
            return [wobbled(densified(points), by: 0.8)]
        case "wave", "zigzag", "squiggle":
            try need(4, "x y width height")
            let humps = try repeats(numbers, at: 4, least: 1, otherwise: 3)
            return [wave(rect(), humps: humps)]
        case "cross", "x":
            try need(4, "x y width height")
            let inner = rect().insetBy(dx: rect().width * 0.14, dy: rect().height * 0.14)
            return [
                wobbled(densified([CGPoint(x: inner.minX, y: inner.minY), CGPoint(x: inner.maxX, y: inner.maxY)]), by: 0.8),
                wobbled(densified([CGPoint(x: inner.maxX, y: inner.minY), CGPoint(x: inner.minX, y: inner.maxY)]), by: 0.8),
            ]
        case "tick", "check", "checkmark":
            try need(4, "x y width height")
            let r = rect()
            let points = [
                CGPoint(x: r.minX + r.width * 0.2, y: r.minY + r.height * 0.5),
                CGPoint(x: r.minX + r.width * 0.42, y: r.minY + r.height * 0.78),
                CGPoint(x: r.minX + r.width * 0.82, y: r.minY + r.height * 0.2),
            ]
            return [wobbled(densified(points), by: 0.5)]
        case "dot":
            try need(2, "centre x and centre y")
            let radius = numbers.count > 2 ? max(abs(numbers[2]), 0.5) : 2
            return [box(CGRect(x: numbers[0] - radius, y: numbers[1] - radius, width: radius * 2, height: radius * 2), radius: radius, wobble: 0)]
        case "scribble", "scratch", "scratchout":
            try need(4, "x y width height")
            let passes = try repeats(numbers, at: 4, least: 2, otherwise: 6)
            return [scribble(rect(), passes: passes)]
        default:
            throw Reason(text: "“\(name)” isn't a shape. Use \(shapeNames.joined(separator: ", ")), or x,y points.")
        }
    }

    /// Every number on a line, in order, including negatives and decimals.
    static func numbers(in line: String) -> [CGFloat] {
        var numbers: [CGFloat] = []
        var current = ""
        func flush() {
            if let value = Double(current) { numbers.append(CGFloat(value)) }
            current = ""
        }
        for character in line {
            if character.isNumber || character == "." || (character == "-" && current.isEmpty) {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return numbers
    }

    // MARK: JSON

    private static func parseJSON(_ text: String) throws -> [[CGPoint]] {
        func fail(_ reason: String) -> ParseError {
            ParseError(line: 0, text: String(text.prefix(80)), reason: reason)
        }
        guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else {
            throw fail("That isn't valid JSON.")
        }
        let list: [Any]
        if let array = object as? [Any] {
            list = array
        } else if let dictionary = object as? [String: Any], let array = dictionary["strokes"] as? [Any] {
            list = array
        } else {
            throw fail("Give an array of strokes, or an object with a \"strokes\" array.")
        }
        return try list.map { item -> [CGPoint] in
            guard let points = item as? [Any] else { throw fail("Each stroke is an array of points.") }
            let parsed = try points.map { point -> CGPoint in
                if let pair = point as? [Any], pair.count >= 2, let x = number(pair[0]), let y = number(pair[1]) {
                    return CGPoint(x: x, y: y)
                }
                if let named = point as? [String: Any], let x = named["x"].flatMap(number), let y = named["y"].flatMap(number) {
                    return CGPoint(x: x, y: y)
                }
                throw fail("Each point is [x, y] or {\"x\": x, \"y\": y}.")
            }
            guard parsed.count >= 2 else { throw fail("Each stroke needs at least two points.") }
            do {
                _ = try checked(parsed.flatMap { [$0.x, $0.y] })
                return try drawable([densified(parsed)])[0]
            } catch let reason as Reason {
                throw fail(reason.text)
            }
        }
    }

    private static func number(_ value: Any) -> CGFloat? {
        if let double = value as? Double { return CGFloat(double) }
        if let int = value as? Int { return CGFloat(int) }
        if let number = value as? NSNumber { return CGFloat(number.doubleValue) }
        return nil
    }

    // MARK: Shapes

    /// Fills in points no more than `spacing` apart along each segment.
    static func densified(_ points: [CGPoint], spacing: CGFloat = 3) -> [CGPoint] {
        guard let first = points.first else { return [] }
        var result = [first]
        for (a, b) in zip(points, points.dropFirst()) {
            let steps = max(1, Int((hypot(b.x - a.x, b.y - a.y) / spacing).rounded(.up)))
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                result.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        return result
    }

    /// A rounded box in one stroke, clockwise from the top-left. A radius of half the
    /// shorter side gives a pill or a circle.
    static func box(_ rect: CGRect, radius: CGFloat, wobble: CGFloat = 1.2) -> [CGPoint] {
        let r = max(0, min(radius, min(rect.width, rect.height) / 2))
        var points: [CGPoint] = []

        func line(_ a: CGPoint, _ b: CGPoint) {
            let steps = max(1, Int(hypot(b.x - a.x, b.y - a.y) / 3))
            for step in 0..<steps {
                let t = CGFloat(step) / CGFloat(steps)
                points.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        func arc(_ center: CGPoint, from: CGFloat, to: CGFloat) {
            guard r > 0 else { return }
            let steps = max(2, Int(abs(to - from) * r / 3))
            for step in 0..<steps {
                let angle = from + (to - from) * CGFloat(step) / CGFloat(steps)
                points.append(CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r))
            }
        }

        line(CGPoint(x: rect.minX + r, y: rect.minY), CGPoint(x: rect.maxX - r, y: rect.minY))
        arc(CGPoint(x: rect.maxX - r, y: rect.minY + r), from: -.pi / 2, to: 0)
        line(CGPoint(x: rect.maxX, y: rect.minY + r), CGPoint(x: rect.maxX, y: rect.maxY - r))
        arc(CGPoint(x: rect.maxX - r, y: rect.maxY - r), from: 0, to: .pi / 2)
        line(CGPoint(x: rect.maxX - r, y: rect.maxY), CGPoint(x: rect.minX + r, y: rect.maxY))
        arc(CGPoint(x: rect.minX + r, y: rect.maxY - r), from: .pi / 2, to: .pi)
        line(CGPoint(x: rect.minX, y: rect.maxY - r), CGPoint(x: rect.minX, y: rect.minY + r))
        arc(CGPoint(x: rect.minX + r, y: rect.minY + r), from: .pi, to: .pi * 1.5)
        points.append(points[0])
        return wobbled(points, by: wobble)
    }

    static func ellipse(_ rect: CGRect) -> [CGPoint] {
        let circumference = CGFloat.pi * (rect.width + rect.height) / 2
        let steps = max(12, Int(circumference / 3))
        let points = (0...steps).map { step -> CGPoint in
            let angle = -CGFloat.pi / 2 + 2 * CGFloat.pi * CGFloat(step) / CGFloat(steps)
            return CGPoint(x: rect.midX + cos(angle) * rect.width / 2, y: rect.midY + sin(angle) * rect.height / 2)
        }
        return wobbled(points, by: 1)
    }

    /// A squiggle left to right with the given number of humps: a title when short and
    /// tall, body text when long and low.
    static func wave(_ rect: CGRect, humps: Int) -> [CGPoint] {
        let steps = max(16, Int(rect.width / 1.5))
        return (0...steps).map { step in
            let t = CGFloat(step) / CGFloat(steps)
            return CGPoint(x: rect.minX + rect.width * t, y: rect.midY - sin(t * CGFloat(humps) * 2 * .pi) * rect.height / 2)
        }
    }

    /// Back and forth across an area, top to bottom: scratching something out.
    static func scribble(_ rect: CGRect, passes: Int) -> [CGPoint] {
        var points: [CGPoint] = []
        for pass in 0...passes {
            let y = rect.minY + rect.height * CGFloat(pass) / CGFloat(passes)
            for step in 0...20 {
                let t = CGFloat(step) / 20
                points.append(CGPoint(x: pass.isMultiple(of: 2) ? rect.minX + rect.width * t : rect.maxX - rect.width * t, y: y))
            }
        }
        return points
    }

    static func wobbled(_ points: [CGPoint], by amount: CGFloat) -> [CGPoint] {
        guard amount != 0 else { return points }
        return points.enumerated().map { index, point in
            CGPoint(x: point.x + sin(CGFloat(index) * 0.21) * amount, y: point.y + cos(CGFloat(index) * 0.17) * amount)
        }
    }
}
