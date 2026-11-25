import Testing
@testable import Layer

/// Each screen prompt's default wording, word for word, as it was measured. A wording change needs a harness run
/// (`Tools/ScreenBenchmarkHarness/run.sh`), recorded in docs/benchmarks/screen-prompt.md, and then a new literal here.
@Suite struct ScreenPromptWordingTests {
    private static let brief = "a settings screen for a podcast app"

    /// The outline prompts: the compact one measured on the on-device model (plan 3, Task 12), and the full one.
    @Test func theMeasuredOutlinePromptIsUnchanged() {
        #expect(ScreenPrompt.instructions(.compact, for: Self.brief) == Self.compact)
        #expect(ScreenPrompt.instructions(.full, for: Self.brief) == Self.full)
    }

    /// The A2UI prompt a model is told when it writes A2UI, as measured on 2026-11-26: a component a message, one way to
    /// write an icon, a control's label always, ids in words, and only what shows counted. A change to them changes this
    /// literal.
    @Test func theA2UIPromptIsUnchanged() {
        #expect(A2UIPrompt.instructions(for: Self.brief) == Self.a2ui)
    }

    /// Every example either prompt can show, word for word, with what picks it: a change to one changes a measured
    /// prompt, so it needs a harness run too.
    @Test func theExamplesAreUnchanged() {
        #expect(ScreenPrompt.library.map(\.name) == Self.outlineExamples.map(\.name))
        for (example, pinned) in zip(ScreenPrompt.library, Self.outlineExamples) {
            #expect(example == pinned, "the outline's \(pinned.name) example")
        }
        #expect(A2UIPrompt.library.map(\.name) == Self.a2uiExamples.map(\.name))
        for (example, pinned) in zip(A2UIPrompt.library, Self.a2uiExamples) {
            #expect(example == pinned, "the A2UI \(pinned.name) example")
        }
    }

