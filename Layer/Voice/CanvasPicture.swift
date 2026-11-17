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

    static let empty = CanvasPicture()

    var hasScreens: Bool { !screens.isEmpty }

    // MARK: In words

    func text(_ detail: Detail) -> String {
        guard hasScreens || !loose.isEmpty else { return "The canvas has no screens yet." }
        var lines: [String] = []
        if hasScreens {
            lines.append("Screens in order (S1 is the first, the last is the newest):")
            let focus = detail == .compact ? focusedScreen : nil
            for screen in screens {
                let isBrief = detail == .compact && screen.handle != focus
                lines.append(Self.line(for: screen, isBrief: isBrief))
                if !isBrief { lines += screen.elements.map { "  " + Self.line(for: $0) } }
            }
        } else {
            lines.append("The canvas has no screens yet.")
        }
        if !loose.isEmpty {
            lines.append("Loose on the canvas:")
            lines += loose.map { "  " + Self.line(for: $0) }
        }
        return lines.joined(separator: "\n")
    }

    /// The screen the person is most likely talking about: the one mostly in view, or
    /// else the one selected or holding the selection, or else the newest.
    private var focusedScreen: String? {
        if let inView = screens.filter({ $0.visibleShare > 0.3 }).max(by: { $0.visibleShare < $1.visibleShare }) {
            return inView.handle
        }
        if let selected = screens.first(where: { $0.isSelected || $0.elements.contains(where: \.isSelected) }) {
            return selected.handle
        }
        return screens.last?.handle
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
