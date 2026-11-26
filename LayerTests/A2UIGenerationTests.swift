import Foundation
@_weakLinked import FoundationModels
import Testing
@testable import Layer

/// A model asked for A2UI 1.0 writes a screen a message per line, read as it comes (plan 3, Task 6). Every model writes
/// the outline by default since plan 6's measure (`ScreenGenerator.hostedFormat`).
@Suite("Screens written in A2UI")
struct A2UIGenerationTests {
    static let createSurface = #"{"version":"1.0","createSurface":{"surfaceId":"screen","catalogId":"urn:layer:a2ui:catalog:1"}}"#

    /// One `updateComponents` line holding `components`.
    static func update(_ components: String) -> String {
        #"{"version":"1.0","updateComponents":{"surfaceId":"screen","components":["# + components + "]}}"
    }

    /// A sign-in screen a message at a time: the surface; the root with its title; the email field; the button.
    static let signIn = [
        createSurface,
        update(###"{"id":"root","component":"Column","children":["title","email","go"]},{"id":"title","component":"Text","text":"## Sign in"}"###),
        update(#"{"id":"email","component":"TextField","label":"Email","value":""}"#),
        update(#"{"id":"go","component":"Button","child":"go_label","variant":"primary","action":{"event":{"name":"signIn"}}},{"id":"go_label","component":"Text","text":"Sign in"}"#),
    ]

    /// The login screen pretty-printed, as a model that ignores "one message per line" writes it: one payload over
    /// many lines, some of them bare strings, such as the children's last id `"go"`.
    static let prettyLogin = """
        [
          {
            "version": "1.0",
            "createSurface": {
              "surfaceId": "screen",
              "catalogId": "urn:layer:a2ui:catalog:1"
            }
          },
          {
            "version": "1.0",
            "updateComponents": {
              "surfaceId": "screen",
              "components": [
                {
                  "id": "root",
                  "component": "Column",
                  "children": [
                    "title",
                    "email",
                    "password",
                    "go"
                  ]
                },
                {
                  "id": "title",
                  "component": "Text",
                  "text": "## Sign in"
                },
                {
                  "id": "email",
                  "component": "TextField",
                  "label": "Email",
                  "value": ""
                },
                {
                  "id": "password",
                  "component": "TextField",
                  "label": "Password",
                  "value": ""
                },
                {
                  "id": "go",
                  "component": "Button",
                  "child": "go_label",
                  "variant": "primary",
                  "action": {
                    "event": {
                      "name": "signIn"
                    }
                  }
                },
                {
                  "id": "go_label",
                  "component": "Text",
                  "text": "Sign in"
                }
              ]
            }
          }
        ]
        """

    // MARK: - The stream

    @Test func aScreenGrowsMessageByMessage() throws {
        var stream = A2UIStream(tokens: .standard)
        var text = ""
        var roots: [LayerNode?] = []
        for line in Self.signIn {
            text += line + "\n"
            roots.append(stream.take(text, isComplete: false))
        }
        // The surface alone has no root to show.
        #expect(roots[0] == nil)
        #expect(roots.dropFirst().map { $0.map { leaves($0).map(\.kind) } } == [[.title], [.title, .textField], [.title, .textField, .button]])
        let last = try #require(roots.compactMap { $0 }.last)
        #expect(leaves(last).map { $0.source?.key } == ["title", "email", "go"])
        // Nothing more is written, so there's nothing new to show.
        let done = stream.take(text, isComplete: true)
        #expect(done == nil)
    }

    @Test func aHalfWrittenLastLineWaits() throws {
        let finished = Self.signIn[0] + "\n" + Self.signIn[1] + "\n"
        let half = finished + Self.signIn[2].prefix(40)
        var stream = A2UIStream(tokens: .standard)
        let first = stream.take(half, isComplete: false)
        #expect(first.map { leaves($0).map(\.kind) } == [.title])
        let more = stream.take(half + Self.signIn[2].dropFirst(40).prefix(10), isComplete: false)
        #expect(more == nil, "the line isn't finished yet")
        let next = stream.take(finished + Self.signIn[2] + "\n", isComplete: false)
        #expect(next.map { leaves($0).map(\.kind) } == [.title, .textField])
        let whole = stream.take(Self.signIn.joined(separator: "\n"), isComplete: true)
        #expect(whole.map { leaves($0).map(\.kind) } == [.title, .textField, .button])
        // The half-written line was waited for, never reported.
        #expect(!stream.diagnostics.contains { $0.reason == .parseFailed })
    }

    @Test func aBrokenLineIsSkippedAndReported() throws {
        let lines = [Self.createSurface, #"{"version":"1.0","updateComponents":{"#, Self.signIn[1], Self.signIn[2]]
        var stream = A2UIStream(tokens: .standard)
        let taken = stream.take(lines.joined(separator: "\n"), isComplete: true)
        let root = try #require(taken)
        #expect(leaves(root).map(\.kind) == [.title, .textField])
        let failed = stream.diagnostics.filter { $0.reason == .parseFailed }
        #expect(failed.count == 1)
        #expect(failed.first?.path == "line 2")
    }

    @Test func aPrettyPrintedAnswerStillMakesAScreenAtTheEnd() throws {
        let lines = Self.prettyLogin.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.contains { $0.trimmingCharacters(in: .whitespaces) == #""go""# }, "a bare string has a line of its own")
        var stream = A2UIStream(tokens: .standard)
        var text = ""
        for line in lines {
            text += line + "\n"
            let taken = stream.take(text, isComplete: false)
            #expect(taken == nil, "no line of it is a message: \(line)")
        }
        let taken = stream.take(Self.prettyLogin, isComplete: true)
        let root = try #require(taken)
        #expect(root.leafCount == 4)
        #expect(leaves(root).map(\.kind) == [.title, .textField, .textField, .button])
        // Its lines were parts of the one payload that made the screen, so none is reported.
        #expect(!stream.diagnostics.contains { $0.reason == .parseFailed }, "\(stream.diagnostics)")
    }

    @Test(arguments: [#""go""#, "1", "null"])
    func aBareValueLineIsNotAMessage(_ line: String) throws {
        var alone = A2UIStream(tokens: .standard)
        let nothing = alone.take(line, isComplete: true)
        #expect(nothing == nil)
        #expect(alone.diagnostics.contains { $0.reason == .parseFailed })

        // Among messages, it's skipped and reported by its line; the importer never sees it.
        var among = A2UIStream(tokens: .standard)
        let taken = among.take([Self.signIn[0], Self.signIn[1], line, Self.signIn[2]].joined(separator: "\n"), isComplete: true)
        let root = try #require(taken)
        #expect(leaves(root).map(\.kind) == [.title, .textField])
        #expect(among.diagnostics.filter { $0.reason == .parseFailed }.map(\.path) == ["line 3"])
    }

    @Test func fencesAroundTheLinesAreIgnored() throws {
        let fenced = "```json\n" + Self.signIn.joined(separator: "\n") + "\n```\n"
        var stream = A2UIStream(tokens: .standard)
        let soFar = stream.take("```json\n" + Self.signIn[0] + "\n" + Self.signIn[1] + "\n", isComplete: false)
        #expect(soFar.map { leaves($0).map(\.kind) } == [.title])
        let taken = stream.take(fenced, isComplete: true)
        let root = try #require(taken)
        #expect(leaves(root).map(\.kind) == [.title, .textField, .button])
        #expect(!stream.diagnostics.contains { $0.reason == .parseFailed }, "\(stream.diagnostics)")

        // So are blank lines between the messages, and Windows line ends.
        let spaced = ("```json\n" + Self.signIn.joined(separator: "\n\n") + "\n```\n").replacingOccurrences(of: "\n", with: "\r\n")
        var other = A2UIStream(tokens: .standard)
        let spacedTaken = other.take(spaced, isComplete: true)
        #expect(spacedTaken.map { leaves($0).map(\.kind) } == [.title, .textField, .button])
        #expect(!other.diagnostics.contains { $0.reason == .parseFailed }, "\(other.diagnostics)")
    }

    @Test func aGeneratedScreenHasOnePrimaryAction() throws {
        let lines = [
            Self.createSurface,
            Self.update(#"{"id":"root","component":"Column","children":["pay","later"]},"# +
                        #"{"id":"pay","component":"Button","child":"pay_label","variant":"primary","action":{"event":{"name":"pay"}}},"# +
                        #"{"id":"pay_label","component":"Text","text":"Pay now"},"# +
                        #"{"id":"later","component":"Button","child":"later_label","variant":"primary","action":{"event":{"name":"later"}}},"# +
                        #"{"id":"later_label","component":"Text","text":"Pay later"}"#),
        ]
        var stream = A2UIStream(tokens: .standard)
        let taken = stream.take(lines.joined(separator: "\n"), isComplete: true)
        let root = try #require(taken)
        #expect(leaves(root).map(\.content.buttonLook) == [.filled, .bordered])
    }

    @Test func aGeneratedScreensLayerLookIsIgnoredWhenStreamed() throws {
        let lines = [
            Self.createSurface,
            Self.update(#"{"id":"root","component":"Column","children":["big"]},"# +
                        #"{"id":"big","component":"Text","text":"Hi","@metadata":{"extensions":{"layer":{"style":{"fontSize":60}}}}}"#),
        ]
        var stream = A2UIStream(tokens: .standard)
        let taken = stream.take(lines.joined(separator: "\n"), isComplete: true)
        let root = try #require(taken)
        let text = try #require(leaves(root).first)
        #expect(text.content.text == "Hi")
        #expect(text.style.fontSize == nil)
    }

    @Test func actionsInAGeneratedScreenAreNeverRun() throws {
        let call = #"{"version":"1.0","callRendererFunction":{"functionCallId":"call_1","surfaceId":"screen","# +
            #""callFunction":{"@call":"openUrl","args":{"url":"https://example.com"},"catalogId":"urn:layer:a2ui:catalog:1"}}}"#
        var stream = A2UIStream(tokens: .standard)
        let taken = stream.take((Self.signIn + [call]).joined(separator: "\n"), isComplete: true)
        let root = try #require(taken)
        #expect(root.leafCount == 3)
        // Reported, never run: Layer has no action handler and no processor.
        #expect(stream.diagnostics.filter { $0.reason == .functionNotRun }.map(\.path) == ["callRendererFunction"])
        #expect(stream.diagnostics.filter { $0.reason == .actionNotRun }.map(\.componentID) == ["go"])
    }

    // MARK: - What a model writes that isn't quite A2UI (2026-11-26)

    /// A model names icons as it knows them: an SF Symbol's name, Material's `arrow_back`, or a word of its own. Each
    /// is the symbol it names, as an outline's `symbol:` line is, and nothing about it is left out.
    @Test func anIconNamedOutsideA2UIsSetIsTheSymbolItNames() throws {
        let lines = [
            Self.createSurface,
            Self.update(#"{"id":"root","component":"Column","children":["sf","material","own","known"]}"#),
            Self.update(#"{"id":"sf","component":"Icon","name":"chevron.right"}"#),
            Self.update(#"{"id":"material","component":"Icon","name":"arrow_back"}"#),
            Self.update(#"{"id":"own","component":"Icon","name":"cloud-sun"}"#),
            Self.update(#"{"id":"known","component":"Icon","name":"search"}"#),
        ]
        var stream = A2UIStream(tokens: .standard)
        let taken = stream.take(lines.joined(separator: "\n"), isComplete: true)
        let root = try #require(taken)
        #expect(leaves(root).map(\.kind) == [.symbol, .symbol, .symbol, .symbol])
        // An SF Symbol's name is kept as written; Material's spelling of an A2UI name is that name's symbol; a word of
        // the model's own is kept, and drawn as Layer draws any symbol's name (`SystemSymbol`).
        #expect(leaves(root).map(\.content.symbol) == ["chevron.right", "arrow.left", "cloud-sun", "magnifyingglass"])
        #expect(stream.diagnostics.isEmpty, "\(stream.diagnostics)")
    }

    /// Only a model's answer is read that way: A2UI from a file or a paste is someone's own, and is told as it is.
    @Test func anIconInAFileNamedOutsideA2UIsSetIsStillSaid() throws {
        let lines = [
            Self.createSurface,
            Self.update(#"{"id":"root","component":"Column","children":["sf"]}"#),
            Self.update(#"{"id":"sf","component":"Icon","name":"chevron.right"}"#),
        ]
        let imported = A2UIImporter.importJSON(Data(lines.joined(separator: "\n").utf8))
        #expect(imported.diagnostics.contains { $0.reason == .invalidComponent && $0.componentID == "sf" }, "\(imported.diagnostics)")
    }

    /// A raw control character inside a string, such as a tab, isn't JSON; escaped, it is the same text. That is the
    /// only mend: the line is read with the tab in its text, and nothing is said.
    @Test func aRawControlCharacterInAStringIsReadAsWritten() throws {
        let lines = [
            Self.createSurface,
            Self.update("{\"id\":\"root\",\"component\":\"Column\",\"children\":[\"hours\"]}"),
            Self.update("{\"id\":\"hours\",\"component\":\"Text\",\"text\":\"Quiet hours\t22:00\u{1}\"}"),
        ]
        var stream = A2UIStream(tokens: .standard)
        let taken = stream.take(lines.joined(separator: "\n"), isComplete: true)
        let root = try #require(taken)
        #expect(leaves(root).map(\.content.text) == ["Quiet hours\t22:00\u{1}"])
        #expect(stream.diagnostics.isEmpty, "\(stream.diagnostics)")
    }

    /// A model writes a component a message, so one id given to two components, which in one message is a duplicate, is
    /// a component written again: what it wrote first isn't on the screen, so that is said. Written again the same, it
    /// changes nothing and nothing is said.
    @Test func aComponentWrittenAgainDifferentlyIsSaid() throws {
        let lines = [
            Self.createSurface,
            Self.update(#"{"id":"root","component":"Column","children":["row","go"]}"#),
            Self.update(#"{"id":"row","component":"Row","children":["label"]}"#),
            Self.update(#"{"id":"label","component":"Text","text":"Don't have an account?"}"#),
            Self.update(#"{"id":"go","component":"Button","child":"label","variant":"primary","action":{"event":{"name":"signUp"}}}"#),
            Self.update(#"{"id":"label","component":"Text","text":"Create account"}"#),
            Self.update(#"{"id":"row","component":"Row","children":["label"]}"#),
        ]
        var stream = A2UIStream(tokens: .standard)
        let taken = stream.take(lines.joined(separator: "\n"), isComplete: true)
        #expect(taken != nil)
        let again = stream.diagnostics.filter { $0.reason == .duplicateID }
        #expect(again.map(\.componentID) == ["label"])
        #expect(again.map(\.path) == ["line 6"])
    }

    /// Any other slip in a line's JSON is never guessed at: a missing comma or colon, or a bracket too many, and the
    /// line is skipped and said once, as before.
    @Test(arguments: [
        #"{"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"t","component":"Text""text":"Hi"}]}}"#,
        #"{"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"t","component":"Text","text" "Hi"}]}}"#,
        #"{"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"t","component":"Text","text":"Hi"}]}]}}"#,
        "{\"version\":\"1.0\",\"updateComponents\":{\"surfaceId\":\"screen\",\"components\":[{\"id\":\"t\",\"component\":\"Text\",\u{1}\"text\":\"Hi\"}]}}",
        // A backslash straight before a raw control character is a broken escape, not a raw character in a string:
        // escaping the tab would make it a backslash and a "t", which changes the text.
        "{\"version\":\"1.0\",\"updateComponents\":{\"surfaceId\":\"screen\",\"components\":[{\"id\":\"t\",\"component\":\"Text\",\"text\":\"Hi\\\t\"}]}}",
    ])
    func anyOtherSlipInALineIsSkippedAndSaidOnce(_ broken: String) throws {
        let lines = [Self.createSurface, Self.update(###"{"id":"root","component":"Column","children":["title","t"]},{"id":"title","component":"Text","text":"## Hi"}"###), broken]
        var stream = A2UIStream(tokens: .standard)
        let taken = stream.take(lines.joined(separator: "\n"), isComplete: true)
        let root = try #require(taken)
        #expect(leaves(root).map(\.kind) == [.title])
        #expect(stream.diagnostics.filter { $0.reason == .parseFailed }.map(\.path) == ["line 3"])
    }

    // MARK: - Which format, and what the model is told

    @Test func hostedModelsAndTheDeviceWriteTheOutline() {
        #expect(ScreenGenerator.hostedFormat == .outline)
        #expect(ScreenGenerator.format(for: .appleIntelligence) == .outline)
        let hosted = ModelChoice.hosted(.openAI, model: "m")
        #expect(ScreenGenerator.format(for: hosted) == .outline)
        // Each is told its own prompt.
        #expect(ScreenGenerator.instructions(for: "a profile", using: .appleIntelligence) == ScreenPrompt.instructions(.compact, for: "a profile"))
        #expect(ScreenGenerator.instructions(for: "a profile", using: hosted)
            == ScreenPrompt.instructions(HostedLanguageModel.isSupported ? .full : .compact, for: "a profile"))
    }

    @Test func everyA2UIExampleImportsCleanlyAndMatchesItsOutline() throws {
        #expect(A2UIPrompt.library.map(\.name) == ScreenPrompt.library.map(\.name))
        for example in A2UIPrompt.library {
            let imported = A2UIImporter.importJSON(Data(example.lines.utf8), tokens: .standard, trustsLayerLook: false)
            #expect(imported.screens.count == 1, "\(example.name)")
            #expect(imported.diagnostics.allSatisfy { $0.reason == .actionNotRun }, "\(example.name): \(imported.diagnostics)")
            let root = try #require(imported.screens.first?.root, "\(example.name)")
            #expect(Outline.withOnePrimaryAction(root) == root, "\(example.name) should already have one primary action")

            let outline = try #require(ScreenPrompt.library.first { $0.name == example.name })
            let expected = leaves(Outline.parse(outline.lines, isComplete: true)).map { Self.read($0.kind) }
            #expect(leaves(root).map { Self.read($0.kind) } == expected, "\(example.name)")
            // Every line is a message of its own, so it streams.
            #expect(example.lines.split(separator: "\n").allSatisfy { $0.hasPrefix(#"{"version":"1.0","#) }, "\(example.name)")
        }
    }

    @Test func theA2UIPromptNamesLayersCatalogue() {
        let prompt = A2UIPrompt.instructions(for: "a profile")
        for needed in ["urn:layer:a2ui:catalog:1", #""version":"1.0""#, "createSurface", "updateComponents", "LayerGrid", "LayerToggle",
                       #""surfaceId":"\#(A2UIPrompt.surfaceID)""#] {
            #expect(prompt.contains(needed), "\(needed)")
        }
        // LayerGrid's columns is required (F10); Layer's tokens set every spacing (F9).
        #expect(prompt.split(separator: "\n").contains { $0.contains("LayerGrid") && $0.contains("columns") && $0.contains("required") })
        #expect(!prompt.contains("columnSpacing"))
        #expect(!prompt.contains("rowSpacing"))
        // Two examples, chosen for the description as the outline's are.
        let chosen = ScreenPrompt.examples(for: "a profile", count: 2).map(\.name)
        #expect(chosen.contains("profile"))
        for example in A2UIPrompt.library {
            #expect(prompt.contains(example.lines) == chosen.contains(example.name), "\(example.name)")
        }
    }

    /// A line holding several components broke far more often than one holding one (2026-11-26,
    /// docs/benchmarks/screen-prompt.md), so the model is asked for one component a message, and every example shows it.
    @Test func theA2UIPromptAsksForOneComponentAMessage() throws {
        let prompt = A2UIPrompt.instructions(for: "a profile")
        #expect(prompt.contains("an updateComponents message holding one component"))
        #expect(prompt.contains(#"{"version":"1.0","updateComponents":{"surfaceId":"screen","components":[{"id":"…","component":"…",…}]}}"#))
        for example in A2UIPrompt.library {
            for line in example.lines.split(separator: "\n").dropFirst() {
                let message = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], "\(example.name)")
                let components = (message["updateComponents"] as? [String: Any])?["components"] as? [Any]
                #expect(components?.count == 1, "\(example.name): \(line)")
            }
        }
    }

    /// A model wrote SF Symbol names in A2UI's `Icon` (plan 6 and 2026-11-26), so the prompt offers one way to write an
    /// icon, Layer's own symbol by its SF Symbol name.
    @Test func theA2UIPromptOffersOneWayToWriteAnIcon() {
        let prompt = A2UIPrompt.instructions(for: "a profile")
        #expect(!prompt.contains("- Icon:"))
        #expect(!prompt.contains("A2UI's icon names"))
        #expect(prompt.contains("- LayerSymbol: name, an SF Symbol name, such as bell, gearshape or chevron.right. Every icon is one."))
        #expect(A2UIPrompt.library.allSatisfy { !$0.lines.contains(#""component":"Icon""#) })
    }

    /// A model gave two components one id (`label` for three labels) and broke the line of a component it named `s3`
    /// three times out of three, its `"s` taken for `"surfaceId` (2026-11-26). So an id says what its component is, in
    /// words, and is its own; every example's ids are.
    @Test func theA2UIPromptAsksForIdsInWordsThatAreEachComponentsOwn() throws {
        let prompt = A2UIPrompt.instructions(for: "a profile")
        #expect(prompt.contains("An id says what its component is, in words joined by underscores, such as total_label or pace_value, and no two components share one."))
        for example in A2UIPrompt.library {
            var ids: [String] = []
            for line in example.lines.split(separator: "\n").dropFirst() {
                let message = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                let components = (message["updateComponents"] as? [String: Any])?["components"] as? [[String: Any]] ?? []
                ids += components.compactMap { $0["id"] as? String }
            }
            #expect(Set(ids).count == ids.count, "\(example.name): \(ids)")
            #expect(ids.allSatisfy { $0.wholeMatch(of: /[a-z]+(_[a-z]+)*/) != nil }, "\(example.name): \(ids)")
        }
    }

    /// A model asked for "5 to 14 components that show something" spent its thinking counting its Columns and Rows too,
    /// and thought a third longer before A2UI than before the outline (2026-11-26). The containers don't count.
    @Test func theA2UIPromptCountsOnlyWhatShows() {
        let prompt = A2UIPrompt.instructions(for: "a profile")
        #expect(prompt.contains("- Show 5 to 14 things, such as Text, Image, Button and TextField; the Columns, Rows and Cards that hold them don't count. Fewer, better things beat a crowded screen."))
        #expect(!prompt.contains("Use 5 to 14 components"))
    }

    /// Every A2UI failure in the third fixed run was the line of the last thing a Column or Row holds, closed with `]}`
    /// too many, as if it closed that Column or Row too (2026-11-26). The prompt says a line doesn't.
    @Test func theA2UIPromptSaysALineClosesOnlyItsOwnComponent() {
        let prompt = A2UIPrompt.instructions(for: "a profile")
        #expect(prompt.contains("A line closes its own component and the message, nothing more: it never adds ]} to close the Column or Row it is in, even for the last thing that Column or Row holds."))
    }

    /// A model left a LayerToggle's label out beside a Text saying the same (2026-11-26), and a label is required.
    @Test func theA2UIPromptSaysAControlAlwaysHasItsLabel() {
        let prompt = A2UIPrompt.instructions(for: "a profile")
        #expect(prompt.contains("- CheckBox, LayerToggle and LayerRadio: label, always, even beside a Text that says the same, and value true or false."))
    }

    // MARK: - What a generation says it left out

    @Test @MainActor func aGenerationSaysWhatItLeftOut() async throws {
        let app = AppModel(document: LayerDocument())
        let (stream, feed) = AsyncThrowingStream<ScreenGenerator.Update, any Error>.makeStream()
        app.screenStream = { _ in stream }
        app.generateScreen(from: "a sign-in screen")
        feed.yield(.screen(Outline.parse("title: Sign in\nbutton: Go\n", isComplete: true)))
        feed.yield(.leftOut([A2UIDiagnostic(reason: .functionNotRun, path: "callRendererFunction", message: "Layer never runs functions.")]))
        feed.finish()
        await app.waitForGeneration()
        #expect(app.generation?.phase == .finished)
        #expect(app.generation?.elementCount == 2)
        #expect(app.generation?.leftOut == 1)
        let generation = try #require(app.generation)
        #expect(GenerationStatus.finishedText(generation) == "Finished. 1 part couldn't be brought in.")
        var two = generation
        two.leftOut = 2
        #expect(GenerationStatus.finishedText(two) == "Finished. 2 parts couldn't be brought in.")
        two.leftOut = 0
        #expect(GenerationStatus.finishedText(two) == "Wrote 2 elements")
    }

    // MARK: - Helpers

    /// A2UI has only Text, which the importer reads as body when it runs past one line: so body and text are one.
    private static func read(_ kind: ElementKind) -> ElementKind {
        kind == .body ? .text : kind
    }
}

/// The leaves under `node`, in reading order.
private func leaves(_ node: LayerNode) -> [LayerNode] {
    node.children.flatMap { $0.isContainer ? leaves($0) : [$0] }
}

/// The stream as a hosted model writes it, through Foundation Models and the stubbed provider. In
/// `HostedModelTests`, which runs one test at a time: the stub's answers and the Keychain's keys are one place
/// for the whole process, and that suite puts its own there as each of its tests starts.
extension HostedModelTests {
    @Test(.enabled(if: HostedLanguageModel.isSupported, "Foundation Models runs models of the app's own from iPadOS 27.2"))
    func aHostedModelCanStillWriteTheOutline() async throws {
        StubProvider.answer(with: .init(body: SSE.openAI(text: ["title: Hi\n", "button: Go\n"])))
        let request = ScreenGenerator.Request(description: "a tiny screen", choice: .hosted(.openAI, model: "m"))
        var counts: [Int] = []
        for try await update in ScreenGenerator.stream(request, format: .outline) {
            if case .screen(let root) = update { counts.append(root.leafCount) }
        }
        #expect(counts.last == 2)
        // It was told the outline, with all a hosted model has room for.
        let system = (StubProvider.lastBody["messages"] as? [[String: Any]])?.first?["content"] as? String
        #expect(system == ScreenPrompt.instructions(.full, for: "a tiny screen"))
    }

    /// A screen in A2UI is asked for at `A2UIPrompt.temperature`, so a slip in a line's JSON is less likely; the outline
    /// is asked for at the model's own (2026-11-26).
    @Test(.enabled(if: HostedLanguageModel.isSupported, "Foundation Models runs models of the app's own from iPadOS 27.2"))
    func anA2UIScreenIsAskedForAtItsOwnTemperature() async throws {
        let choice = ModelChoice.hosted(.lmStudio, model: "m")
        StubProvider.answer(with: .init(body: SSE.openAI(text: A2UIGenerationTests.signIn.map { $0 + "\n" })))
        for try await _ in ScreenGenerator.stream(ScreenGenerator.Request(description: "a sign-in screen", choice: choice), format: .a2ui) {}
        #expect(StubProvider.lastBody["temperature"] as? Double == A2UIPrompt.temperature)

        StubProvider.answer(with: .init(body: SSE.openAI(text: ["title: Hi\n", "button: Go\n"])))
        for try await _ in ScreenGenerator.stream(ScreenGenerator.Request(description: "a tiny screen", choice: choice), format: .outline) {}
        #expect(StubProvider.lastBody["temperature"] == nil)
    }

    @Test(.enabled(if: HostedLanguageModel.isSupported, "Foundation Models runs models of the app's own from iPadOS 27.2"))
    func whatAHostedScreenLeftOutIsSaidOnceAfterItsLastScreen() async throws {
        let call = #"{"version":"1.0","callRendererFunction":{"functionCallId":"call_1","surfaceId":"screen","# +
            #""callFunction":{"@call":"openUrl","args":{"url":"https://example.com"},"catalogId":"urn:layer:a2ui:catalog:1"}}}"#
        StubProvider.answer(with: .init(body: SSE.openAI(text: (A2UIGenerationTests.signIn + [call]).map { $0 + "\n" })))
        var updates: [ScreenGenerator.Update] = []
        for try await update in ScreenGenerator.stream(ScreenGenerator.Request(description: "a sign-in screen", choice: .hosted(.openAI, model: "m")), format: .a2ui) {
            updates.append(update)
        }
        let leftOut = updates.compactMap { if case .leftOut(let diagnostics) = $0 { diagnostics } else { nil } }
        // The function call, said once; the button's action, never run, isn't something left out.
        #expect(leftOut.count == 1)
        #expect(leftOut.first?.map(\.reason) == [.functionNotRun])
        if case .leftOut = updates.last {} else { Issue.record("what was left out comes after the last screen: \(updates)") }
        let counts = updates.compactMap { if case .screen(let root) = $0 { root.leafCount } else { nil } }
        #expect(counts.last == 3)

        // A screen whose only diagnostics are its buttons' actions left nothing out, so says nothing.
        StubProvider.answer(with: .init(body: SSE.openAI(text: A2UIGenerationTests.signIn.map { $0 + "\n" })))
        var whole: [ScreenGenerator.Update] = []
        for try await update in ScreenGenerator.stream(ScreenGenerator.Request(description: "a sign-in screen", choice: .hosted(.openAI, model: "m")), format: .a2ui) {
            whole.append(update)
        }
        #expect(!whole.contains { if case .leftOut = $0 { true } else { false } }, "\(whole)")
        #expect(whole.compactMap { if case .screen(let root) = $0 { root.leafCount } else { nil } }.last == 3)
    }
}
