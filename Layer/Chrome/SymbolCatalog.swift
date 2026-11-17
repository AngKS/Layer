import Foundation

/// The SF Symbols the library's Icons tab offers, grouped the way people look for them.
/// Any other symbol can still be placed by typing its exact name: see `AssetLibrary`.
///
/// iOS has no way to list every SF Symbol, so this is a hand-picked set of the ones that
/// turn up in app wireframes. A test checks that every name here is a real symbol.
enum SymbolCatalog {
    struct Category: Identifiable, Sendable {
        let name: String
        let symbols: [String]
        var id: String { name }
    }

    static let categories: [Category] = [
        Category(name: "Interface", symbols: [
            "house", "house.fill", "magnifyingglass", "gearshape", "gearshape.fill", "bell", "bell.fill",
            "person", "person.fill", "person.2", "person.crop.circle", "line.3.horizontal", "ellipsis",
            "ellipsis.circle", "plus", "plus.circle.fill", "minus", "xmark", "xmark.circle.fill", "checkmark",
            "checkmark.circle.fill", "slider.horizontal.3", "square.grid.2x2", "list.bullet", "bookmark",
            "bookmark.fill", "tag", "flag", "pin", "trash", "pencil", "square.and.pencil", "square.and.arrow.up",
            "square.and.arrow.down", "doc", "doc.text", "folder", "tray", "paperclip", "link", "lock",
            "lock.open", "key", "eye", "eye.slash", "info.circle", "questionmark.circle", "exclamationmark.triangle",
        ]),
        Category(name: "Arrows", symbols: [
            "chevron.left", "chevron.right", "chevron.up", "chevron.down", "arrow.left", "arrow.right",
            "arrow.up", "arrow.down", "arrow.up.right", "arrow.clockwise", "arrow.counterclockwise",
            "arrow.triangle.2.circlepath", "arrow.up.arrow.down", "arrow.left.arrow.right", "arrow.uturn.backward",
            "arrow.down.circle", "arrow.up.circle.fill", "chevron.left.forwardslash.chevron.right",
        ]),
        Category(name: "Communication", symbols: [
            "message", "message.fill", "bubble.left", "bubble.left.and.bubble.right", "phone", "phone.fill",
            "video", "envelope", "envelope.fill", "paperplane", "paperplane.fill", "mic", "mic.fill",
            "speaker.wave.2", "megaphone", "at", "globe", "wifi", "antenna.radiowaves.left.and.right",
        ]),
        Category(name: "Media", symbols: [
            "play.fill", "pause.fill", "stop.fill", "forward.fill", "backward.fill", "play.circle", "photo",
            "photo.on.rectangle", "camera", "camera.fill", "film", "music.note", "headphones", "tv", "waveform",
            "speaker.slash", "repeat", "shuffle",
        ]),
        Category(name: "Commerce", symbols: [
            "cart", "cart.fill", "bag", "creditcard", "giftcard", "banknote", "dollarsign.circle", "percent",
            "shippingbox", "barcode", "qrcode", "storefront", "wallet.pass", "chart.bar", "chart.pie",
            "chart.line.uptrend.xyaxis",
        ]),
        Category(name: "Favourites and Feedback", symbols: [
            "heart", "heart.fill", "star", "star.fill", "hand.thumbsup", "hand.thumbsdown", "face.smiling",
            "sparkles", "bolt", "bolt.fill", "flame", "crown", "trophy", "medal", "rosette", "gift",
        ]),
        Category(name: "Time and Place", symbols: [
            "clock", "alarm", "timer", "calendar", "hourglass", "map", "mappin", "mappin.and.ellipse",
            "location", "location.fill", "safari", "airplane", "car", "bus", "tram", "bicycle", "figure.walk",
            "building.2",
        ]),
        Category(name: "Weather and Nature", symbols: [
            "sun.max", "moon", "cloud", "cloud.rain", "cloud.bolt", "snowflake", "wind", "drop", "leaf", "tree",
            "pawprint", "mountain.2", "thermometer.medium", "umbrella", "rainbow",
        ]),
        Category(name: "Devices", symbols: [
            "iphone", "ipad", "laptopcomputer", "desktopcomputer", "applewatch", "keyboard", "printer",
            "battery.100", "externaldrive", "server.rack", "cpu", "lightbulb", "power",
        ]),
        Category(name: "Health and Living", symbols: [
            "heart.text.square", "cross.case", "pills", "bandage", "stethoscope", "figure.run", "bed.double",
            "fork.knife", "cup.and.saucer", "dumbbell",
        ]),
    ]

    /// The categories narrowed to symbols whose names contain every word of the search.
    static func matching(_ search: String) -> [Category] {
        let words = search.lowercased().split(whereSeparator: { $0 == " " || $0 == "." }).map(String.init)
        guard !words.isEmpty else { return categories }
        return categories.compactMap { category in
            let symbols = category.symbols.filter { name in words.allSatisfy(name.contains) }
            return symbols.isEmpty ? nil : Category(name: category.name, symbols: symbols)
        }
    }
}
