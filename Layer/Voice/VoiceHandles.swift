import Foundation

/// Short names for the screens and nodes of a design, for the length of one call: S1, S2
/// for screens and E1, E2 for what is on them, containers and all, in one sequence (plan 6,
/// call 7). A screen's root has no E handle: its screen's S handle stands for it. A model is
/// told the canvas in these and answers in them, which costs it far less than the
/// identifiers the design keeps, and is far harder to get wrong.
///
/// A handle means the same thing for the whole call, however the node is regrouped, since a
/// node keeps its id. Numbers only go up, so one is never handed on to something else after
/// what it named has gone.
@MainActor
final class VoiceHandles {
    private var screenNumbers: [TreeScreen.ID: Int] = [:]
    private var nodeNumbers: [UUID: Int] = [:]
    private var screens: [Int: TreeScreen.ID] = [:]
    private var nodes: [Int: UUID] = [:]

    func handle(forScreen id: TreeScreen.ID) -> String {
        if let number = screenNumbers[id] { return "S\(number)" }
        let number = screenNumbers.count + 1
        screenNumbers[id] = number
        screens[number] = id
        return "S\(number)"
    }

    func handle(forNode id: UUID) -> String {
        if let number = nodeNumbers[id] { return "E\(number)" }
        let number = nodeNumbers.count + 1
        nodeNumbers[id] = number
        nodes[number] = id
        return "E\(number)"
    }

    /// The screen a handle names, however the model wrote it: `S1`, `s1`, ` S1 ` or `#S1`.
    func screen(_ handle: String) -> TreeScreen.ID? {
        Self.number(in: handle, after: "S").flatMap { screens[$0] }
    }

    /// The node an E handle names, however the model wrote it, as `screen(_:)` reads an S handle.
    func node(_ handle: String) -> UUID? {
        Self.number(in: handle, after: "E").flatMap { nodes[$0] }
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
