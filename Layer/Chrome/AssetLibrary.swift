import os
import SwiftUI
import UIKit

/// The library's tabs, in the order they're shown.
enum AssetTab: String, CaseIterable, Identifiable, Sendable {
    case icons, wireframes, shapes, components

    var id: Self { self }

    var title: String {
        switch self {
        case .icons: "Icons"
        case .wireframes: "Wireframes"
        case .shapes: "Shapes"
        case .components: "Components"
        }
    }
}

/// One thing in the library that can be put on the canvas, by tapping it or dragging it there.
struct Asset: Identifiable, Hashable, Sendable {
    enum Content: Hashable, Sendable {
        /// An SF Symbol, by name.
        case symbol(String)
        case shape(ShapeKind, filled: Bool)
        /// One of `AssetLibrary.components`, by id.
        case component(String)
        /// An empty screen of a device, by the device's id.
        case frame(String)
        /// A ready-made screen: one of `ScreenPrompt.library`, by name.
        case template(String)
    }

    let content: Content
    let name: String
    let tab: AssetTab
    /// The heading it is listed under in its tab.
    let section: String
    /// Lower-case words a search finds it by: its name's words and other words for it.
    let terms: [String]
    /// The words of its name, split once rather than on every search.
    let nameWords: [String]

    init(content: Content, name: String, tab: AssetTab, section: String, terms: [String]) {
        self.content = content
        self.name = name
        self.tab = tab
        self.section = section
        self.terms = terms
        nameWords = AssetLibrary.words(in: name)
    }

    /// What a drag carries, and what the canvas reads back when it is dropped.
    var id: String {
        switch content {
        case .symbol(let name): "symbol:\(name)"
        case .shape(let kind, let filled): "shape:\(kind.rawValue):\(filled ? "fill" : "line")"
        case .component(let id): "component:\(id)"
        case .frame(let id): "frame:\(id)"
        case .template(let name): "template:\(name)"
        }
    }

    /// The name VoiceOver reads, and UI tests look for. A symbol goes by its own name.
    var accessibilityName: String {
        switch content {
        case .symbol(let name): name
        case .frame(let id):
            DeviceFrame.all.first { $0.id == id }.map { "\($0.name)  \(Int($0.size.width)) × \(Int($0.size.height))" } ?? name
        default: name
        }
    }
}

/// Everything the library offers, and finding things in it.
enum AssetLibrary {
    // MARK: Components

    struct Component: Sendable {
        let id: String
        let name: String
        let section: String
        let keywords: [String]
        let kind: ElementKind
        /// The element's words, when not the kind's usual ones.
        var text: String? = nil
        var buttonLook: ButtonLook? = nil
        var isOn: Bool? = nil
        var cornerRadius: CGFloat? = nil
    }

    static let components: [Component] = [
        Component(id: "title", name: "Title", section: "Text", keywords: ["heading", "header", "headline"], kind: .title),
        Component(id: "body", name: "Body Text", section: "Text", keywords: ["paragraph", "description", "copy", "subtitle"], kind: .body),
        Component(id: "label", name: "Label", section: "Text", keywords: ["text", "caption"], kind: .text, text: "Label"),
        Component(id: "button", name: "Button", section: "Buttons", keywords: ["primary", "cta", "action", "filled"], kind: .button),
        Component(id: "button.bordered", name: "Secondary Button", section: "Buttons", keywords: ["bordered", "outlined", "outline", "cancel"],
                  kind: .button, text: "Cancel", buttonLook: .bordered),
        Component(id: "button.plain", name: "Link Button", section: "Buttons", keywords: ["plain", "link", "text button", "tertiary"],
                  kind: .button, text: "Learn more", buttonLook: .plain),
        Component(id: "textField", name: "Text Field", section: "Inputs", keywords: ["input", "field", "form", "email", "textbox"],
                  kind: .textField, text: "Email"),
        Component(id: "searchField", name: "Search Field", section: "Inputs", keywords: ["search", "find", "input", "field"],
                  kind: .textField, text: "Search", cornerRadius: 24),
        Component(id: "toggle", name: "Toggle", section: "Controls", keywords: ["switch", "on", "off", "setting"], kind: .toggle),
        Component(id: "checkbox", name: "Checkbox", section: "Controls", keywords: ["check", "tick", "box", "agree"], kind: .checkbox),
        Component(id: "radio", name: "Radio Button", section: "Controls", keywords: ["option", "choice", "select"], kind: .radio),
        Component(id: "progress", name: "Progress Bar", section: "Controls", keywords: ["loading", "bar", "percent", "meter"], kind: .progress),
        Component(id: "divider", name: "Divider", section: "Controls", keywords: ["separator", "line", "rule", "hr"], kind: .divider),
        Component(id: "image", name: "Image", section: "Media", keywords: ["photo", "picture", "hero", "banner", "placeholder"], kind: .image),
        Component(id: "avatar", name: "Avatar", section: "Media", keywords: ["profile", "user", "person", "photo"], kind: .avatar),
        Component(id: "stickyNote", name: "Sticky Note", section: "Notes", keywords: ["note", "comment", "annotation", "post-it"], kind: .stickyNote),
    ]

