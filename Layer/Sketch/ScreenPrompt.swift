import Foundation

/// What a model is told when it writes a whole screen (`ScreenGenerator`), put together
/// from parts so each can be changed, measured and overridden on its own:
///
/// - **grammar**: how a screen is written down, with the kinds read from the catalogue,
///   so a new kind reaches the prompt without anyone editing it;
/// - **rules**: what makes a written screen good: one job, one primary action, real
///   words, colour left to the design, a shape that fits the job. They follow the
///   anti-"AI look" rules Hallmark uses for web pages, turned into wireframe terms;
/// - **examples**: one or two short screens chosen to suit the description, so the
///   model isn't anchored on a sign-in form whatever it is asked for;
/// - **the board**: what the design's other screens say, so a new one matches their
///   words and voice.
///
/// The on-device model has a small context, so it gets the compact rules and one
/// example; a hosted model gets all of it.
enum ScreenPrompt {
    enum Room: Sendable {
        /// The on-device model: little room.
        case compact
        /// A hosted model: room for everything.
        case full
    }

    // MARK: Instructions

    static func instructions(_ room: Room, for description: String) -> String {
        let examples = examples(for: description, count: room == .compact ? 1 : 2)
        let shown = examples.map(\.lines).joined(separator: "\n\n---\n\n")
        let heading = examples.count == 1
            ? "An example of the form. Write your own content; don't copy it:"
            : "Examples of the form, one screen each. Write your own content; don't copy them:"
        // Rules last: a small model follows best what it read most recently.
        return [
            "You design phone app screens for a wireframing tool. Given a description of a screen, write it down.",
            grammar,
            "\(heading)\n\n\(shown)",
            rules(room),
        ].joined(separator: "\n\n")
    }

    /// How a screen is written down: the outline `Outline.parse` reads. Shown with real lines
    /// rather than a `kind: words` template, which the on-device model measurably copied word
    /// for word.
    static var grammar: String {
        PromptOverrides.text(.screenGrammar, default: """
            Write one line per element, from top to bottom. A line is the element's kind, a colon \
            and its words, then its look in square brackets only when it needs one, such as:
            text field: Card number
            button: Skip [plain]

            Kinds: \(kindNames.joined(separator: ", ")). Use only the kinds the screen needs.
            - "row:", "card:" or "grid 2:" on a line of its own holds the lines indented two spaces \
            under it. A row puts them side by side, a card groups them on a panel, and a grid sets \
            them in that many columns, such as:
            card:
              text: Arrives Thursday [semibold]
              body: Free delivery to your door.
            - A short row can stay on one line, its elements separated by "|", such as \
            row: text: Wi-Fi | toggle [on]
            - A blank line starts a new section.
            - For a symbol, the words are an SF Symbol name, such as bell or gearshape.
            - Most lines need no look. Looks: filled, bordered or plain for a button; bold or \
            semibold; a size such as 28pt; text grey for quieter words; a colour name; on or off; \
            40% for a progress bar; left, centre or right.

            Write only the lines: no introduction, no explanation, no markdown.
            """)
    }

    /// The kinds a screen can be written with, by the first word each goes by.
    static var kindNames: [String] {
        ElementKind.allCases
            .filter { $0.spec.belongsOnScreens }
            .compactMap { $0.spec.writtenNames.first }
    }

    static func rules(_ room: Room) -> String {
        switch room {
        case .full:
            PromptOverrides.text(.screenRules, default: """
                What makes a screen good:
                - Give it one job and build it around that. The title names the job in plain words.
                - Shape it for the job instead of a title, a paragraph and a button every time: \
                settings are rows of text and a toggle; a profile starts with an avatar; an article \
                or a product starts with an image; a form is its fields, then its action.
                - One primary action, written as the only filled button, usually last. Every other \
                button is bordered or plain. Of two side by side, the less important one is plain.
                - Write real copy for this product. Fields name what goes in them ("Card number"). \
                Buttons are verbs that say what happens ("Save address", not "Submit" or "OK"). \
                Never lorem ipsum, "Placeholder", "Button" or "Click here".
                - Sample content such as a name, a date or a price is fine. Invented claims are not: \
                no "10× faster", no "trusted by thousands", no ratings or counts the description didn't give.
                - Leave colour to the design: write a colour only when the description asks for one, \
                and red only for something destructive such as Delete account.
                - Make hierarchy with size and weight, not colour: one title, body for whatever \
                explains, text grey for small print.
                - Group with blank lines or in a card: a form's fields together, a list's rows together. \
                Two to four sections.
                - Use 5 to 14 elements. Fewer, better elements beat a crowded screen.
                """)
        case .compact:
            PromptOverrides.text(.screenRulesCompact, default: """
                Rules:
                - Write words for this exact product, not the example's.
                - Shape the screen for its job: settings are rows of text and a toggle, a profile \
                starts with an avatar, an article starts with an image, a form is fields then one button. \
                Details that belong together, such as a summary or a set of figures, go in a card: or a grid 2:.
                - The main action is one button with no look, so it is filled. Other buttons are [bordered] or [plain].
                - Real, specific words such as "Card number" or "Save address". Never "Placeholder", \
                "Submit" or lorem ipsum. No invented claims or ratings.
                - No colour words, not even blue, red or grey, unless the description names a colour. \
                Quieter words are text grey.
                - Use 6 to 12 elements.
                """)
        }
    }

