/// What the harness asks for: the 8 briefs every screen benchmark has used since 2026-11-18,
/// and one canned answer in each format for `check`, which runs no model.
enum Briefs {
    static let all = [
        "a settings screen for a podcast app",
        "a recipe detail screen",
        "a checkout screen for a coffee subscription",
        "a profile screen for a running app",
        "an empty inbox",
        "a sign-in screen",
        "a weather dashboard",
        "a habit tracker home screen",
    ]

    /// An outline as the on-device model writes one, for the first brief.
    static let cannedOutline = """
        title: Playback

        row: text: Skip silence | toggle [on]
        row: text: Download on Wi-Fi only | toggle [on]
        row: text: Playback speed | text: 1.2× [right, text grey]

        card:
          text: Storage [semibold]
          body: 2.4 GB of episodes on this iPad.

        button: Clear downloads
        button: Sign out [plain]
        """

    /// The same screen as a hosted model writes it in A2UI, a message per line.
    static let cannedA2UI = #"""
        {"version":"1.0","createSurface":{"surfaceId":"screen","catalogId":"urn:layer:a2ui:catalog:1"}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"root","component":"Column","children":["heading","options","storage","actions"]},{"id":"heading","component":"Text","text":"## Playback"}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"options","component":"Column","children":["skip","wifi"]},{"id":"skip","component":"Row","justify":"spaceBetween","align":"center","children":["skip_label","skip_switch"]},{"id":"skip_label","component":"Text","text":"Skip silence"},{"id":"skip_switch","component":"LayerToggle","label":"Skip silence","value":true}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"wifi","component":"Row","justify":"spaceBetween","align":"center","children":["wifi_label","wifi_switch"]},{"id":"wifi_label","component":"Text","text":"Download on Wi-Fi only"},{"id":"wifi_switch","component":"LayerToggle","label":"Download on Wi-Fi only","value":true}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"storage","component":"Card","child":"storage_text"},{"id":"storage_text","component":"Column","children":["storage_title","storage_body"]},{"id":"storage_title","component":"Text","text":"Storage"},{"id":"storage_body","component":"Text","text":"2.4 GB of episodes on this iPad."}]}}
        {"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"actions","component":"Column","children":["clear","sign_out"]},{"id":"clear","component":"Button","child":"clear_label","variant":"primary","action":{"event":{"name":"clearDownloads"}}},{"id":"clear_label","component":"Text","text":"Clear downloads"},{"id":"sign_out","component":"Button","child":"sign_out_label","variant":"borderless","action":{"event":{"name":"signOut"}}},{"id":"sign_out_label","component":"Text","text":"Sign out"}]}}
        """#
}
