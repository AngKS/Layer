import Synchronization
import UIKit

/// The SF Symbol drawn for an icon's name. A model names icons loosely, "arrow down",
/// "Email" or "GitHub", and a name the system doesn't know is drawn as nothing at all.
///
/// An element keeps the name it was given, so that a later model or system can still make
/// something of it. Only what is drawn, on the canvas, in the layers list and in the
/// design's code, is the symbol found here.
enum SystemSymbol {
    /// Drawn for a name nothing else fits: a dashed square, where an icon goes.
    static let placeholder = "square.dashed"

    /// The symbol to draw for `name`: the name itself if the system has it; or the name
    /// spelled as symbols are, "arrow.down" for "arrow down"; or the symbol for a word in
    /// it, an envelope for "Email"; or the placeholder. Remembered, since views ask for it
    /// each time they are drawn.
    static func resolve(_ name: String) -> String {
        if let found = found.withLock({ $0[name] }) { return found }
        let symbol = find(name)
        found.withLock { $0[name] = symbol }
        return symbol
    }

    /// The symbol each name asked about resolved to.
    private static let found = Mutex<[String: String]>([:])

    private static func find(_ name: String) -> String {
        if exists(name) { return name }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = spelled(trimmed)
        if exists(plain) { return plain }
        // "arrowDown" is "arrow.down", and "GitHub" is "git.hub", joined again below.
        let parts = spelled(splittingWords(trimmed)).split(separator: ".").map(String.init)
        // Words left over at the end, as in "heart.outline" or "arrow.left.icon", are dropped.
        for count in stride(from: parts.count, to: 0, by: -1) {
            let shorter = parts.prefix(count).joined(separator: ".")
            if exists(shorter) { return shorter }
        }
        // The whole name as one word, as brands are written, and then each word in it.
        for word in [parts.joined()] + parts {
            if let symbol = words[word] { return symbol }
        }
        return placeholder
    }

    private static func exists(_ name: String) -> Bool {
        !name.isEmpty && UIImage(systemName: name) != nil
    }

    /// Lowercased, with spaces, underscores and hyphens as the dots symbols have between words.
    private static func spelled(_ name: String) -> String {
        let dotted = String(name.lowercased().map { $0.isWhitespace || $0 == "_" || $0 == "-" ? "." : $0 })
        return dotted.split(separator: ".").joined(separator: ".")
    }

    /// A dot wherever a capital follows a small letter.
    private static func splittingWords(_ name: String) -> String {
        var split = ""
        var previous: Character?
        for character in name {
            if character.isUppercase, previous?.isLowercase == true { split.append(".") }
            split.append(character)
            previous = character
        }
        return split
    }

    /// Words a model uses for an icon, and the symbol drawn for each. A brand has no symbol
    /// of its own, Apple's apart, so its icon is a link: what it usually stands for is a
    /// profile somewhere else.
    static let words: [String: String] = {
        let groups: [(symbol: String, words: [String])] = [
            ("envelope", ["email", "mail", "inbox"]),
            ("phone", ["phone", "call", "telephone", "tel", "mobile"]),
            ("magnifyingglass", ["search", "find", "lookup"]),
            ("gearshape", ["settings", "setting", "gear", "cog", "preferences", "config"]),
            ("person.crop.circle", ["profile", "user", "account", "avatar", "person"]),
            ("house", ["home"]),
            ("chevron.left", ["back", "previous", "prev"]),
            ("chevron.right", ["next", "forward", "chevron", "disclosure"]),
            ("arrow.right", ["arrow"]),
            ("chevron.down", ["down", "dropdown", "expand"]),
            ("chevron.up", ["up", "collapse"]),
            ("line.3.horizontal", ["menu", "hamburger", "burger", "nav"]),
            ("xmark", ["close", "dismiss", "cancel", "exit", "x"]),
            ("plus", ["add", "plus", "new", "create"]),
            ("heart", ["heart", "like", "love", "favorite", "favourite"]),
            ("square.and.arrow.up", ["share"]),
            ("cart", ["cart", "basket", "shopping", "shop", "checkout"]),
            ("calendar", ["calendar", "date", "schedule", "event"]),
            ("mappin.and.ellipse", ["location", "map", "address", "place", "pin", "gps"]),
            ("link", ["link", "url", "hyperlink"]),
            ("globe", ["web", "website", "internet", "browser", "www", "site", "language"]),
            ("bell", ["notification", "notifications", "alert", "alerts", "bell"]),
            ("message", ["chat", "message", "messages", "comment", "comments", "sms"]),
            ("pencil", ["edit", "write", "compose"]),
            ("trash", ["delete", "remove", "bin", "trash"]),
            ("arrow.down.circle", ["download"]),
            ("arrow.up.circle", ["upload"]),
            ("star", ["star", "rating", "rate"]),
            ("photo", ["image", "photo", "picture", "gallery", "img"]),
            ("play.fill", ["play"]),
            ("info.circle", ["info", "information", "about"]),
            ("questionmark.circle", ["help", "support", "faq", "question"]),
            ("lock", ["lock", "password", "secure", "security"]),
            ("rectangle.portrait.and.arrow.right", ["logout", "signout"]),
            ("line.3.horizontal.decrease", ["filter", "filters"]),
            ("ellipsis", ["more", "options", "dots", "overflow", "kebab"]),
            ("checkmark", ["check", "done", "tick", "ok", "success"]),
            ("arrow.clockwise", ["refresh", "reload", "retry"]),
            ("music.note", ["music", "song", "audio"]),
            ("creditcard", ["card", "payment", "pay", "wallet", "billing"]),
            ("clock", ["time", "clock", "history"]),
            ("paperplane", ["send"]),
            ("mic", ["mic", "microphone", "voice"]),
            ("bookmark", ["bookmark", "save", "saved"]),
            ("apple.logo", ["apple"]),
            ("link", [
                "github", "gitlab", "bitbucket", "linkedin", "dribbble", "dribble", "behance", "twitter",
                "xtwitter", "xlogo", "xcom", "facebook", "fb", "instagram", "insta", "youtube", "tiktok",
                "pinterest", "reddit", "discord", "slack", "whatsapp", "telegram", "snapchat", "medium",
                "figma", "google", "spotify", "twitch", "threads", "mastodon", "bluesky", "stackoverflow",
                "producthunt", "substack", "patreon", "paypal", "messenger", "wechat",
            ]),
        ]
        var words: [String: String] = [:]
        for group in groups {
            for word in group.words {
                assert(words[word] == nil, "\(word) is given two symbols")
                words[word] = group.symbol
            }
        }
        return words
    }()
}