    /// A new element for a component, at its usual size and look.
    static func element(forComponent id: String) -> DesignElement? {
        guard let component = components.first(where: { $0.id == id }) else { return nil }
        var element = DesignStore.newElement(component.kind)
        if let text = component.text { element.text = text }
        if let look = component.buttonLook { element.buttonLook = look }
        if let isOn = component.isOn { element.isOn = isOn }
        if let radius = component.cornerRadius { element.cornerRadius = radius }
        return element
    }

    // MARK: Wireframes

    /// The ready-made screens, by the names they are listed under.
    static let templates: [(name: String, example: String)] = [
        ("Sign In", "sign in"), ("Settings", "settings"), ("Profile", "profile"),
        ("Product", "product"), ("Form", "form"), ("Empty State", "empty"),
    ]

    /// A library screen as an outline root, with its rows, cards and grids, spaced and padded by `tokens`: a design's
    /// own when it goes on the design, the standard ones for its thumbnail. Every node's source is `.template`.
    static func template(named name: String, tokens: DesignTokens = .standard) -> LayerNode? {
        guard let example = templates.first(where: { $0.name == name })?.example,
              let lines = ScreenPrompt.library.first(where: { $0.name == example })?.lines
        else { return nil }
        var root = Outline.parse(lines, isComplete: true, tokens: tokens)
        markAsTemplate(&root)
        return root
    }

    private static func markAsTemplate(_ node: inout LayerNode) {
        node.source = LayerNode.Source(origin: .template, key: node.source?.key)
        for index in node.children.indices { markAsTemplate(&node.children[index]) }
    }

    // MARK: Everything

    static let all: [Asset] = icons + wireframes + shapes + componentAssets

    private static let byID: [String: Asset] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    /// Each tab's assets, in order.
    private static let byTab: [AssetTab: [Asset]] = Dictionary(grouping: all, by: \.tab)

    private static func assets(in tab: AssetTab) -> [Asset] { byTab[tab] ?? [] }

    /// The asset a drag carried, from its id. A symbol that isn't in the catalogue is still
    /// one, as long as SF Symbols has it.
    static func asset(id: String) -> Asset? {
        if let known = byID[id] { return known }
        if id.hasPrefix("symbol:") { return customSymbol(String(id.dropFirst("symbol:".count))) }
        return nil
    }

    /// Any SF Symbol, by its exact name: the catalogue is a hand-picked few of thousands.
    static func customSymbol(_ name: String) -> Asset? {
        let name = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty, !name.contains(" "), UIImage(systemName: name) != nil else { return nil }
        return Asset(content: .symbol(name), name: name, tab: .icons, section: "SF Symbols", terms: words(in: name))
    }

    private static let icons: [Asset] = SymbolCatalog.categories.flatMap { category in
        category.symbols.map { symbol in
            Asset(content: .symbol(symbol), name: symbol, tab: .icons, section: category.name,
                  terms: words(in: symbol) + (iconSynonyms[symbol] ?? []))
        }
    }

    private static let wireframes: [Asset] = DeviceFrame.all.map { device in
        Asset(content: .frame(device.id), name: device.name, tab: .wireframes, section: device.family.name,
              terms: words(in: device.name) + familyWords[device.family, default: []] + ["frame", "device", "screen", "blank", "empty", "artboard"])
    } + templates.map { template in
        Asset(content: .template(template.name), name: template.name, tab: .wireframes, section: "Screens",
              terms: words(in: template.name) + ["screen", "template", "page"] + (ScreenPrompt.library.first { $0.name == template.example }?.keywords ?? []))
    }

