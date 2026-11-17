import Foundation
@_weakLinked import FoundationModels

let oldInstructions = """
    You design phone app screens for a wireframing tool. Given a description of a screen, \
    write its elements one per line, from top to bottom, in this form:

    kind: words [look]

    Kinds: title, body, button, text field, image, symbol, divider, toggle, checkbox, radio, \
    progress, avatar, text. Start a line with "row:" and separate elements with "|" to put \
    them side by side. A blank line starts a new section. Square brackets are optional and \
    hold the look: a colour name, bold, a size such as 18pt, radius 12, on or off, 40% for a \
    progress bar, bordered or plain for a button.

    Example:
    title: Welcome back
    body: Sign in to continue
    text field: Email
    text field: Password
    button: Sign in [blue]
    row: button: Forgot password? [plain] | button: Create account [plain]

    Write only the lines: no introduction, no explanation, no markdown. Use 4 to 12 lines.
    """

let briefs = [
    "a settings screen for a podcast app",
    "a recipe detail screen",
    "a checkout screen for a coffee subscription",
    "a profile screen for a running app",
    "an empty inbox",
    "a sign-in screen",
    "a weather dashboard",
    "a habit tracker home screen",
]

struct Score { var filled = 0; var coloured = 0; var slop = 0; var kinds = 0; var lines = 0; var welcome = 0; var copied = 0; var parsed = 0; var oneAfterPolish = 0; var kindLeak = 0 }

func lowered0(_ t: String) -> String { t.lowercased() }
func score(_ text: String) -> Score {
    var s = Score()
    let kept = text.components(separatedBy: "\n").filter { !$0.hasPrefix("```") && !$0.hasPrefix("#") }.joined(separator: "\n")
    guard let bp = ScreenBlueprint.parse(kept) else { return s }
    s.parsed = 1
    let items = bp.sections.flatMap(\.items)
    s.lines = items.count
    s.kinds = Set(items.map(\.kind)).count
    s.filled = items.filter { $0.kind == .button && ($0.buttonLook == nil || $0.buttonLook == .filled) }.count
    let after = bp.withOnePrimaryAction().sections.flatMap(\.items).filter { $0.kind == .button && ($0.buttonLook == nil || $0.buttonLook == .filled) }.count
    s.oneAfterPolish = (after == 1 || !items.contains { $0.kind == .button }) ? 1 : 0
    s.kindLeak = lowered0(text).contains("kind:") ? 1 : 0
    s.coloured = items.filter { $0.colour != nil }.count
    let lowered = text.lowercased()
    s.slop = ["placeholder", "lorem", "submit", "click here", "button:  ", "trusted by", "10x", "10×"].filter { lowered.contains($0) }.count
    s.welcome = items.first.map { $0.kind == .title && $0.text.lowercased().hasPrefix("welcome") } == true ? 1 : 0
    for ex in ScreenPrompt.library { if ex.lines.split(separator: "\n").contains(where: { l in l.count > 12 && text.contains(l.trimmingCharacters(in: .whitespaces)) }) { s.copied = 1 } }
    return s
}

@main struct Bench {
    static func main() async throws {
        let runs = Int(CommandLine.arguments.dropFirst().first ?? "1") ?? 1
        for (label, make) in [("OLD", { (_: String) in oldInstructions }), ("NEW", { (b: String) in ScreenPrompt.instructions(.compact, for: b) })] {
            var total = Score(); var count = 0; var screensWithManyFilled = 0
            for brief in briefs {
                for _ in 0..<runs {
                    let session = LanguageModelSession(instructions: make(brief))
                    let text: String
                    do { text = try await session.respond(to: brief, options: GenerationOptions(temperature: 0.7)).content } catch { print("ERR", brief, error); continue }
                    let s = score(text)
                    print("=== \(label) · \(brief)\n\(text)\n--- filled=\(s.filled) coloured=\(s.coloured) slop=\(s.slop) kinds=\(s.kinds) items=\(s.lines) welcome=\(s.welcome) copied=\(s.copied)\n")
                    total.filled += s.filled; total.coloured += s.coloured; total.slop += s.slop; total.kinds += s.kinds; total.lines += s.lines; total.welcome += s.welcome; total.copied += s.copied; total.parsed += s.parsed; total.oneAfterPolish += s.oneAfterPolish; total.kindLeak += s.kindLeak
                    if s.filled > 1 { screensWithManyFilled += 1 }
                    count += 1
                }
            }
            print("SUMMARY \(label): screens=\(count) parsed=\(total.parsed) screens>1filled=\(screensWithManyFilled) avgFilled=\(Double(total.filled)/Double(count)) colouredItems=\(total.coloured) slopHits=\(total.slop) avgKinds=\(Double(total.kinds)/Double(count)) avgItems=\(Double(total.lines)/Double(count)) welcomeTitles=\(total.welcome) copiedExample=\(total.copied) onePrimaryAfterPolish=\(total.oneAfterPolish) kindLeak=\(total.kindLeak)")
        }
    }
}
