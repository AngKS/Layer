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

    /// The A2UI prompt hosted models are told. Plan 6 measures it, and changes this literal when it changes the words.
    @Test func theA2UIPromptIsUnchanged() {
        #expect(A2UIPrompt.instructions(for: Self.brief) == Self.a2ui)
    }

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
        - Most lines need no look. Looks: filled, bordered or plain for a button; bold or semibold; a size such as 28pt; text grey for quieter words; a colour name; on or off; 40% for a progress bar; left, centre or right.

        Write only the lines: no introduction, no explanation, no markdown.

        An example of the form. Write your own content; don't copy it:

        title: Notifications

        row: text: Push notifications | toggle [on]
        row: text: Daily summary | toggle [off]
        row: text: Mentions only | toggle [on]
        divider
        row: text: Quiet hours | text: 22:00 – 07:00 [right, text grey]

        button: Turn off all notifications [plain, red]

        Rules:
        - Write words for this exact product, not the example's.
        - Shape the screen for its job: settings are rows of text and a toggle, a profile starts with an avatar, an article starts with an image, a form is fields then one button. Details that belong together, such as a summary or a set of figures, go in a card: or a grid 2:.
        - The main action is one button with no look, so it is filled. Other buttons are [bordered] or [plain].
        - Real, specific words such as "Card number" or "Save address". Never "Placeholder", "Submit" or lorem ipsum. No invented claims or ratings.
        - No colour words, not even blue, red or grey, unless the description names a colour. Quieter words are text grey.
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
        - Most lines need no look. Looks: filled, bordered or plain for a button; bold or semibold; a size such as 28pt; text grey for quieter words; a colour name; on or off; 40% for a progress bar; left, centre or right.

        Write only the lines: no introduction, no explanation, no markdown.

        Examples of the form, one screen each. Write your own content; don't copy them:

        title: Notifications

        row: text: Push notifications | toggle [on]
        row: text: Daily summary | toggle [off]
        row: text: Mentions only | toggle [on]
        divider
        row: text: Quiet hours | text: 22:00 – 07:00 [right, text grey]

        button: Turn off all notifications [plain, red]

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

        Each line after it is an updateComponents message that adds the next part of the screen, from top to bottom:
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[…]}}
        The first holds the root: a Column with the id root, whose children are the ids of the screen's sections, in order. Each one after it adds the next section: the component the root names, and what it holds.

        Every component has an id, its own on the screen, and a component. Use only these:
        - Column: children, a list of ids, from top to bottom.
        - Row: children, side by side. align center lines them up; justify spaceBetween puts them at both ends.
        - Card: child, the id of one component, usually a Column.
        - LayerGrid: children, filled row by row, and columns, a whole number from 1 to 12, which is required.
        - Text: text. "# " or "## " before the words makes the screen's heading; variant caption is for small print.
        - Image: url "" and a description of what it shows; variant avatar for a person.
        - Icon: name, one of A2UI's icon names, such as search, settings or favorite.
        - LayerSymbol: name, an SF Symbol name, such as bell or gearshape.
        - Button: child, the id of a Text with its words; variant primary, default or borderless; and action.
        - TextField: label, saying what goes in it, and value "".
        - CheckBox, LayerToggle and LayerRadio: label, and value true or false.
        - LayerProgress: value, from 0 to 1.
        - Divider.

        Every value is a literal, written out: no @path, no @call. A button's action is {"event":{"name":"<verb>"}}.

        Examples of the form, one screen each. Write your own content; don't copy them:

        {"version":"1.0","createSurface":{"surfaceId":"screen","catalogId":"urn:layer:a2ui:catalog:1"}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"root","component":"Column","children":["heading","alerts","turn_off"]},{"id":"heading","component":"Text","text":"## Notifications"}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"alerts","component":"Column","children":["push","summary","mentions","divider","quiet"]},{"id":"push","component":"Row","justify":"spaceBetween","align":"center","children":["push_label","push_switch"]},{"id":"push_label","component":"Text","text":"Push notifications"},{"id":"push_switch","component":"LayerToggle","label":"Push notifications","value":true}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"summary","component":"Row","justify":"spaceBetween","align":"center","children":["summary_label","summary_switch"]},{"id":"summary_label","component":"Text","text":"Daily summary"},{"id":"summary_switch","component":"LayerToggle","label":"Daily summary","value":false}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"mentions","component":"Row","justify":"spaceBetween","align":"center","children":["mentions_label","mentions_switch"]},{"id":"mentions_label","component":"Text","text":"Mentions only"},{"id":"mentions_switch","component":"LayerToggle","label":"Mentions only","value":true}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"divider","component":"Divider"},{"id":"quiet","component":"Row","justify":"spaceBetween","align":"center","children":["quiet_label","quiet_hours"]},{"id":"quiet_label","component":"Text","text":"Quiet hours"},{"id":"quiet_hours","component":"Text","text":"22:00 – 07:00","variant":"caption"}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"turn_off","component":"Button","child":"turn_off_label","variant":"borderless","action":{"event":{"name":"turnOffAllNotifications"}}},{"id":"turn_off_label","component":"Text","text":"Turn off all notifications"}]}}

        ---

        {"version":"1.0","createSurface":{"surfaceId":"screen","catalogId":"urn:layer:a2ui:catalog:1"}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"root","component":"Column","children":["photo","about","details","actions"]},{"id":"photo","component":"Image","url":"","description":"A black cast-iron skillet"}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"about","component":"Column","children":["name","summary"]},{"id":"name","component":"Text","text":"## Cast-iron skillet, 26 cm"},{"id":"summary","component":"Text","text":"Pre-seasoned and oven-safe. Ships in two days."}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"details","component":"Card","child":"details_rows"},{"id":"details_rows","component":"Column","children":["size","colour"]},{"id":"size","component":"Row","justify":"spaceBetween","align":"center","children":["size_label","size_value"]},{"id":"size_label","component":"Text","text":"Size"},{"id":"size_value","component":"Text","text":"26 cm"}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"colour","component":"Row","justify":"spaceBetween","align":"center","children":["colour_label","colour_value"]},{"id":"colour_label","component":"Text","text":"Colour"},{"id":"colour_value","component":"Text","text":"Black"}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"actions","component":"Column","children":["add","save"]},{"id":"add","component":"Button","child":"add_label","variant":"primary","action":{"event":{"name":"addToBag"}}},{"id":"add_label","component":"Text","text":"Add to bag"},{"id":"save","component":"Button","child":"save_label","variant":"borderless","action":{"event":{"name":"saveForLater"}}},{"id":"save_label","component":"Text","text":"Save for later"}]}}

        What makes a screen good:
        - Give it one job and build it around that. Its heading names the job in plain words.
        - Shape it for the job instead of a heading, a paragraph and a button every time: settings are Rows of a Text and a LayerToggle; a profile starts with an Image of variant avatar; an article or a product starts with an Image; a form is its TextFields, then its action.
        - One primary action, written as the only Button with variant primary, usually last. Every other Button is default or borderless. Of two side by side, the less important one is borderless.
        - Write real copy for this product. A TextField's label names what goes in it ("Card number"). A Button's words are a verb that says what happens ("Save address", not "Submit" or "OK"). Never lorem ipsum, "Placeholder", "Button" or "Click here".
        - Sample content such as a name, a date or a price is fine. Invented claims are not: no "10× faster", no "trusted by thousands", no ratings or counts the description didn't give.
        - Leave colour, size and spacing to the design: write none of them, and no @metadata.
        - Make hierarchy with the heading and variant caption, not colour: one heading, Text for whatever explains, variant caption for small print.
        - Group into sections, each a Column, Row, Card or LayerGrid in the root: a form's fields together, a list's rows together. Two to four sections.
        - Use 5 to 14 components that show something, such as Text, Image, Button and TextField. Fewer, better elements beat a crowded screen.
        """
}
