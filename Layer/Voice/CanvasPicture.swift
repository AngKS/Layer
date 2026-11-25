import CoreGraphics
import Foundation

/// What is on the canvas at one moment, as a model is told it: every screen and what it
/// holds by its handle, with where it is and how it looks, containers told with their layout
/// in words and what they hold indented under them. A voice command is carried out against
/// this, so it is taken afresh before each command and after each change.
struct CanvasPicture: Sendable, Equatable {
    /// How much is said. A hosted model is told everything. The on-device model has
    /// little room, so it is told one screen in full and the rest by name.
    enum Detail: Sendable {
        case full
        case compact
    }

    struct Element: Sendable, Equatable {
        var handle: String
        /// The kind as people say it, such as `text field`; `group` or `card` for a container.
        var kind: String
        var text: String
        /// In the screen's own points; nil for a loose element, which has no screen.
        var frame: CGRect?
        /// How far it is turned clockwise, in degrees, its containers' turns added in; 0 when upright.
        var rotation: Double = 0
        /// Look words that would give this look back, such as `colour blue` or `bold`.
        var look: [String] = []
        var isSelected = false
        var isLocked = false
        var isHidden = false
        /// A container's layout in words, such as `row, spacing 12, centred`; nil for a leaf, a free group or a free card.
        var layout: String? = nil
        var isContainer = false
        /// What a container holds, in the order it is read: a row's, column's, grid's or overlay's own order, which
        /// lays them out; otherwise from the top down, then from the left.
        var children: [Element] = []
    }

    struct Screen: Sendable, Equatable {
        var handle: String
        var name: String
        var size: CGSize
        /// How much of the screen the window is showing, from 0 to 1.
        var visibleShare: Double = 0
        var isSelected = false
        var isLocked = false
        /// What its root holds, in the order it is read, as a container's `children` are.
        var elements: [Element] = []
        /// Its root's layout in words, such as `column, spacing 24`; nil when the root is free.
        var layout: String? = nil
    }

    /// In the order they were made: the first is the oldest, the last the newest.
    var screens: [Screen] = []
    /// Elements on the open canvas, outside every screen.
    var loose: [Element] = []
    /// The handle of the screen a change is for, when the change can touch nothing else:
    /// that screen is told in full and every other by its one line, however much room the
    /// model has, and nothing loose is told at all. Nil for a command that can go anywhere.
    var scope: String?
    /// The design's own devices, each as its name and size, such as `"Kiosk" 1080x1920`, which a screen can be
    /// made as or changed to by name.
    var devices: [String] = []

    static let empty = CanvasPicture()

    var hasScreens: Bool { !screens.isEmpty }

    // MARK: In words