    private static let familyWords: [DeviceFrame.Family: [String]] = [
        .phone: ["phone", "mobile", "ios"],
        .tablet: ["tablet", "ipados"],
        .desktop: ["desktop", "mac", "laptop", "computer", "macos", "web", "window"],
    ]

    private static let shapes: [Asset] = [true, false].flatMap { filled in
        ShapeKind.allCases.map { kind in
            Asset(content: .shape(kind, filled: filled), name: filled ? kind.name : "\(kind.name) Outline", tab: .shapes,
                  section: filled ? "Filled" : "Outlined",
                  terms: words(in: kind.name) + kind.keywords + ["shape", filled ? "filled" : "outline", filled ? "solid" : "stroke"])
        }
    }

    private static let componentAssets: [Asset] = components.map { component in
        Asset(content: .component(component.id), name: component.name, tab: .components, section: component.section,
              terms: words(in: component.name) + component.keywords.flatMap(words(in:)) + ["component", "control"])
    }

    // MARK: Searching

    static func words(in text: String) -> [String] {
        text.lowercased().split(whereSeparator: { " .-_,/".contains($0) }).map(String.init)
    }

    /// The assets in `tab` that match `search`, best first: every word searched for must
    /// start one of an asset's words. A word that is a whole word of its name counts for
    /// most. With nothing searched, everything in the tab, in order.
    static func matching(_ search: String, in tab: AssetTab) -> [Asset] {
        guard !words(in: search).isEmpty else { return assets(in: tab) }
        return matching(search, in: tab, scored: scored(search, among: assets(in: tab)), exactSymbol: tab == .icons ? customSymbol(search) : nil)
    }

    private static func matching(_ search: String, in tab: AssetTab, scored: [(asset: Asset, score: Int)], exactSymbol: Asset?) -> [Asset] {
        var found = scored.map(\.asset)
        // A symbol named exactly, from beyond the catalogue, comes first.
        if tab == .icons, let exact = exactSymbol, !found.contains(where: { $0.id == exact.id }) {
            found.insert(exact, at: 0)
        }
        return found
    }

    /// The tab whose best match for `search` is the strongest: "toggle" means the
    /// component, not the settings screen that has toggles on it. Nil when nothing
    /// anywhere matches.
    static func bestTab(for search: String) -> AssetTab? {
        bestMatch(for: search)?.tab
    }

    /// The strongest score `search` has in `tab`, or nil when nothing there matches.
    static func topScore(for search: String, in tab: AssetTab) -> Int? {
        scored(search, among: assets(in: tab)).first?.score
    }

    static func bestMatch(for search: String) -> (tab: AssetTab, score: Int)? {
        var best = AssetTab.allCases
            .compactMap { tab in scored(search, among: assets(in: tab)).first.map { (tab: tab, score: $0.score) } }
        // A symbol's exact name: certain when it is dotted, as in cloud.sun.rain; a plain
        // word such as "hexagon" is a symbol too, but more likely means the shape.
        if customSymbol(search) != nil {
            best.append((.icons, search.contains(".") ? 10_000 : 250))
        }
        return best.max { $0.score < $1.score }
    }

    /// One tab's share of a search.
    struct ResultGroup: Equatable {
        let tab: AssetTab
        let assets: [Asset]
    }

    /// What `search` finds in every tab at once, the tab with the strongest match first:
    /// "mac" is an icon and a family of wireframes, and the library shows both. Tabs that
    /// find nothing are left out.
    static func searchEverywhere(_ search: String) -> [ResultGroup] {
        guard !words(in: search).isEmpty else { return [] }
        // Looked up once: asking SF Symbols for a name loads its image.
        let exactSymbol = customSymbol(search)
        let groups: [(group: ResultGroup, score: Int)] = AssetTab.allCases.compactMap { tab in
            // Each tab is scored once, for both what it finds and how well.
            let scored = scored(search, among: assets(in: tab))
            let assets = matching(search, in: tab, scored: scored, exactSymbol: exactSymbol)
            guard !assets.isEmpty else { return nil }
            var score = scored.first?.score ?? 0
            // The exact symbol counts as the Icons group's score, as `bestMatch` scores it.
            if tab == .icons, exactSymbol != nil {
                score = max(score, search.contains(".") ? 10_000 : 250)
            }
            return (ResultGroup(tab: tab, assets: assets), score)
        }
        // A stable sort: tabs with equal scores stay in the order the tabs are shown.
        return groups.enumerated()
            .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            .map(\.element.group)
    }

