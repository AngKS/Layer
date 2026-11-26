/// The SF Symbol drawn for an A2UI icon name.
///
/// The Basic Catalog names its icons as Material Symbols do (`skipNext`, `locationOn`). Each of
/// its 59 names has an SF Symbol here, chosen to look like it; `A2UIImportTests` checks that
/// every one exists. Any other name, such as one read from a data model, goes through Layer's
/// own reading of loosely written symbol names.
enum A2UIIcons {
    static let symbols: [String: String] = [
        "accountCircle": "person.crop.circle",
        "add": "plus",
        "arrowBack": "arrow.left",
        "arrowForward": "arrow.right",
        "attachFile": "paperclip",
        "calendarToday": "calendar",
        "call": "phone",
        "camera": "camera",
        "check": "checkmark",
        "close": "xmark",
        "delete": "trash",
        "download": "arrow.down.to.line",
        "edit": "pencil",
        "event": "calendar.badge.clock",
        "error": "exclamationmark.circle",
        "fastForward": "forward.fill",
        "favorite": "heart.fill",
        "favoriteOff": "heart.slash",
        "folder": "folder",
        "help": "questionmark.circle",
        "home": "house",
        "info": "info.circle",
        "locationOn": "mappin.and.ellipse",
        "lock": "lock",
        "lockOpen": "lock.open",
        "mail": "envelope",
        "menu": "line.3.horizontal",
        // SF Symbols has no plain vertical ellipsis.
        "moreVert": "ellipsis",
        "moreHoriz": "ellipsis",
        "notificationsOff": "bell.slash",
        "notifications": "bell",
        "pause": "pause.fill",
        "payment": "creditcard",
        "person": "person",
        "phone": "phone",
        "photo": "photo",
        "play": "play.fill",
        "print": "printer",
        "refresh": "arrow.clockwise",
        "rewind": "backward.fill",
        "search": "magnifyingglass",
        "send": "paperplane",
        "settings": "gearshape",
        "share": "square.and.arrow.up",
        "shoppingCart": "cart",
        "skipNext": "forward.end.fill",
        "skipPrevious": "backward.end.fill",
        "star": "star.fill",
        "starHalf": "star.leadinghalf.filled",
        "starOff": "star.slash",
        "stop": "stop.fill",
        "upload": "arrow.up.to.line",
        "visibility": "eye",
        "visibilityOff": "eye.slash",
        "volumeDown": "speaker.wave.1",
        "volumeMute": "speaker",
        "volumeOff": "speaker.slash",
        "volumeUp": "speaker.wave.3",
        "warning": "exclamationmark.triangle",
    ]

    /// The SF Symbol for `a2uiName`: the table's, else whatever Layer makes of the name,
    /// which may be the placeholder.
    static func symbol(for a2uiName: String) -> String {
        symbols[a2uiName] ?? SystemSymbol.resolve(a2uiName)
    }

    // MARK: A model's icons

    /// What a model meant by an icon's name.
    enum Meant: Equatable, Sendable {
        /// An A2UI icon, by A2UI's own name.
        case icon(String)
        /// Layer's own symbol (`LayerSymbol`), by the name as the model wrote it.
        case symbol(String)
    }

    /// What a model meant by an `Icon` it named `name`, since models name icons as they know them. One of A2UI's names
    /// is that icon. One with the same letters as an A2UI name, as Material spells it (`arrow_back`) or in other
    /// capitals or with hyphens or spaces, is that A2UI icon. Any other, such as an SF Symbol's name (`chevron.right`)
    /// or a word of the model's own, is Layer's own symbol by that name: drawn as an outline's `symbol:` line is, the
    /// SF Symbol if there is one, else what `SystemSymbol` makes of the name, which may be the placeholder.
    ///
    /// Only a model's answer is read this way (`A2UIStream`): A2UI from a file or a paste is someone's own, and its
    /// import says what in it isn't A2UI's.
    static func meant(byIconNamed name: String) -> Meant {
        if symbols[name] != nil { return .icon(name) }
        if let a2uiName = byLetters[letters(of: name)] { return .icon(a2uiName) }
        return .symbol(name)
    }

    /// A2UI's names by their letters (`letters(of:)`). No two of them share their letters.
    private static let byLetters: [String: String] = Dictionary(uniqueKeysWithValues: symbols.keys.map { (letters(of: $0), $0) })

    /// A name lowercased, without its underscores, hyphens and spaces: `arrow_back`, `Arrow-Back` and `arrowBack` are
    /// all `arrowback`.
    private static func letters(of name: String) -> String {
        String(name.lowercased().filter { $0 != "_" && $0 != "-" && !$0.isWhitespace })
    }
}
