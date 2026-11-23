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
}