    /// Whether a search is worth offering to write a screen for: it has words, and nothing
    /// in the library answers it.
    static func offersGeneration(for search: String) -> Bool {
        !words(in: search).isEmpty && searchEverywhere(search).isEmpty
    }

    /// What Return in the search field does.
    enum SubmitAction: Equatable {
        /// Puts the best match on the canvas.
        case place(Asset)
        /// Writes the screen the words describe.
        case generate(String)
        case nothing
    }

    /// Return places the best match; when nothing matches, it writes the screen the words
    /// describe, where the library can, and not while a screen is already being written.
    static func submitAction(for search: String, firstResult: Asset?, canGenerate: Bool, isGenerating: Bool) -> SubmitAction {
        if let firstResult { return .place(firstResult) }
        guard canGenerate, !words(in: search).isEmpty, !isGenerating else { return .nothing }
        return .generate(search.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// What the library lists: a search's finds from every tab, or the open tab's things.
    enum Listing: Equatable {
        case searchResults
        case tab(AssetTab)
    }

    /// A search doesn't change the open tab, so clearing it lists that tab again.
    static func listing(for search: String, openTab: AssetTab) -> Listing {
        words(in: search).isEmpty ? .tab(openTab) : .searchResults
    }

    /// The assets among `candidates` that match `search`, scored and best first.
    private static func scored(_ search: String, among candidates: [Asset]) -> [(asset: Asset, score: Int)] {
        let query = words(in: search)
        var scored: [(asset: Asset, score: Int, index: Int)] = []
        for (index, asset) in candidates.enumerated() {
            let nameWords = asset.nameWords
            var score = 0
            var matchesAll = true
            for word in query {
                if nameWords.contains(word) { score += 4 }
                else if asset.terms.contains(word) { score += 3 }
                else if nameWords.contains(where: { $0.hasPrefix(word) }) { score += 2 }
                else if asset.terms.contains(where: { $0.hasPrefix(word) }) { score += 1 }
                else { matchesAll = false; break }
            }
            guard matchesAll else { continue }
            // Shorter names are the plainer match: "heart" before "heart.text.square".
            score = score * 100 - nameWords.count
            scored.append((asset, score, index))
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }.map { ($0.asset, $0.score) }
    }

    // MARK: Recently used

    static let recentsKey = "assetLibrary.recents"
    static let recentsLimit = 12

    /// Notes that an asset was used, so it leads its tab next time.
    static func noteUsed(_ asset: Asset, in defaults: UserDefaults = AppSettings.defaults) {
        var ids = recentIDs(from: defaults.string(forKey: recentsKey) ?? "")
        ids.removeAll { $0 == asset.id }
        ids.insert(asset.id, at: 0)
        defaults.set(ids.prefix(recentsLimit).joined(separator: "\n"), forKey: recentsKey)
    }

    static func recentIDs(from stored: String) -> [String] {
        stored.split(separator: "\n").map(String.init)
    }

    // MARK: Other words for icons

    /// Words people search for that aren't in a symbol's name, such as "settings" for a gear.
    static let iconSynonyms: [String: [String]] = {
        let groups: [(words: [String], symbols: [String])] = [
            (["settings", "preferences", "options", "cog", "gear"], ["gearshape", "gearshape.fill", "slider.horizontal.3"]),
            (["search", "find", "zoom", "look"], ["magnifyingglass"]),
            (["close", "cancel", "dismiss", "remove", "x"], ["xmark", "xmark.circle.fill"]),
            (["delete", "bin", "remove", "trash", "garbage"], ["trash"]),
            (["add", "new", "create", "plus"], ["plus", "plus.circle.fill"]),
            (["user", "account", "profile", "me", "people", "contact"], ["person", "person.fill", "person.2", "person.crop.circle"]),
            (["home", "start", "main"], ["house", "house.fill"]),
            (["menu", "hamburger", "nav", "navigation"], ["line.3.horizontal", "list.bullet"]),
            (["more", "options", "overflow", "dots"], ["ellipsis", "ellipsis.circle"]),
            (["share", "export", "send"], ["square.and.arrow.up", "paperplane", "paperplane.fill"]),
            (["download", "save", "import"], ["square.and.arrow.down", "arrow.down.circle"]),
            (["upload"], ["arrow.up.circle.fill", "square.and.arrow.up"]),
            (["edit", "write", "compose", "pen"], ["pencil", "square.and.pencil"]),
            (["like", "love", "favourite", "favorite"], ["heart", "heart.fill", "star", "star.fill"]),
            (["notification", "notifications", "alert", "alarm", "reminder"], ["bell", "bell.fill", "alarm"]),
            (["back", "previous", "return"], ["chevron.left", "arrow.left", "arrow.uturn.backward"]),
            (["next", "forward", "go", "continue", "disclosure"], ["chevron.right", "arrow.right"]),
            (["expand", "dropdown", "open"], ["chevron.down"]),
            (["collapse"], ["chevron.up"]),
            (["filter", "sort", "adjust", "controls"], ["slider.horizontal.3", "arrow.up.arrow.down"]),
            (["chat", "comment", "messages", "conversation", "sms"], ["message", "message.fill", "bubble.left", "bubble.left.and.bubble.right"]),
            (["email", "mail", "inbox"], ["envelope", "envelope.fill", "tray"]),
            (["call", "telephone"], ["phone", "phone.fill"]),
            (["money", "pay", "payment", "card", "price", "cash"], ["creditcard", "banknote", "dollarsign.circle", "wallet.pass"]),
            (["shop", "shopping", "buy", "basket", "store", "checkout"], ["cart", "cart.fill", "bag", "storefront"]),
            (["location", "place", "address", "map", "gps"], ["mappin", "mappin.and.ellipse", "location", "location.fill", "map"]),
            (["time", "hour", "history"], ["clock", "timer", "hourglass"]),
            (["date", "schedule", "event", "day"], ["calendar"]),
            (["picture", "gallery", "image", "photos"], ["photo", "photo.on.rectangle", "camera"]),
            (["audio", "song", "sound", "podcast"], ["music.note", "headphones", "waveform", "speaker.wave.2"]),
            (["bookmark", "saved"], ["bookmark", "bookmark.fill"]),
            (["warning", "error", "caution", "problem"], ["exclamationmark.triangle"]),
            (["help", "support", "faq", "question"], ["questionmark.circle"]),
            (["info", "about", "details"], ["info.circle"]),
            (["password", "secure", "private", "security", "locked"], ["lock", "key"]),
            (["unlock", "unlocked"], ["lock.open"]),
            (["show", "visible", "view", "reveal"], ["eye"]),
            (["hide", "hidden", "invisible"], ["eye.slash"]),
            (["done", "complete", "success", "tick", "ok", "confirm", "check"], ["checkmark", "checkmark.circle.fill"]),
            (["refresh", "reload", "sync", "retry", "update"], ["arrow.clockwise", "arrow.triangle.2.circlepath"]),
            (["undo"], ["arrow.uturn.backward", "arrow.counterclockwise"]),
            (["weather", "sunny", "day"], ["sun.max", "cloud"]),
            (["night", "dark", "sleep"], ["moon", "bed.double"]),
            (["rating", "review", "rate"], ["star", "star.fill"]),
            (["volume", "speaker", "loud"], ["speaker.wave.2"]),
            (["mute", "silent", "quiet"], ["speaker.slash"]),
            (["voice", "record", "microphone", "dictate"], ["mic", "mic.fill", "waveform"]),
            (["film", "movie", "watch"], ["video", "film", "play.circle", "tv"]),
            (["attach", "attachment", "clip"], ["paperclip"]),
            (["file", "document", "page", "paper"], ["doc", "doc.text", "folder"]),
            (["grid", "dashboard", "apps", "tiles"], ["square.grid.2x2"]),
            (["list", "items", "bullets"], ["list.bullet"]),
            (["idea", "tip", "hint"], ["lightbulb"]),
            (["hot", "trending", "popular", "streak"], ["flame"]),
            (["new", "magic", "ai", "special"], ["sparkles"]),
            (["fast", "quick", "flash", "power"], ["bolt", "bolt.fill"]),
            (["award", "achievement", "win", "prize"], ["trophy", "medal", "rosette", "crown"]),
            (["web", "internet", "language", "world", "browser"], ["globe", "safari"]),
            (["stats", "analytics", "chart", "graph", "report"], ["chart.bar", "chart.pie", "chart.line.uptrend.xyaxis"]),
            (["code", "developer", "html"], ["chevron.left.forwardslash.chevron.right"]),
            (["fitness", "exercise", "workout", "gym", "sport"], ["figure.run", "dumbbell", "figure.walk"]),
            (["food", "eat", "restaurant", "meal", "dinner"], ["fork.knife"]),
            (["coffee", "cafe", "drink", "tea"], ["cup.and.saucer"]),
            (["travel", "flight", "trip"], ["airplane", "car", "bus", "tram"]),
            (["health", "medical", "doctor", "medicine"], ["cross.case", "pills", "stethoscope", "heart.text.square"]),
            (["gift", "present", "reward"], ["gift", "giftcard"]),
            (["delivery", "package", "parcel", "shipping"], ["shippingbox"]),
            (["scan", "code"], ["qrcode", "barcode"]),
            (["tag", "label", "category"], ["tag"]),
            (["link", "url", "chain"], ["link"]),
            (["mention", "handle"], ["at"]),
            (["announcement", "broadcast", "promo"], ["megaphone"]),
            (["phone", "mobile", "device"], ["iphone"]),
            (["computer", "desktop", "mac", "laptop"], ["laptopcomputer", "desktopcomputer"]),
        ]
        var synonyms: [String: [String]] = [:]
        for group in groups {
            for symbol in group.symbols { synonyms[symbol, default: []] += group.words }
        }
        return synonyms
    }()
}

// PROJECTION: deleted in plan 6
extension AssetLibrary {
    /// A template's thumbnail: its screen laid out on the iPhone and lowered to the elements the thumbnail
    /// draws. Made once per name and kept, since the library's tiles ask for it whenever they are drawn.
    static func templatePreview(named name: String) -> [DesignElement] {
        previews.withLock { previews in
            if let made = previews.elements[name] { return made }
            guard let root = template(named: name, tokens: .standard) else { return [] }
            var content = TreeContent()
            content.screens = [TreeScreen(name: name, origin: .zero, scale: 1, deviceID: nil,
                                          root: TreeRules.laidOut(root, deviceID: nil, settings: content.settings, previous: nil))]
            let elements = TreeProjection.lower(content).screens.first?.elements ?? []
            previews.elements[name] = elements
            #if DEBUG
            previews.made[name, default: 0] += 1
            #endif
            return elements
        }
    }

    #if DEBUG
    /// Previews made for this name, counted under a lock: tests count per name (F13).
    static func templatePreviewsMade(named name: String) -> Int {
        previews.withLock { $0.made[name] ?? 0 }
    }
    #endif

    private struct Previews: Sendable {
        var elements: [String: [DesignElement]] = [:]
        #if DEBUG
        var made: [String: Int] = [:]
        #endif
    }

    /// Held while a preview is made, so that one asked for twice at once is made once.
    private static let previews = OSAllocatedUnfairLock(initialState: Previews())
}

// MARK: - The library's view

/// The library: icons, wireframes, shapes and components, in tabs under one search field.
/// Tapping a thing hands it back; dragging it puts it on the canvas where it is dropped.
/// A search looks in every tab at once; one that finds nothing offers to write the screen.
struct AssetLibraryView: View {
    let onPick: (Asset) -> Void
    /// A drag has started. A popover catches drops on the canvas behind it, so whoever
    /// presents the library puts it away here.
    var onDragStart: () -> Void = {}
    /// Writes a screen from what was searched for. Without it, a search that finds nothing
    /// only says so.
    var onGenerate: ((String) -> Void)?
    @Environment(AppModel.self) private var model
    @Environment(ImageLibrary.self) private var images
    @AppStorage("assetLibrary.tab") private var tab = AssetTab.icons
    @AppStorage(AssetLibrary.recentsKey) private var storedRecents = ""
    @State private var search = ""
    /// The last search and what it found. The body is worked out again for other reasons,
    /// a generation starting for one, and the library isn't searched again for those.
    @State private var lastSearch = LastSearch()
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let groups = lastSearch.groups(for: search)
        VStack(spacing: 0) {
            searchField(firstResult: groups.first?.assets.first)
            // The tabs stay where they are while searching, so the layout doesn't jump, but
            // they don't filter: a search looks in all of them, and clearing it returns to
            // the tab that was open.
            Picker("Library", selection: $tab) {
                ForEach(AssetTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isSearching)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if isSearching {
                        searchResults(groups)
                    } else {
                        browsing
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .foregroundStyle(.primary)
        // The size of its popover. In a narrow window it is a sheet instead, and fills it.
        .frame(idealWidth: 380, maxWidth: .infinity, idealHeight: 480, maxHeight: .infinity)
    }

    private var isSearching: Bool { AssetLibrary.listing(for: search, openTab: tab) == .searchResults }

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Whether to offer to write a screen for the search: there are words, and nothing
    /// was found. Every group found has at least one asset, so the first is enough to tell.
    private func offersGeneration(_ firstResult: Asset?) -> Bool {
        isSearching && firstResult == nil
    }

    // MARK: Search

    private func searchField(firstResult: Asset?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search the library", text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(onGenerate != nil && offersGeneration(firstResult) ? .go : .done)
                .focused($isSearchFocused)
                // Return puts the best match on the canvas; when nothing matches, it writes
                // the screen the words describe.
                .onSubmit {
                    switch AssetLibrary.submitAction(for: search, firstResult: firstResult, canGenerate: onGenerate != nil, isGenerating: model.isGenerating) {
                    case .place(let asset): onPick(asset)
                    case .generate(let query): onGenerate?(query)
                    case .nothing: break
                    }
                }
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .transition(.opacity)
            }
        }
        .padding(10)
        .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 10))
        .padding(12)
        .animation(.easeOut(duration: 0.15), value: search.isEmpty)
    }