    private static let outlineExamples: [ScreenPrompt.Example] = [
        ScreenPrompt.Example(
            name: "settings",
            keywords: ["setting", "preference", "notification", "privacy", "option", "toggle", "switch"],
            lines: """
                title: Notifications

                row: text: Push notifications | toggle [on]
                row: text: Daily summary | toggle [off]
                row: text: Mentions only | toggle [on]
                divider
                row: text: Quiet hours | text: 22:00 – 07:00 [right, text grey]

                button: Turn off all notifications [plain]
                """
        ),
        ScreenPrompt.Example(
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
        ScreenPrompt.Example(
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
        ScreenPrompt.Example(
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
        ScreenPrompt.Example(
            name: "empty",
            keywords: ["empty", "no ", "nothing", "onboarding", "welcome", "intro", "get started", "permission", "success", "done"],
            lines: """
                symbol: tray
                title: No orders yet
                body: When you buy something, it shows up here with its tracking.

                button: Browse the shop
                """
        ),
        ScreenPrompt.Example(
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

    private static let a2uiExamples: [ScreenPrompt.Example] = [
        ScreenPrompt.Example(
            name: "settings",
            keywords: ["setting", "preference", "notification", "privacy", "option", "toggle", "switch"],
            lines: """
                {"version":"1.0","createSurface":{"surfaceId":"screen","catalogId":"urn:layer:a2ui:catalog:1"}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"root","component":"Column","children":["heading","alerts","turn_off"]}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"heading","component":"Text","text":"## Notifications"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"alerts","component":"Column","children":["push","summary","mentions","divider","quiet"]}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"push","component":"Row","justify":"spaceBetween","align":"center","children":["push_label","push_switch"]}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"push_label","component":"Text","text":"Push notifications"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"push_switch","component":"LayerToggle","label":"Push notifications","value":true}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"summary","component":"Row","justify":"spaceBetween","align":"center","children":["summary_label","summary_switch"]}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"summary_label","component":"Text","text":"Daily summary"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"summary_switch","component":"LayerToggle","label":"Daily summary","value":false}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"mentions","component":"Row","justify":"spaceBetween","align":"center","children":["mentions_label","mentions_switch"]}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"mentions_label","component":"Text","text":"Mentions only"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"mentions_switch","component":"LayerToggle","label":"Mentions only","value":true}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"divider","component":"Divider"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"quiet","component":"Row","justify":"spaceBetween","align":"center","children":["quiet_label","quiet_hours"]}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"quiet_label","component":"Text","text":"Quiet hours"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"quiet_hours","component":"Text","text":"22:00 – 07:00","variant":"caption"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"turn_off","component":"Button","child":"turn_off_label","variant":"borderless","action":{"event":{"name":"turnOffAllNotifications"}}}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"turn_off_label","component":"Text","text":"Turn off all notifications"}]}}
                """
        ),
        ScreenPrompt.Example(
            name: "product",
            keywords: ["product", "detail", "item", "article", "recipe", "post", "story", "listing", "shop", "store"],
            lines: """
                {"version":"1.0","createSurface":{"surfaceId":"screen","catalogId":"urn:layer:a2ui:catalog:1"}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"root","component":"Column","children":["photo","about","details","actions"]}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"photo","component":"Image","url":"","description":"A black cast-iron skillet"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"about","component":"Column","children":["name","summary"]}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"name","component":"Text","text":"## Cast-iron skillet, 26 cm"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"summary","component":"Text","text":"Pre-seasoned and oven-safe. Ships in two days."}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"details","component":"Card","child":"details_rows"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"details_rows","component":"Column","children":["size","colour"]}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"size","component":"Row","justify":"spaceBetween","align":"center","children":["size_label","size_value"]}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"size_label","component":"Text","text":"Size"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"size_value","component":"Text","text":"26 cm"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"colour","component":"Row","justify":"spaceBetween","align":"center","children":["colour_label","colour_value"]}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"colour_label","component":"Text","text":"Colour"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"colour_value","component":"Text","text":"Black"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"actions","component":"Column","children":["add","save"]}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"add","component":"Button","child":"add_label","variant":"primary","action":{"event":{"name":"addToBag"}}}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"add_label","component":"Text","text":"Add to bag"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"save","component":"Button","child":"save_label","variant":"borderless","action":{"event":{"name":"saveForLater"}}}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"save_label","component":"Text","text":"Save for later"}]}}
                """
        ),
        ScreenPrompt.Example(
            name: "profile",
            keywords: ["profile", "user", "bio", "follower", "member", "person", "contact"],
            lines: """
                {"version":"1.0","createSurface":{"surfaceId":"screen","catalogId":"urn:layer:a2ui:catalog:1"}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"root","component":"Column","children":["person","work"]}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"person","component":"Column","children":["avatar","name","bio","contact"]}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"avatar","component":"Image","url":"","variant":"avatar","description":"Maya Okafor"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"name","component":"Text","text":"## Maya Okafor"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"bio","component":"Text","text":"Ceramicist in Lisbon. Small-batch tableware."}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"contact","component":"Row","align":"center","children":["follow","message"]}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"follow","component":"Button","child":"follow_label","variant":"primary","action":{"event":{"name":"follow"}}}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"follow_label","component":"Text","text":"Follow"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"message","component":"Button","child":"message_label","variant":"default","action":{"event":{"name":"message"}}}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"message_label","component":"Text","text":"Message"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"work","component":"Column","children":["work_heading","work_grid"]}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"work_heading","component":"Text","text":"Recent work"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"work_grid","component":"LayerGrid","columns":3,"children":["bowl","plate","mug","vase","jug","cup"]}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"bowl","component":"Image","url":"","description":"A speckled bowl"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"plate","component":"Image","url":"","description":"A blue-rimmed plate"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"mug","component":"Image","url":"","description":"A stoneware mug"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"vase","component":"Image","url":"","description":"A tall glazed vase"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"jug","component":"Image","url":"","description":"A cream jug"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"cup","component":"Image","url":"","description":"A handleless cup"}]}}
                """
        ),
        ScreenPrompt.Example(
            name: "form",
            keywords: ["form", "checkout", "payment", "address", "order", "booking", "book", "delivery", "shipping", "edit"],
            lines: """
                {"version":"1.0","createSurface":{"surfaceId":"screen","catalogId":"urn:layer:a2ui:catalog:1"}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"root","component":"Column","children":["heading","address","billing","next"]}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"heading","component":"Text","text":"## Delivery address"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"address","component":"Column","children":["full_name","street","town","phone"]}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"full_name","component":"TextField","label":"Full name","value":""}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"street","component":"TextField","label":"Street and number","value":""}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"town","component":"Row","children":["postcode","city"]}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"postcode","component":"TextField","label":"Postcode","value":""}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"city","component":"TextField","label":"City","value":""}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"phone","component":"TextField","label":"Phone, for the courier","value":""}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"billing","component":"Row","justify":"spaceBetween","align":"center","children":["billing_label","billing_switch"]}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"billing_label","component":"Text","text":"Same address for billing"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"billing_switch","component":"LayerToggle","label":"Same address for billing","value":true}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"next","component":"Button","child":"next_label","variant":"primary","action":{"event":{"name":"continueToPayment"}}}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"next_label","component":"Text","text":"Continue to payment"}]}}
                """
        ),
        ScreenPrompt.Example(
            name: "empty",
            keywords: ["empty", "no ", "nothing", "onboarding", "welcome", "intro", "get started", "permission", "success", "done"],
            lines: """
                {"version":"1.0","createSurface":{"surfaceId":"screen","catalogId":"urn:layer:a2ui:catalog:1"}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"root","component":"Column","children":["message","browse"]}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"message","component":"Column","children":["tray","heading","explanation"]}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"tray","component":"LayerSymbol","name":"tray"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"heading","component":"Text","text":"## No orders yet"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"explanation","component":"Text","text":"When you buy something, it shows up here with its tracking."}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"browse","component":"Button","child":"browse_label","variant":"primary","action":{"event":{"name":"browseTheShop"}}}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"browse_label","component":"Text","text":"Browse the shop"}]}}
                """
        ),
        ScreenPrompt.Example(
            name: "sign in",
            keywords: ["sign in", "sign-in", "log in", "login", "sign up", "sign-up", "register", "password", "account"],
            lines: """
                {"version":"1.0","createSurface":{"surfaceId":"screen","catalogId":"urn:layer:a2ui:catalog:1"}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"root","component":"Column","children":["intro","fields","links"]}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"intro","component":"Column","children":["heading","subtitle"]}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"heading","component":"Text","text":"## Sign in to Fieldnote"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"subtitle","component":"Text","text":"Pick up your notes where you left them."}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"fields","component":"Column","children":["email","password","sign_in"]}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"email","component":"TextField","label":"Email","value":""}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"password","component":"TextField","label":"Password","value":""}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"sign_in","component":"Button","child":"sign_in_label","variant":"primary","action":{"event":{"name":"signIn"}}}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"sign_in_label","component":"Text","text":"Sign in"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"links","component":"Row","justify":"spaceBetween","children":["forgot","create"]}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"forgot","component":"Button","child":"forgot_label","variant":"borderless","action":{"event":{"name":"resetPassword"}}}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"forgot_label","component":"Text","text":"Forgot password?"}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"create","component":"Button","child":"create_label","variant":"borderless","action":{"event":{"name":"createAccount"}}}]}}
                {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"create_label","component":"Text","text":"Create account"}]}}
                """
        ),
    ]

    private static let compact = """
        You design phone app screens for a wireframing tool. Given a description of a screen, write it down.

        Write one line per element, from top to bottom. A line is the element's kind, a colon and its words, then its look in square brackets only when it needs one, such as:
        text field: Card number
        button: Skip [plain]

        Kinds: title, body, image, button, text field, divider, symbol, text, toggle, avatar, checkbox, radio, progress. Use only the kinds the screen needs.
        - "row:", "card:" or "grid 2:" on a line of its own holds the lines indented two spaces under it. A row puts them side by side, a card groups them on a panel, and a grid sets them in that many columns, such as:
        card:
          text: Arrives Thursday [semibold]
          body: Free delivery to your door.
        - A short row can stay on one line, its elements separated by "|", such as row: text: Wi-Fi | toggle [on]
        - A blank line starts a new section.
        - For a symbol, the words are an SF Symbol name, such as bell or gearshape.
        - Most lines need no look. Looks: filled, bordered or plain for a button; bold or semibold; text grey for quieter words; a colour name; on or off; 40% for a progress bar; left, centre or right.

        Write only the lines: no introduction, no explanation, no markdown.

        An example of the form. Write your own content; don't copy it:

        title: Notifications

        row: text: Push notifications | toggle [on]
        row: text: Daily summary | toggle [off]
        row: text: Mentions only | toggle [on]
        divider
        row: text: Quiet hours | text: 22:00 – 07:00 [right, text grey]

        button: Turn off all notifications [plain]

        Rules:
        - Write words for this exact product, not the example's.
        - Shape the screen for its job: settings are rows of text and a toggle, a profile starts with an avatar, an article starts with an image, a form is fields then one button. Details that belong together, such as a summary or a set of figures, go in a card: or a grid 2:.
        - The main action is one button with no look, so it is filled. Other buttons are [bordered] or [plain].
        - Real, specific words such as "Card number" or "Save address". Never "Placeholder", "Submit" or lorem ipsum. No invented claims or ratings.
        - No colour words, not even blue, red or grey, unless the description names a colour. For quieter words use text grey, which isn't one.
        - Use 6 to 12 elements.
        """

    private static let full = """
        You design phone app screens for a wireframing tool. Given a description of a screen, write it down.

        Write one line per element, from top to bottom. A line is the element's kind, a colon and its words, then its look in square brackets only when it needs one, such as:
        text field: Card number
        button: Skip [plain]

        Kinds: title, body, image, button, text field, divider, symbol, text, toggle, avatar, checkbox, radio, progress. Use only the kinds the screen needs.
        - "row:", "card:" or "grid 2:" on a line of its own holds the lines indented two spaces under it. A row puts them side by side, a card groups them on a panel, and a grid sets them in that many columns, such as:
        card:
          text: Arrives Thursday [semibold]
          body: Free delivery to your door.
        - A short row can stay on one line, its elements separated by "|", such as row: text: Wi-Fi | toggle [on]
        - A blank line starts a new section.
        - For a symbol, the words are an SF Symbol name, such as bell or gearshape.
        - Most lines need no look. Looks: filled, bordered or plain for a button; bold or semibold; text grey for quieter words; a colour name; on or off; 40% for a progress bar; left, centre or right.

        Write only the lines: no introduction, no explanation, no markdown.

        Examples of the form, one screen each. Write your own content; don't copy them:

        title: Notifications

        row: text: Push notifications | toggle [on]
        row: text: Daily summary | toggle [off]
        row: text: Mentions only | toggle [on]
        divider
        row: text: Quiet hours | text: 22:00 – 07:00 [right, text grey]

        button: Turn off all notifications [plain]

        ---

        image
        title: Cast-iron skillet, 26 cm
        body: Pre-seasoned and oven-safe. Ships in two days.

        card:
          row: text: Size | text: 26 cm [right]
          row: text: Colour | text: Black [right]

        button: Add to bag
        button: Save for later [plain]

        What makes a screen good:
        - Give it one job and build it around that. The title names the job in plain words.
        - Shape it for the job instead of a title, a paragraph and a button every time: settings are rows of text and a toggle; a profile starts with an avatar; an article or a product starts with an image; a form is its fields, then its action.
        - One primary action, written as the only filled button, usually last. Every other button is bordered or plain. Of two side by side, the less important one is plain.
        - Write real copy for this product. Fields name what goes in them ("Card number"). Buttons are verbs that say what happens ("Save address", not "Submit" or "OK"). Never lorem ipsum, "Placeholder", "Button" or "Click here".
        - Sample content such as a name, a date or a price is fine. Invented claims are not: no "10× faster", no "trusted by thousands", no ratings or counts the description didn't give.
        - Leave colour to the design: write a colour only when the description asks for one, and red only for something destructive such as Delete account.
        - Make hierarchy with size and weight, not colour: one title, body for whatever explains, text grey for small print.
        - Group with blank lines or in a card: a form's fields together, a list's rows together. Two to four sections.
        - Use 5 to 14 elements. Fewer, better elements beat a crowded screen.
        """

    private static let a2ui = """
        You design phone app screens for a wireframing tool. Given a description of a screen, write it down in A2UI.

        Write A2UI 1.0 messages, one JSON object per line and nothing else: no introduction, no explanation, no markdown.

        The first line creates the screen's surface:
        {"version":"1.0","createSurface":{"surfaceId":"screen","catalogId":"urn:layer:a2ui:catalog:1"}}

        Each line after it is an updateComponents message holding one component, the next part of the screen, from top to bottom:
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"…","component":"…",…}]}}
        The first holds the root: a Column with the id root, whose children are the ids of the screen's sections, in order. Then each section the root names, each followed by what it holds, a line for each component. Every id a component names has a line of its own.

        Every component has an id and a component. An id says what its component is, in words joined by underscores, such as total_label or pace_value, and no two components share one. Use only these:
        - Column: children, a list of ids, from top to bottom.
        - Row: children, side by side. align center lines them up; justify spaceBetween puts them at both ends.
        - Card: child, the id of one component, usually a Column.
        - LayerGrid: children, filled row by row, and columns, a whole number from 1 to 12, which is required.
        - Text: text. "# " or "## " before the words makes the screen's heading; variant caption is for small print.
        - Image: url "" and a description of what it shows; variant avatar for a person.
        - LayerSymbol: name, an SF Symbol name, such as bell, gearshape or chevron.right. Every icon is one.
        - Button: child, the id of a Text with its words; variant primary, default or borderless; and action.
        - TextField: label, saying what goes in it, and value "".
        - CheckBox, LayerToggle and LayerRadio: label, always, even beside a Text that says the same, and value true or false.
        - LayerProgress: value, from 0 to 1.
        - Divider.

        Every value is a literal, written out: no @path, no @call. A button's action is {"event":{"name":"<verb>"}}.

        Examples of the form, one screen each. Write your own content; don't copy them:

        {"version":"1.0","createSurface":{"surfaceId":"screen","catalogId":"urn:layer:a2ui:catalog:1"}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"root","component":"Column","children":["heading","alerts","turn_off"]}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"heading","component":"Text","text":"## Notifications"}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"alerts","component":"Column","children":["push","summary","mentions","divider","quiet"]}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"push","component":"Row","justify":"spaceBetween","align":"center","children":["push_label","push_switch"]}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"push_label","component":"Text","text":"Push notifications"}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"push_switch","component":"LayerToggle","label":"Push notifications","value":true}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"summary","component":"Row","justify":"spaceBetween","align":"center","children":["summary_label","summary_switch"]}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"summary_label","component":"Text","text":"Daily summary"}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"summary_switch","component":"LayerToggle","label":"Daily summary","value":false}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"mentions","component":"Row","justify":"spaceBetween","align":"center","children":["mentions_label","mentions_switch"]}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"mentions_label","component":"Text","text":"Mentions only"}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"mentions_switch","component":"LayerToggle","label":"Mentions only","value":true}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"divider","component":"Divider"}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"quiet","component":"Row","justify":"spaceBetween","align":"center","children":["quiet_label","quiet_hours"]}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"quiet_label","component":"Text","text":"Quiet hours"}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"quiet_hours","component":"Text","text":"22:00 – 07:00","variant":"caption"}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"turn_off","component":"Button","child":"turn_off_label","variant":"borderless","action":{"event":{"name":"turnOffAllNotifications"}}}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"turn_off_label","component":"Text","text":"Turn off all notifications"}]}}

        ---

        {"version":"1.0","createSurface":{"surfaceId":"screen","catalogId":"urn:layer:a2ui:catalog:1"}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"root","component":"Column","children":["photo","about","details","actions"]}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"photo","component":"Image","url":"","description":"A black cast-iron skillet"}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"about","component":"Column","children":["name","summary"]}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"name","component":"Text","text":"## Cast-iron skillet, 26 cm"}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"summary","component":"Text","text":"Pre-seasoned and oven-safe. Ships in two days."}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"details","component":"Card","child":"details_rows"}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"details_rows","component":"Column","children":["size","colour"]}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"size","component":"Row","justify":"spaceBetween","align":"center","children":["size_label","size_value"]}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"size_label","component":"Text","text":"Size"}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"size_value","component":"Text","text":"26 cm"}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"colour","component":"Row","justify":"spaceBetween","align":"center","children":["colour_label","colour_value"]}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"colour_label","component":"Text","text":"Colour"}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"colour_value","component":"Text","text":"Black"}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"actions","component":"Column","children":["add","save"]}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"add","component":"Button","child":"add_label","variant":"primary","action":{"event":{"name":"addToBag"}}}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"add_label","component":"Text","text":"Add to bag"}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"save","component":"Button","child":"save_label","variant":"borderless","action":{"event":{"name":"saveForLater"}}}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"save_label","component":"Text","text":"Save for later"}]}}

        What makes a screen good:
        - Give it one job and build it around that. Its heading names the job in plain words.
        - Shape it for the job instead of a heading, a paragraph and a button every time: settings are Rows of a Text and a LayerToggle; a profile starts with an Image of variant avatar; an article or a product starts with an Image; a form is its TextFields, then its action.
        - One primary action, written as the only Button with variant primary, usually last. Every other Button is default or borderless. Of two side by side, the less important one is borderless.
        - Write real copy for this product. A TextField's label names what goes in it ("Card number"). A Button's words are a verb that says what happens ("Save address", not "Submit" or "OK"). Never lorem ipsum, "Placeholder", "Button" or "Click here".
        - Sample content such as a name, a date or a price is fine. Invented claims are not: no "10× faster", no "trusted by thousands", no ratings or counts the description didn't give.
        - Leave colour, size and spacing to the design: write none of them, and no @metadata.
        - Make hierarchy with the heading and variant caption, not colour: one heading, Text for whatever explains, variant caption for small print.
        - Group into sections, each a Column, Row, Card or LayerGrid in the root: a form's fields together, a list's rows together. Two to four sections.
        - Show 5 to 14 things, such as Text, Image, Button and TextField; the Columns, Rows and Cards that hold them don't count. Fewer, better things beat a crowded screen.
        """
}
