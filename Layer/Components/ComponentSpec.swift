import CoreGraphics

/// What Layer knows about one kind of element, apart from how it is drawn and how it is
/// written out as code: what it is called, how large it starts, where a sketch of it is
/// put, how it usually looks, and which settings it has. Each kind has one entry in
/// `Catalogue`, and the rest of the app asks the catalogue rather than deciding kind by
/// kind.
struct ComponentSpec: Sendable {
    // MARK: Names

    /// The name shown in the Layers panel and used in generated code.
    var name: String
    /// The SF Symbol that stands for it in lists.
    var symbol: String
    /// The copy a new one starts with. Empty for kinds that show no words.
    var placeholder = ""
    /// The name it goes by in prompts to models, and in their answers.
    var promptName: String
    /// The words people use for it when a screen is written out, as Shortcuts and
    /// generated screens do.
    var writtenNames: [String]
    /// What designers usually mean when they sketch it, for a model choosing between
    /// readings of a close call (`SketchPrompt`). Nil for kinds the shape rules never
    /// offer as a close call. Sizes come from `SketchConventions`, so the model and the
    /// rules draw the same lines.
    var sketchHint: String? = nil

    // MARK: Where it goes

    /// Whether it can join a screen. Notes about a design stay on the open canvas.
    var belongsOnScreens = true
    /// Whether a drawing on a screen can be asked to become one.
    var isAskedForOnScreens = true

    // MARK: Size

    /// The size it starts at, on the standard phone.
    var size: Size
    /// What one sketched on the open canvas takes from the size it was drawn.
    var looseSize = LooseSize.usual
    /// The least it can be resized to.
    var minimumSize = CGSize(width: 32, height: 16)
    /// Whether its height is fixed, so that resizing changes only its width.
    var hasFixedHeight = false
    /// Whether resizing keeps it as wide as it is tall.
    var staysSquare = false

    // MARK: Placement

    /// Whether it usually runs across the screen, and keeps its side margins on wider
    /// and narrower devices.
    var runsAcross = false
    /// Whether it stays where it was drawn across the screen. The rest are centred.
    var keepsSketchedPosition = false
    /// What a sketch of it says about its frame, beyond where it was drawn.
    var sketchFit = SketchFit.standard
    /// Whether it fills the width it is given in a written or generated screen.
    var fillsWrittenWidth = false

    // MARK: Look

    /// The colour a new one starts with.
    var tint = Theme.accent
    var fontSize = FontSize.points(17)
    var fontWeight = FontWeightChoice.regular
    var textColour = TextColour.colour(Theme.inkTint)
    var cornerRadius = Radius.none
    var textAlignment = TextAlignmentChoice.leading
    /// Whether it can be made see-through and given a shadow. Ink can't: PencilKit draws it.
    var hasEffects = true
    /// The settings it has.
    var traits: Traits = [.border]
    /// What its being switched on is called in the format panel.
    var onName: String? = nil
    /// What the marks drawn inside a sketch of it say about it.
    var marks: Marks? = nil
}

extension ComponentSpec {
    /// Settings that some kinds have and others don't.
    struct Traits: OptionSet, Sendable {
        let rawValue: Int

        /// It shows its own colour: a button's or sticky note's fill, a symbol's ink.
        static let fill = Traits(rawValue: 1 << 0)
        static let cornerRadius = Traits(rawValue: 1 << 1)
        /// An outline can be drawn round it. Checkboxes and radio buttons draw their own.
        static let border = Traits(rawValue: 1 << 2)
        /// It can be switched on and off.
        static let onState = Traits(rawValue: 1 << 3)
        /// The text inside it can be aligned.
        static let textAlignment = Traits(rawValue: 1 << 4)
        /// It shows an amount, from nothing to all: how full a progress bar is.
        static let value = Traits(rawValue: 1 << 5)
        /// It can be filled, outlined or plain, as a button can.
        static let buttonLooks = Traits(rawValue: 1 << 6)
    }

    enum Size: Sendable {
        case fixed(CGSize)
        /// `width` wide, and as tall as it was drawn: within `height`, to the nearest `step`.
        case tallAsDrawn(width: CGFloat, height: ClosedRange<CGFloat>, step: CGFloat)
        /// As wide as it was drawn and as tall as that: within `side`, to the nearest `step`.
        case squareAsDrawn(side: ClosedRange<CGFloat>, step: CGFloat)

        /// The size for a sketch with these bounds, or for none when they are empty.
        func size(sketched sketch: CGRect) -> CGSize {
            func snapped(_ value: CGFloat, within range: ClosedRange<CGFloat>, to step: CGFloat) -> CGFloat {
                (min(max(value, range.lowerBound), range.upperBound) / step).rounded() * step
            }
            switch self {
            case .fixed(let size):
                return size
            case .tallAsDrawn(let width, let height, let step):
                return CGSize(width: width, height: snapped(sketch.height, within: height, to: step))
            case .squareAsDrawn(let side, let step):
                let side = snapped(sketch.width, within: side, to: step)
                return CGSize(width: side, height: side)
            }
        }
    }

    enum LooseSize: Sendable {
        /// The kind's usual size, however large it was drawn.
        case usual
        /// A square as large as the longer side of the drawing, within these bounds.
        case squareAsDrawn(ClosedRange<CGFloat>)
        /// As wide as the drawing, within these bounds, at its usual height.
        case wideAsDrawn(ClosedRange<CGFloat>)

        func size(from usual: CGSize, drawn: CGSize) -> CGSize {
            switch self {
            case .usual:
                return usual
            case .squareAsDrawn(let range):
                let side = min(max(max(drawn.width, drawn.height), range.lowerBound), range.upperBound).rounded()
                return CGSize(width: side, height: side)
            case .wideAsDrawn(let range):
                return CGSize(width: min(max(drawn.width, range.lowerBound), range.upperBound).rounded(), height: usual.height)
            }
        }
    }

    enum SketchFit: Sendable {
        /// Its usual size, where it was drawn.
        case standard
        /// A line of words: drawn against the leading edge, or beside something on its
        /// left, it is leading-aligned from there. `sizedByHeight` makes a taller
        /// scribble larger text, as with titles.
        case words(sizedByHeight: Bool)
        /// A box that keeps the width it was drawn at when that is clearly narrower than
        /// the screen, down to `narrowest`.
        case box(narrowest: CGFloat)
    }

    enum FontSize: Sendable {
        case points(CGFloat)
        /// This fraction of the element's height, so the text grows and shrinks with its box.
        case ofHeight(CGFloat)

        func points(in frame: CGRect) -> CGFloat {
            switch self {
            case .points(let points): points
            case .ofHeight(let fraction): frame.height * fraction
            }
        }
    }

    enum TextColour: Sendable {
        case colour(RGBColor)
        /// White on its fill; outlined or plain, it shows its own colour in its text.
        case onFill
    }

    enum Radius: Sendable {
        case none
        case points(CGFloat)
        case ofHeight(CGFloat)
        case ofShorterSide(CGFloat)

        func points(in frame: CGRect) -> CGFloat {
            switch self {
            case .none: 0
            case .points(let points): points
            case .ofHeight(let fraction): frame.height * fraction
            case .ofShorterSide(let fraction): min(frame.width, frame.height) * fraction
            }
        }
    }

    enum Marks: Sendable {
        /// A knob drawn inside: on when it is nearer the trailing end.
        case knob
        /// A tick, a cross or a dot inside: on when there is one.
        case mark
        /// Shading inside: full as far as it reaches.
        case shading
    }
}