    @ViewBuilder
    private func searchResults(_ groups: [AssetLibrary.ResultGroup]) -> some View {
        if groups.isEmpty {
            if let onGenerate {
                GenerateEmptyState(query: query, modelName: model.modelChoice.displayName, isGenerating: model.isGenerating) {
                    onGenerate(query)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nothing matches “\(query)”.")
                        .font(.system(size: 13, weight: .medium))
                    Text("Try another word, such as “settings” or “arrow”, or type an SF Symbol's exact name, such as cloud.sun.rain.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 20)
            }
        } else {
            ForEach(groups, id: \.tab) { group in
                sectionHeader("\(group.tab.title)  \(group.assets.count)")
                grid(group.assets, in: group.tab)
            }
        }
    }

    // MARK: Browsing

    @ViewBuilder
    private var browsing: some View {
        let recents = AssetLibrary.recentIDs(from: storedRecents)
            .compactMap(AssetLibrary.asset(id:))
            .filter { $0.tab == tab }
        if !recents.isEmpty {
            sectionHeader("Recent")
            grid(recents, in: tab)
        }
        let assets = AssetLibrary.matching("", in: tab)
        ForEach(sections(of: assets), id: \.name) { section in
            sectionHeader(section.name)
            grid(section.assets, in: tab)
        }
    }

    private func sections(of assets: [Asset]) -> [(name: String, assets: [Asset])] {
        var order: [String] = []
        var grouped: [String: [Asset]] = [:]
        for asset in assets {
            if grouped[asset.section] == nil { order.append(asset.section) }
            grouped[asset.section, default: []].append(asset)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 6)
    }

    // MARK: Tiles

    private func grid(_ assets: [Asset], in tab: AssetTab) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: tileWidth(of: tab)), spacing: 6)], spacing: 6) {
            ForEach(assets) { asset in
                Button {
                    onPick(asset)
                } label: {
                    AssetTile(asset: asset)
                        .contentShape(.rect(cornerRadius: 8))
                        .contentShape(.hoverEffect, .rect(cornerRadius: 8))
                        .hoverEffect(.highlight)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(asset.accessibilityName)
                .accessibilityHint("Adds it to the canvas. Drag it to put it somewhere.")
                .onDrag {
                    onDragStart()
                    return NSItemProvider(object: asset.id as NSString)
                } preview: {
                    AssetTile(asset: asset, isDragPreview: true)
                        .environment(images)
                }
            }
        }
    }

    private func tileWidth(of tab: AssetTab) -> CGFloat {
        switch tab {
        case .icons: 44
        case .shapes: 60
        case .wireframes, .components: 96
        }
    }
}

