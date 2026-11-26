import Foundation

/// What a model is told when it is asked to write a whole screen in A2UI 1.0 (spec §6, call 9): Layer's catalogue, a
/// message per line, so the screen is shown growing as each line is finished (`A2UIStream`).
///
/// A model writes A2UI only when a caller asks for it (`ScreenGenerator.stream(_:format:)`): every model writes the
/// outline by default (`ScreenGenerator.format(for:)`, plan 6's measure and 2026-11-26's). The prompt is always the
/// full one: the form, a component a line, two examples chosen for the description as `ScreenPrompt.examples` chooses
/// the outline's, and today's rules in A2UI's words. It names no spacing, size or colour: Layer's tokens set them, and
/// a model's Layer look is ignored (§14). It builds on macOS, for the screen harness.
enum A2UIPrompt {
    /// The surface a model writes its screen on.
    static let surfaceID = "screen"

    /// The temperature a screen in A2UI is asked for at (`ScreenGenerator`), where a provider takes one
    /// (`HostedModelClient`): lower than a model's own, often 1, so a slip inside a line's JSON is less likely
    /// (2026-11-26, docs/benchmarks/screen-prompt.md).
    static let temperature = 0.5

    static func instructions(for description: String) -> String {
        let shown = examples(for: description).map(\.lines).joined(separator: "\n\n---\n\n")
        // Rules last, as in the outline's prompt: a model follows best what it read most recently.
        return [
            "You design phone app screens for a wireframing tool. Given a description of a screen, write it down in A2UI.",
            form,
            "Examples of the form, one screen each. Write your own content; don't copy them:\n\n\(shown)",
            rules,
        ].joined(separator: "\n\n")
    }

    /// How a screen is written in A2UI, and the components that map well to Layer's kinds.
    static var form: String {
        """
        Write A2UI 1.0 messages, one JSON object per line and nothing else: no introduction, no explanation, no markdown.

        The first line creates the screen's surface:
        \(createSurface)

        Each line after it is an updateComponents message holding one component, the next part of the screen, from \
        top to bottom:
        \(message(#"{"id":"…","component":"…",…}"#))
        The first holds the root: a Column with the id root, whose children are the ids of the screen's sections, in \
        order. Then each section the root names, each followed by what it holds, a line for each component. Every id \
        a component names has a line of its own. A line closes its own component and the message, nothing more: it \
        never adds ]} to close the Column or Row it is in, even for the last thing that Column or Row holds.

        Every component has an id and a component. An id says what its component is, in words joined by underscores, \
        such as total_label or pace_value, and no two components share one. Use only these:
        - Column: children, a list of ids, from top to bottom.
        - Row: children, side by side. align center lines them up; justify spaceBetween puts them at both ends.
        - Card: child, the id of one component, usually a Column.
        - LayerGrid: children, filled row by row, and columns, a whole number from 1 to 12, which is required.
        - Text: text. "# " or "## " before the words makes the screen's heading; variant caption is for small print.
        - Image: url "" and a description of what it shows; variant avatar for a person.
        - LayerSymbol: name, an SF Symbol name, such as bell, gearshape or chevron.right. Every icon is one.
        - Button: child, the id of a Text with its words; variant primary, default or borderless; and action.
        - TextField: label, saying what goes in it, and value "".
        - CheckBox, LayerToggle and LayerRadio: label, always, even beside a Text that says the same, and value true \
        or false.
        - LayerProgress: value, from 0 to 1.
        - Divider.

        Every value is a literal, written out: no @path, no @call. A button's action is {"event":{"name":"<verb>"}}.
        """
    }

