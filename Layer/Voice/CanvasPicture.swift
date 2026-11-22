import CoreGraphics
import Foundation

/// What is on the canvas at one moment, as a model is told it: every screen and element
/// by its handle, with where it is and how it looks. A voice command is carried out
/// against this, so it is taken afresh before each command and after each change.
struct CanvasPicture: Sendable, Equatable {
    /// How much is said. A hosted model is told everything. The on-device model has
    /// little room, so it is told one screen in full and the rest by name.
    enum Detail: Sendable {
        case full
        case compact
    }

    struct Element: Sendable, Equatable {
        var handle: String
        /// The kind as people say it, such as `text field`.
        var kind: String
        var text: String
        /// In the screen's own points; nil for a loose element, which has no screen.
        var frame: CGRect?
        /// How far it is turned clockwise, in degrees; 0 when upright.
        var rotation: Double = 0
        /// Look words that would give this look back, such as `colour blue` or `bold`.
        var look: [String] = []
        var isSelected = false
        var isLocked = false
        var isHidden = false
    }

    struct Screen: Sendable, Equatable {
        var handle: String
        var name: String
        var size: CGSize
        /// How much of the screen the window is showing, from 0 to 1.
        var visibleShare: Double = 0
        var isSelected = false
        var isLocked = false
        /// From the top of the screen down.
        var elements: [Element] = []
    }

    /// In the order they were made: the first is the oldest, the last the newest.
    var screens: [Screen] = []
    /// Elements on the open canvas, outside every screen.
    var loose: [Element] = []
    /// The handle of the screen a change is for, when the change can touch nothing else:
    /// that screen is told in full and every other by its one line, however much room the
    /// model has, and nothing loose is told at all. Nil for a command that can go anywhere.
    var scope: String?

    static let empty = CanvasPicture()

    var hasScreens: Bool { !screens.isEmpty }

    // MARK: In words

    func text(_ detail: Detail) -> String {
        guard hasScreens || !loose.isEmpty else { return "The canvas has no screens yet." }
        var lines: [String] = []
        if hasScreens {
            lines.append("Screens in order (S1 is the first, the last is the newest):")
            // Every screen is told in full, unless the change is for one or the model is
            // short of room: then only that one, or the one most likely meant.
            let tellsAll = scope == nil && detail == .full
            let focus = scope ?? (detail == .compact ? focusedScreen : nil)
            for screen in screens {
                let isBrief = !tellsAll && screen.handle != focus
                lines.append(Self.line(for: screen, isBrief: isBrief))
                if !isBrief { lines += screen.elements.map { "  " + Self.line(for: $0) } }
            }
        } else {
            lines.append("The canvas has no screens yet.")
        }
        // A change for one screen can't touch what is loose, so it isn't told of it.
        if !loose.isEmpty, scope == nil {
            lines.append("Loose on the canvas:")
            lines += loose.map { "  " + Self.line(for: $0) }
        }
        return lines.joined(separator: "\n")
    }

    /// The screen the person is most likely talking about: the one selected or holding the
    /// selection, which the pencil points at, or else the one mostly in view, or else the
    /// newest. Pointed at, a screen not mostly in view must still be told in full.
    private var focusedScreen: String? {
        if let selected = screens.first(where: { $0.isSelected || $0.elements.contains(where: \.isSelected) }) {
            return selected.handle
        }
        if let inView = screens.filter({ $0.visibleShare > 0.3 }).max(by: { $0.visibleShare < $1.visibleShare }) {
            return inView.handle
        }
        return screens.last?.handle
    }

    /// What is selected, in words a model can't mistake, such as `E42, the button "Save" on
    /// S3`; nil when nothing is.
    var selectionInWords: String? {
        var things: [String] = []
        for screen in screens {
            if screen.isSelected { things.append(Self.words(for: screen)) }
            for element in screen.elements where element.isSelected {
                things.append(Self.words(for: element) + " on \(screen.handle)")
            }
        }
        things += loose.filter(\.isSelected).map(Self.words(for:))
        return things.isEmpty ? nil : things.joined(separator: "; ")
    }

    /// A screen in words a model can't mistake, such as `S1, the screen "Login"`; nil for a
    /// handle that names none of these.
    func screenInWords(_ handle: String) -> String? {
        screens.first { $0.handle == handle }.map(Self.words(for:))
    }

    private static func words(for screen: Screen) -> String {
        "\(screen.handle), the screen \"\(screen.name)\""
    }

    private static func words(for element: Element) -> String {
        let text = element.text.replacingOccurrences(of: "\n", with: " ")
        guard !text.isEmpty else { return "\(element.handle), the \(element.kind)" }
        return "\(element.handle), the \(element.kind) \"\(text.count > 48 ? text.prefix(45) + "…" : text)\""
    }

    private static func line(for screen: Screen, isBrief: Bool) -> String {
        var line = "\(screen.handle) \"\(screen.name)\" \(Int(screen.size.width))x\(Int(screen.size.height))"
        if screen.visibleShare > 0.3 { line += " [in view]" }
        if screen.isSelected { line += " [selected]" }
        if screen.isLocked { line += " [locked]" }
        if isBrief {
            let count = screen.elements.count
            line += ", \(count == 1 ? "1 element" : "\(count) elements")"
        } else if screen.elements.isEmpty {
            line += ", empty"
        }
        return line
    }

    private static func line(for element: Element) -> String {
        var parts = [element.handle, element.kind]
        if !element.text.isEmpty {
            // A long passage is cut short: its first words are enough to know it by.
            let words = element.text.replacingOccurrences(of: "\n", with: " ")
            parts.append("\"\(words.count > 48 ? words.prefix(45) + "…" : words)\"")
        }
        if let frame = element.frame {
            parts.append("x\(number(frame.minX)) y\(number(frame.minY)) w\(number(frame.width)) h\(number(frame.height))")
        }
        if element.rotation != 0 { parts.append("turned \(number(CGFloat(Rotation.shown(element.rotation))))°") }
        parts += element.look
        if element.isSelected { parts.append("[selected]") }
        if element.isLocked { parts.append("[locked]") }
        if element.isHidden { parts.append("[hidden]") }
        return parts.joined(separator: " ")
    }

    private static func number(_ value: CGFloat) -> String {
        String(Int(value.rounded()))
    }
}
