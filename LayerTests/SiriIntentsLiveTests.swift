import Foundation
import Testing
@testable import Layer

/// Runs the actions themselves inside the running app, as Siri and Shortcuts would: they
/// make a real design through the document browser, open it, and change it.
/// Skipped under the CI test plan (it sets LAYER_CI): driving the document browser fails
/// intermittently on fresh simulators, and a flaky test shouldn't block a TestFlight build.
@Suite(
    "Siri actions in the running app", .serialized,
    .disabled(if: ProcessInfo.processInfo.environment["LAYER_CI"] != nil, "Flaky on CI simulators")
)
@MainActor
struct SiriIntentsLiveTests {
    @Test func makesBuildsStylesAndDescribesADesign() async throws {
        let name = "Siri Test \(UUID().uuidString.prefix(6))"

        let create = CreateDesignIntent()
        create.name = name
        _ = try await create.perform()
        let model = try #require(OpenDesigns.shared.current)
        let designID = try #require(model.designID)
        #expect(model.store.title == name)
        defer {
            if let url = DesignLibrary.url(for: designID) { try? FileManager.default.removeItem(at: url) }
        }

        let addScreen = AddScreenIntent()
        addScreen.device = .iPad
        addScreen.name = "Settings"
        _ = try await addScreen.perform()
        #expect(model.store.tree.screens.map(\.name) == ["Settings"])
        #expect(model.store.tree.screens.first?.deviceID == "ipad")

        let build = BuildScreenIntent()
        build.layout = "title: Welcome back\ntext field: Email\nbutton: Sign in [blue]"
        build.name = "Login"
        build.device = .iPhone
        _ = try await build.perform()
        let login = try #require(model.store.tree.screens.first { $0.name == "Login" })
        #expect(model.store.screenLeaves(login.id).map(\.kind) == [.title, .textField, .button])
        // A built screen is shown and selected, so “this screen” means it.
        #expect(model.selection == .screen(login.id))

        // “Make this button bold with rounded corners”: the element comes from the query
        // Siri would use, by its words.
        let button = try #require(try await ElementQuery().entities(matching: "sign in").first)
        let style = StyleElementIntent()
        style.element = button
        style.weight = .bold
        style.cornerRadius = 20
        _ = try await style.perform()
        let styled = try #require(model.store.screenLeaves(login.id).first { $0.kind == .button })
        #expect(styled.style.fontWeight == .bold)
        #expect(styled.style.cornerRadius == 20)

        let describe = DescribeDesignIntent()
        _ = try await describe.perform()
        let snapshot = try #require(DesignActions.snapshot(of: model))
        let words = DesignDescriber.describe(snapshot)
        #expect(words.contains("Login (iPhone): title “Welcome back”, text field “Email”, button “Sign in”"))

        // Undo in Layer takes back the last change, the styling.
        _ = try await UndoIntent().perform()
        let unstyled = model.store.screenLeaves(login.id).first { $0.kind == .button }
        #expect(unstyled?.style.fontWeight == nil)

        // The design is found again by name, as Siri would find it.
        let found = try await DesignQuery().entities(matching: String(name.suffix(6)))
        #expect(found.contains { $0.id == designID })

        // With another design open, opening this one by name puts the other away first.
        let other = CreateDesignIntent()
        other.name = "\(name) Other"
        _ = try await other.perform()
        let otherID = try #require(OpenDesigns.shared.current?.designID)
        defer {
            if let url = DesignLibrary.url(for: otherID) { try? FileManager.default.removeItem(at: url) }
        }
        #expect(otherID != designID)
        let open = OpenDesignIntent()
        open.target = try #require(found.first { $0.id == designID })
        _ = try await open.perform()
        #expect(OpenDesigns.shared.current?.designID == designID)
        #expect(OpenDesigns.shared.current?.store.tree.screens.map(\.name).contains("Login") == true)
    }
}