    /// What makes a written screen good: `ScreenPrompt`'s rules for hosted models, in A2UI's words.
    static var rules: String {
        """
        What makes a screen good:
        - Give it one job and build it around that. Its heading names the job in plain words.
        - Shape it for the job instead of a heading, a paragraph and a button every time: settings are Rows of a Text \
        and a LayerToggle; a profile starts with an Image of variant avatar; an article or a product starts with an \
        Image; a form is its TextFields, then its action.
        - One primary action, written as the only Button with variant primary, usually last. Every other Button is \
        default or borderless. Of two side by side, the less important one is borderless.
        - Write real copy for this product. A TextField's label names what goes in it ("Card number"). A Button's \
        words are a verb that says what happens ("Save address", not "Submit" or "OK"). Never lorem ipsum, \
        "Placeholder", "Button" or "Click here".
        - Sample content such as a name, a date or a price is fine. Invented claims are not: no "10× faster", no \
        "trusted by thousands", no ratings or counts the description didn't give.
        - Leave colour, size and spacing to the design: write none of them, and no @metadata.
        - Make hierarchy with the heading and variant caption, not colour: one heading, Text for whatever explains, \
        variant caption for small print.
        - Group into sections, each a Column, Row, Card or LayerGrid in the root: a form's fields together, a list's \
        rows together. Two to four sections.
        - Show 5 to 14 things, such as Text, Image, Button and TextField; the Columns, Rows and Cards that hold them \
        don't count. Fewer, better things beat a crowded screen.
        """
    }

    // MARK: Examples

    /// The two examples that suit `description` best, chosen as the outline's are.
    private static func examples(for description: String) -> [ScreenPrompt.Example] {
        ScreenPrompt.examples(for: description, count: 2).compactMap { chosen in
            library.first { $0.name == chosen.name }
        }
    }