/// What a search that finds nothing shows: a sketch of what happens next, and the way to do it.
private struct GenerateEmptyState: View {
    let query: String
    let modelName: String
    let isGenerating: Bool
    let generate: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            diagram
            if isGenerating {
                Text("A screen is being written. Stop it, or wait for it to finish, to start another.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Press Return to generate this screen with \(modelName)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(action: generate) {
                Label("Generate Screen", systemImage: "wand.and.sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isGenerating)
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }

    /// The query, a library with no component for it, and the screen it becomes instead.
    private var diagram: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(query)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(3)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: 110)
                .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 10))
                .frame(height: 44)
            arrow
            step("No component") {
                Image(systemName: "square.on.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    // The strike: nothing in the library is this.
                    .overlay {
                        Rectangle()
                            .fill(.red.opacity(0.8))
                            .frame(width: 34, height: 2)
                            .rotationEffect(.degrees(-35))
                    }
            }
            arrow
            step("New screen") {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.primary, lineWidth: 1.5)
                    .frame(width: 26, height: 44)
                    .overlay(alignment: .top) {
                        Capsule().fill(.primary).frame(width: 8, height: 2).padding(.top, 4)
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("“\(query)” is not a component. It becomes a new screen.")
    }

    private var arrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(height: 44)
    }

    private func step(_ title: String, @ViewBuilder picture: () -> some View) -> some View {
        VStack(spacing: 4) {
            picture().frame(width: 40, height: 44)
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

/// One asset's picture in the library: the thing itself, drawn as it will be on the canvas.
private struct AssetTile: View {
    let asset: Asset
    var isDragPreview = false

    var body: some View {
        switch asset.content {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 20))
                .frame(width: 44, height: 44)

        case .shape(let kind, let filled):
            let size = kind.size
            let scale = 36 / max(size.width, size.height)
            ShapeElementView(kind: kind, color: Theme.inkTint.color, isFilled: filled, cornerRadius: 10)
                .frame(width: size.width * scale, height: size.height * scale)
                .frame(width: 60, height: 52)

        case .component(let id):
            labelled(asset.name) {
                if let element = AssetLibrary.element(forComponent: id) {
                    ScaledElement(element: element, fitting: CGSize(width: 84, height: 40))
                }
            }

        case .frame(let id):
            labelled(asset.name) {
                if let device = DeviceFrame.all.first(where: { $0.id == id }) {
                    let scale = 52 / max(device.size.width, device.size.height)
                    RoundedRectangle(cornerRadius: device.cornerRadius * scale + 2, style: .continuous)
                        .strokeBorder(.secondary, lineWidth: 1.5)
                        .frame(width: device.size.width * scale, height: device.size.height * scale)
                }
            }

        case .template(let name):
            labelled(asset.name) {
                TemplatePreview(elements: AssetLibrary.templatePreview(named: name), device: .iPhone, height: 52)
            }
        }
    }

    private func labelled(_ name: String, @ViewBuilder picture: () -> some View) -> some View {
        VStack(spacing: 4) {
            picture()
                .frame(width: 92, height: 56)
                .background(Color(uiColor: .tertiarySystemFill).opacity(isDragPreview ? 0 : 1), in: .rect(cornerRadius: 8))
            if !isDragPreview {
                Text(name)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(width: 96)
    }
}

/// An element drawn at its own size, then scaled down to fit.
private struct ScaledElement: View {
    let element: DesignElement
    let fitting: CGSize

    var body: some View {
        let size = element.frame.size
        let scale = min(1, fitting.width / max(size.width, 1), fitting.height / max(size.height, 1))
        ElementView(element: element)
            .frame(width: size.width, height: size.height)
            .scaleEffect(scale)
            .frame(width: size.width * scale, height: size.height * scale)
            .allowsHitTesting(false)
    }
}

/// A ready-made screen in miniature: its elements on a white phone.
private struct TemplatePreview: View {
    let elements: [DesignElement]
    let device: DeviceFrame
    let height: CGFloat

    var body: some View {
        let scale = height / device.size.height
        ZStack(alignment: .topLeading) {
            Color.white
            ForEach(elements) { element in
                ElementView(element: element)
                    .frame(width: element.frame.width, height: element.frame.height)
                    .offset(x: element.frame.minX, y: element.frame.minY)
            }
        }
        .frame(width: device.size.width, height: device.size.height, alignment: .topLeading)
        .clipShape(.rect(cornerRadius: device.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: device.cornerRadius, style: .continuous)
                .strokeBorder(.black.opacity(0.25), lineWidth: 6)
        }
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: device.size.width * scale, height: height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// What the library's search last found, kept for the search it was.
@MainActor
private final class LastSearch {
    private var search: String?
    private var found: [AssetLibrary.ResultGroup] = []

    func groups(for search: String) -> [AssetLibrary.ResultGroup] {
        if search != self.search {
            self.search = search
            found = AssetLibrary.searchEverywhere(search)
        }
        return found
    }
}