    func text(_ detail: Detail) -> String {
        guard hasScreens || !loose.isEmpty || !devices.isEmpty else { return "The canvas has no screens yet." }
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
                if !isBrief { Self.tell(screen.elements, indent: "  ", into: &lines) }
            }
        } else {
            lines.append("The canvas has no screens yet.")
        }
        // A change for one screen can't touch what is loose, so it isn't told of it.
        if !loose.isEmpty, scope == nil {
            lines.append("Loose on the canvas:")
            Self.tell(loose, indent: "  ", into: &lines)
        }
        if !devices.isEmpty { lines.append("This design's own devices: \(devices.joined(separator: ", ")).") }
        if let scope { lines.append(Self.alone(scope)) }
        return lines.joined(separator: "\n")
    }

    /// The last line told of a change for one screen. The rules, the same for every command
    /// so that a model can keep them read, tell it to make a screen when one is asked for:
    /// here it can't, and isn't handed the tool to.
    static func alone(_ handle: String) -> String {
        "This change is for \(handle) alone: no new screen can be made and nothing elsewhere can change; if one is asked for, call no tool and say it can't be done here."
    }

    /// The screen the person is most likely talking about: the one selected or holding the
    /// selection, at any depth, which the pencil points at, or else the one mostly in view, or
    /// else the newest. Pointed at, a screen not mostly in view must still be told in full.
    private var focusedScreen: String? {
        if let selected = screens.first(where: { $0.isSelected || Self.everything(in: $0.elements).contains(where: \.isSelected) }) {
            return selected.handle
        }
        if let inView = screens.filter({ $0.visibleShare > 0.3 }).max(by: { $0.visibleShare < $1.visibleShare }) {
            return inView.handle
        }
        return screens.last?.handle
    }

    /// What is selected, in words a model can't mistake, such as `E42, the button "Save" on
    /// S3`, or `E2, the card on S1` for a container selected itself; nil when nothing is.
    var selectionInWords: String? {
        var things: [String] = []
        for screen in screens {
            if screen.isSelected { things.append(Self.words(for: screen)) }
            for element in Self.everything(in: screen.elements) where element.isSelected {
                things.append(Self.words(for: element) + " on \(screen.handle)")
            }
        }
        things += Self.everything(in: loose).filter(\.isSelected).map(Self.words(for:))
        return things.isEmpty ? nil : things.joined(separator: "; ")
    }

    /// A screen in words a model can't mistake, such as `S1, the screen "Login"`; nil for a
    /// handle that names none of these.
    func screenInWords(_ handle: String) -> String? {
        screens.first { $0.handle == handle }.map(Self.words(for:))
    }

    /// Every element at any depth, each before what it holds, in the order they are told.
    private static func everything(in elements: [Element]) -> [Element] {
        elements.flatMap { [$0] + everything(in: $0.children) }
    }

    private static func words(for screen: Screen) -> String {
        "\(screen.handle), the screen \"\(screen.name)\""
    }

    private static func words(for element: Element) -> String {
        let text = element.text.replacingOccurrences(of: "\n", with: " ")
        guard !text.isEmpty else { return "\(element.handle), the \(noun(for: element))" }
        return "\(element.handle), the \(noun(for: element)) \"\(text.count > 48 ? text.prefix(45) + "…" : text)\""
    }

    /// What a thing is called: its kind, or for a group what its layout makes it, as its line and the Layers panel call
    /// it: `row`, `column`, `grid` or `overlay`, and `group` when it is free. A card is a card, whatever its layout.
    private static func noun(for element: Element) -> String {
        guard element.isContainer, element.kind == "group", let layout = element.layout,
              let first = layout.split(whereSeparator: { $0 == " " || $0 == "," }).first else { return element.kind }
        return String(first)
    }

    /// Each element's line at `indent`, and what a container holds under it, two spaces further in.
    private static func tell(_ elements: [Element], indent: String, into lines: inout [String]) {
        for element in elements {
            lines.append(indent + line(for: element))
            tell(element.children, indent: indent + "  ", into: &lines)
        }
    }

    private static func line(for screen: Screen, isBrief: Bool) -> String {
        var line = "\(screen.handle) \"\(screen.name)\" \(number(screen.size.width))x\(number(screen.size.height))"
        if let layout = screen.layout { line += " \(layout)" }
        if screen.visibleShare > 0.3 { line += " [in view]" }
        if screen.isSelected { line += " [selected]" }
        if screen.isLocked { line += " [locked]" }
        if isBrief {
            // What it holds by its leaves: the things on it a person would count.
            let count = everything(in: screen.elements).filter { !$0.isContainer }.count
            line += ", \(count == 1 ? "1 element" : "\(count) elements")"
        } else if screen.elements.isEmpty {
            line += ", empty"
        }
        return line
    }

    /// A leaf's line; a container's is its handle, its kind in words, its frame and flags as a leaf's, and then `:`
    /// for what it holds, told under it, or `, empty` when it holds nothing told.
    private static func line(for element: Element) -> String {
        var parts = [element.handle, element.isContainer ? kindWords(for: element) : element.kind]
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
        let line = parts.joined(separator: " ")
        guard element.isContainer else { return line }
        return line + (element.children.isEmpty ? ", empty" : ":")
    }

    /// A group is what its layout makes it, such as `row, spacing 12`, or `group` when free; a card stays a card,
    /// with its layout after it when it has one: `card, column, spacing 8`.
    private static func kindWords(for element: Element) -> String {
        guard let layout = element.layout else { return element.kind }
        return element.kind == "group" ? layout : "\(element.kind), \(layout)"
    }

    /// To the whole point. What isn't a number is told as 0, and what is past any design's length as the farthest
    /// one told, so that no number traps: a picture `capture` makes holds screen sizes in whole points already.
    private static func number(_ value: CGFloat) -> String {
        guard value.isFinite else { return "0" }
        return String(Int(min(max(value.rounded(), -farthest), farthest)))
    }

    private static let farthest: CGFloat = 1_000_000_000_000
}