    /// The outline library's six screens as A2UI JSON lines, by the same names, with the same elements in the same
    /// order: a message per line and a component per message, the root first, then each section followed by what it
    /// holds. Every broken line in plan 3's and 2026-11-26's runs held several components, and plan 6's were all long
    /// (docs/benchmarks/screen-prompt.md).
    static let library: [ScreenPrompt.Example] = [
        example("settings", lines(
            #"{"id":"root","component":"Column","children":["heading","alerts","turn_off"]}"#,
            ###"{"id":"heading","component":"Text","text":"## Notifications"}"###,
            #"{"id":"alerts","component":"Column","children":["push","summary","mentions","divider","quiet"]}"#,
            #"{"id":"push","component":"Row","justify":"spaceBetween","align":"center","children":["push_label","push_switch"]}"#,
            #"{"id":"push_label","component":"Text","text":"Push notifications"}"#,
            #"{"id":"push_switch","component":"LayerToggle","label":"Push notifications","value":true}"#,
            #"{"id":"summary","component":"Row","justify":"spaceBetween","align":"center","children":["summary_label","summary_switch"]}"#,
            #"{"id":"summary_label","component":"Text","text":"Daily summary"}"#,
            #"{"id":"summary_switch","component":"LayerToggle","label":"Daily summary","value":false}"#,
            #"{"id":"mentions","component":"Row","justify":"spaceBetween","align":"center","children":["mentions_label","mentions_switch"]}"#,
            #"{"id":"mentions_label","component":"Text","text":"Mentions only"}"#,
            #"{"id":"mentions_switch","component":"LayerToggle","label":"Mentions only","value":true}"#,
            #"{"id":"divider","component":"Divider"}"#,
            #"{"id":"quiet","component":"Row","justify":"spaceBetween","align":"center","children":["quiet_label","quiet_hours"]}"#,
            #"{"id":"quiet_label","component":"Text","text":"Quiet hours"}"#,
            #"{"id":"quiet_hours","component":"Text","text":"22:00 – 07:00","variant":"caption"}"#,
            #"{"id":"turn_off","component":"Button","child":"turn_off_label","variant":"borderless","action":{"event":{"name":"turnOffAllNotifications"}}}"#,
            #"{"id":"turn_off_label","component":"Text","text":"Turn off all notifications"}"#
        )),
        example("product", lines(
            #"{"id":"root","component":"Column","children":["photo","about","details","actions"]}"#,
            #"{"id":"photo","component":"Image","url":"","description":"A black cast-iron skillet"}"#,
            #"{"id":"about","component":"Column","children":["name","summary"]}"#,
            ###"{"id":"name","component":"Text","text":"## Cast-iron skillet, 26 cm"}"###,
            #"{"id":"summary","component":"Text","text":"Pre-seasoned and oven-safe. Ships in two days."}"#,
            #"{"id":"details","component":"Card","child":"details_rows"}"#,
            #"{"id":"details_rows","component":"Column","children":["size","colour"]}"#,
            #"{"id":"size","component":"Row","justify":"spaceBetween","align":"center","children":["size_label","size_value"]}"#,
            #"{"id":"size_label","component":"Text","text":"Size"}"#,
            #"{"id":"size_value","component":"Text","text":"26 cm"}"#,
            #"{"id":"colour","component":"Row","justify":"spaceBetween","align":"center","children":["colour_label","colour_value"]}"#,
            #"{"id":"colour_label","component":"Text","text":"Colour"}"#,
            #"{"id":"colour_value","component":"Text","text":"Black"}"#,
            #"{"id":"actions","component":"Column","children":["add","save"]}"#,
            #"{"id":"add","component":"Button","child":"add_label","variant":"primary","action":{"event":{"name":"addToBag"}}}"#,
            #"{"id":"add_label","component":"Text","text":"Add to bag"}"#,
            #"{"id":"save","component":"Button","child":"save_label","variant":"borderless","action":{"event":{"name":"saveForLater"}}}"#,
            #"{"id":"save_label","component":"Text","text":"Save for later"}"#
        )),
        example("profile", lines(
            #"{"id":"root","component":"Column","children":["person","work"]}"#,
            #"{"id":"person","component":"Column","children":["avatar","name","bio","contact"]}"#,
            #"{"id":"avatar","component":"Image","url":"","variant":"avatar","description":"Maya Okafor"}"#,
            ###"{"id":"name","component":"Text","text":"## Maya Okafor"}"###,
            #"{"id":"bio","component":"Text","text":"Ceramicist in Lisbon. Small-batch tableware."}"#,
            #"{"id":"contact","component":"Row","align":"center","children":["follow","message"]}"#,
            #"{"id":"follow","component":"Button","child":"follow_label","variant":"primary","action":{"event":{"name":"follow"}}}"#,
            #"{"id":"follow_label","component":"Text","text":"Follow"}"#,
            #"{"id":"message","component":"Button","child":"message_label","variant":"default","action":{"event":{"name":"message"}}}"#,
            #"{"id":"message_label","component":"Text","text":"Message"}"#,
            #"{"id":"work","component":"Column","children":["work_heading","work_grid"]}"#,
            #"{"id":"work_heading","component":"Text","text":"Recent work"}"#,
            #"{"id":"work_grid","component":"LayerGrid","columns":3,"children":["bowl","plate","mug","vase","jug","cup"]}"#,
            #"{"id":"bowl","component":"Image","url":"","description":"A speckled bowl"}"#,
            #"{"id":"plate","component":"Image","url":"","description":"A blue-rimmed plate"}"#,
            #"{"id":"mug","component":"Image","url":"","description":"A stoneware mug"}"#,
            #"{"id":"vase","component":"Image","url":"","description":"A tall glazed vase"}"#,
            #"{"id":"jug","component":"Image","url":"","description":"A cream jug"}"#,
            #"{"id":"cup","component":"Image","url":"","description":"A handleless cup"}"#
        )),
        example("form", lines(
            #"{"id":"root","component":"Column","children":["heading","address","billing","next"]}"#,
            ###"{"id":"heading","component":"Text","text":"## Delivery address"}"###,
            #"{"id":"address","component":"Column","children":["full_name","street","town","phone"]}"#,
            #"{"id":"full_name","component":"TextField","label":"Full name","value":""}"#,
            #"{"id":"street","component":"TextField","label":"Street and number","value":""}"#,
            #"{"id":"town","component":"Row","children":["postcode","city"]}"#,
            #"{"id":"postcode","component":"TextField","label":"Postcode","value":""}"#,
            #"{"id":"city","component":"TextField","label":"City","value":""}"#,
            #"{"id":"phone","component":"TextField","label":"Phone, for the courier","value":""}"#,
            #"{"id":"billing","component":"Row","justify":"spaceBetween","align":"center","children":["billing_label","billing_switch"]}"#,
            #"{"id":"billing_label","component":"Text","text":"Same address for billing"}"#,
            #"{"id":"billing_switch","component":"LayerToggle","label":"Same address for billing","value":true}"#,
            #"{"id":"next","component":"Button","child":"next_label","variant":"primary","action":{"event":{"name":"continueToPayment"}}}"#,
            #"{"id":"next_label","component":"Text","text":"Continue to payment"}"#
        )),
        example("empty", lines(
            #"{"id":"root","component":"Column","children":["message","browse"]}"#,
            #"{"id":"message","component":"Column","children":["tray","heading","explanation"]}"#,
            #"{"id":"tray","component":"LayerSymbol","name":"tray"}"#,
            ###"{"id":"heading","component":"Text","text":"## No orders yet"}"###,
            #"{"id":"explanation","component":"Text","text":"When you buy something, it shows up here with its tracking."}"#,
            #"{"id":"browse","component":"Button","child":"browse_label","variant":"primary","action":{"event":{"name":"browseTheShop"}}}"#,
            #"{"id":"browse_label","component":"Text","text":"Browse the shop"}"#
        )),
        example("sign in", lines(
            #"{"id":"root","component":"Column","children":["intro","fields","links"]}"#,
            #"{"id":"intro","component":"Column","children":["heading","subtitle"]}"#,
            ###"{"id":"heading","component":"Text","text":"## Sign in to Fieldnote"}"###,
            #"{"id":"subtitle","component":"Text","text":"Pick up your notes where you left them."}"#,
            #"{"id":"fields","component":"Column","children":["email","password","sign_in"]}"#,
            #"{"id":"email","component":"TextField","label":"Email","value":""}"#,
            #"{"id":"password","component":"TextField","label":"Password","value":""}"#,
            #"{"id":"sign_in","component":"Button","child":"sign_in_label","variant":"primary","action":{"event":{"name":"signIn"}}}"#,
            #"{"id":"sign_in_label","component":"Text","text":"Sign in"}"#,
            #"{"id":"links","component":"Row","justify":"spaceBetween","children":["forgot","create"]}"#,
            #"{"id":"forgot","component":"Button","child":"forgot_label","variant":"borderless","action":{"event":{"name":"resetPassword"}}}"#,
            #"{"id":"forgot_label","component":"Text","text":"Forgot password?"}"#,
            #"{"id":"create","component":"Button","child":"create_label","variant":"borderless","action":{"event":{"name":"createAccount"}}}"#,
            #"{"id":"create_label","component":"Text","text":"Create account"}"#
        )),
    ]

    // MARK: Writing messages

    /// The line that creates the screen's surface on Layer's catalogue.
    private static var createSurface: String {
        #"{"version":"1.0","createSurface":{"surfaceId":"\#(surfaceID)","catalogId":"\#(LayerCatalog.id)"}}"#
    }

    /// An updateComponents line adding `components`, written as JSON: the examples' lines each add one.
    private static func message(_ components: String) -> String {
        #"{"version":"1.0","updateComponents":{"surfaceId":"\#(surfaceID)","components":[\#(components)]}}"#
    }

    /// A screen as a model writes it: the surface, then a message for each component.
    private static func lines(_ components: String...) -> String {
        ([createSurface] + components.map(message)).joined(separator: "\n")
    }

    /// The library screen `name` in A2UI, picked by the outline example's keywords.
    private static func example(_ name: String, _ lines: String) -> ScreenPrompt.Example {
        ScreenPrompt.Example(name: name, keywords: ScreenPrompt.library.first { $0.name == name }?.keywords ?? [], lines: lines)
    }
}