    // MARK: The request

    /// The message sent for a screen: its description and, for a hosted model when the
    /// board has other screens, what they say. The on-device model isn't told the board:
    /// given it, it wrote the other screens out again in place of the one asked for (a
    /// calligraphy webpage came back as the board's trip planner, natively and on the iPad).
    static func request(_ description: String, board: String?, room: Room) -> String {
        guard room == .full, let board = board?.trimmingCharacters(in: .whitespacesAndNewlines), !board.isEmpty else { return description }
        let limit = 2000
        let context = board.count > limit ? String(board.prefix(limit)) + "…" : board
        return """
            \(description)

            The rest of the design, so the new screen's words and voice match it: \(context)
            """
    }

    // MARK: Examples

    struct Example: Sendable, Equatable {
        var name: String
        /// Words in a description that make this example a good fit.
        var keywords: [String]
        var lines: String
    }

    /// The examples that suit `description` best, the best first. A description that
    /// suits none gets the first few of the library, which deliberately don't start with
    /// a sign-in form.
    static func examples(for description: String, count: Int) -> [Example] {
        let lowered = description.lowercased()
        let scored = library.enumerated().map { index, example in
            (example, index, example.keywords.count { lowered.contains($0) })
        }
        return scored
            .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.1 < $1.1 }
            .prefix(count)
            .map(\.0)
    }

    static let library: [Example] = [
        Example(
            name: "settings",
            keywords: ["setting", "preference", "notification", "privacy", "option", "toggle", "switch"],
            lines: """
                title: Notifications

                row: text: Push notifications | toggle [on]
                row: text: Daily summary | toggle [off]
                row: text: Mentions only | toggle [on]
                divider
                row: text: Quiet hours | text: 22:00 – 07:00 [right, text grey]

                button: Turn off all notifications [plain, red]
                """
        ),
        Example(
            name: "product",
            keywords: ["product", "detail", "item", "article", "recipe", "post", "story", "listing", "shop", "store"],
            lines: """
                image
                title: Cast-iron skillet, 26 cm
                body: Pre-seasoned and oven-safe. Ships in two days.

                card:
                  row: text: Size | text: 26 cm [right]
                  row: text: Colour | text: Black [right]

                button: Add to bag
                button: Save for later [plain]
                """
        ),
        Example(
            name: "profile",
            keywords: ["profile", "user", "bio", "follower", "member", "person", "contact"],
            lines: """
                avatar
                title: Maya Okafor
                body: Ceramicist in Lisbon. Small-batch tableware.
                row: button: Follow | button: Message [bordered]

                text: Recent work [semibold]
                grid 3:
                  image
                  image
                  image
                  image
                  image
                  image
                """
        ),
        Example(
            name: "form",
            keywords: ["form", "checkout", "payment", "address", "order", "booking", "book", "delivery", "shipping", "edit"],
            lines: """
                title: Delivery address

                text field: Full name
                text field: Street and number
                row:
                  text field: Postcode
                  text field: City
                text field: Phone, for the courier

                row: text: Same address for billing | toggle [on]

                button: Continue to payment
                """
        ),
        Example(
            name: "empty",
            keywords: ["empty", "no ", "nothing", "onboarding", "welcome", "intro", "get started", "permission", "success", "done"],
            lines: """
                symbol: tray
                title: No orders yet
                body: When you buy something, it shows up here with its tracking.

                button: Browse the shop
                """
        ),
        Example(
            name: "sign in",
            keywords: ["sign in", "sign-in", "log in", "login", "sign up", "sign-up", "register", "password", "account"],
            lines: """
                title: Sign in to Fieldnote
                body: Pick up your notes where you left them.

                text field: Email
                text field: Password
                button: Sign in
                row: button: Forgot password? [plain] | button: Create account [plain]
                """
        ),
    ]
}
