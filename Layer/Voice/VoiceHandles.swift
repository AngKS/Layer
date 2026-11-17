import Foundation

/// Short names for the screens and elements of a design, for the length of one call: S1,
/// S2 for screens and E1, E2 for elements. A model is told the canvas in these and answers
/// in them, which costs it far less than the identifiers the design keeps, and is far
/// harder to get wrong.
///
/// A handle means the same thing for the whole call. Numbers only go up, so one is never
/// handed on to something else after what it named has gone.
@MainActor
final class VoiceHandles {
    private var screenNumbers: [DesignScreen.ID: Int] = [:]
    private var elementNumbers: [DesignElement.ID: Int] = [:]
    private var screens: [Int: DesignScreen.ID] = [:]
    private var elements: [Int: DesignElement.ID] = [:]

    func handle(forScreen id: DesignScreen.ID) -> String {
        if let number = screenNumbers[id] { return "S\(number)" }
        let number = screenNumbers.count + 1
        screenNumbers[id] = number
        screens[number] = id
        return "S\(number)"
    }

    func handle(forElement id: DesignElement.ID) -> String {
        if let number = elementNumbers[id] { return "E\(number)" }
        let number = elementNumbers.count + 1
        elementNumbers[id] = number
        elements[number] = id
        return "E\(number)"
    }

    /// The screen a handle names, however the model wrote it: `S1`, `s1`, ` S1 ` or `#S1`.
    func screen(_ handle: String) -> DesignScreen.ID? {
        Self.number(in: handle, after: "S").flatMap { screens[$0] }
    }

    func element(_ handle: String) -> DesignElement.ID? {
        Self.number(in: handle, after: "E").flatMap { elements[$0] }
    }

    /// The handle as it is written here, such as `E7` from ` e 7`. Nil if it isn't one.
    static func tidied(_ handle: String) -> String? {
        for letter in ["S", "E"] {
            if let number = number(in: handle, after: letter) { return "\(letter)\(number)" }
        }
        return nil
    }

    private static func number(in handle: String, after letter: String) -> Int? {
        let cleaned = handle.uppercased().filter { !$0.isWhitespace && $0 != "#" }
        guard cleaned.hasPrefix(letter) else { return nil }
        let digits = cleaned.dropFirst()
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }
}
