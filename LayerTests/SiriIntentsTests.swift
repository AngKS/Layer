import CoreGraphics
import Foundation
import os
import Testing
import UIKit
@testable import Layer

// What Siri and Shortcuts rely on: reading a written screen, laying it out, finding
// designs and elements again by identifier, and undoing what an action changed.

@Suite("Written screens")
struct WrittenScreenTests {
    private func all(_ node: LayerNode) -> [LayerNode] { [node] + node.children.flatMap(all) }
    private func leaves(_ node: LayerNode) -> [LayerNode] { all(node).filter { !$0.isContainer } }

    /// A written screen's leaves where the rules lay it out on the iPhone, each frame in the screen's points.
    private func laidOut(_ written: String) -> [(node: LayerNode, frame: CGRect)] {
        placedLeaves(of: TreeRules.laidOut(Outline.parse(written, isComplete: true), deviceID: DeviceFrame.iPhone.id,
                                           settings: CanvasSettings(), previous: nil))
    }

    @Test func readsOneElementPerLine() {
        let screen = Outline.parse("""
        title: Welcome back
        text field: Email
        text field: Password
        button: Sign in
        """, isComplete: true)
        #expect(leaves(screen).map(\.kind) == [.title, .textField, .textField, .button])
        #expect(leaves(screen).map(\.content.text) == ["Welcome back", "Email", "Password", "Sign in"])
    }

    /// Read as a hand-written outline is read, every look number and all. Build Screen reads the same lines as a
    /// model's outline, and passes the numbers over.
    @Test func aHandWrittenOutlineReadsRowsSectionsAndLooks() throws {
        let written = """
        heading: Settings

        row: button: Cancel | button: Done [blue, bold, radius 12]
        ---
        body: Tap a row to change it [text #333333, 15pt]
        """
        let screen = Outline.parse(written, isComplete: true)
        #expect(screen.children.count == 3)
        let second = screen.children[1]
        #expect(second.children.count == 1)
        guard case .stack(let row)? = second.children.first?.resolvedLayout else {
            Issue.record("the second section holds a row")
            return
        }
        #expect(row.axis == .horizontal)
        let done = try #require(all(second).first { $0.content.text == "Done" })
        #expect(done.style.tint == ColourWords.named["blue"])
        #expect(done.style.fontWeight == .bold)
        #expect(done.style.cornerRadius == 12)
        let body = try #require(all(screen).first { $0.kind == .body })
        #expect(body.style.textColor == RGBColor(hex: 0x333333))
        #expect(body.style.fontSize == 15)
        let built = Outline.parse(written, isComplete: true, tokens: .standard, readsLookNumbers: false)
        #expect(all(built).first { $0.content.text == "Done" }?.style.cornerRadius == nil)
        #expect(all(built).first { $0.kind == .body }?.style.fontSize == nil)
    }

    @Test func understandsSynonymsSymbolsAndBareKinds() {
        let screen = Outline.parse("icon: heart.fill; switch; separator; Just some words", isComplete: true)
        #expect(leaves(screen).map(\.kind) == [.symbol, .toggle, .divider, .text])
        #expect(leaves(screen)[0].content.symbol == "heart.fill")
        #expect(leaves(screen)[3].content.text == "Just some words")
    }

    @Test func nothingToLayOutLeavesTheRootEmpty() {
        #expect(Outline.parse("   \n---\n", isComplete: true).children.isEmpty)
    }

    @Test func laysOutTopToBottomInsideTheSafeArea() {
        let device = DeviceFrame.iPhone
        let placed = laidOut("title: Hi\ntext field: Email\nbutton: Go")
        #expect(placed.count == 3)
        #expect((placed.first?.frame.minY ?? 0) >= device.safeTop)
        for (upper, lower) in zip(placed, placed.dropFirst()) {
            #expect(lower.frame.minY >= upper.frame.maxY, "\(lower.node.kind) overlaps \(upper.node.kind)")
        }
        // Fields and buttons run between the 20-point margins.
        #expect(placed.last?.frame.minX == 20)
        #expect(placed.last?.frame.width == device.size.width - 40)
    }

    @Test func aRowSharesItsWidth() {
        let device = DeviceFrame.iPhone
        let placed = laidOut("row: button: A | button: B")
        #expect(placed.count == 2)
        guard placed.count == 2 else { return }
        #expect(placed[0].frame.minY == placed[1].frame.minY)
        #expect(placed[0].frame.maxX < placed[1].frame.minX)
        #expect(placed[1].frame.maxX <= device.size.width - 20)
    }
}

@Suite("Entity identifiers")
struct EntityKeyTests {
    @Test func screensRoundTrip() throws {
        let screen = UUID()
        let id = EntityKey.screen(design: "icloud:Folder/Travel.layer", screen: screen)
        let parsed = try #require(EntityKey.parseScreen(id))
        #expect(parsed.design == "icloud:Folder/Travel.layer")
        #expect(parsed.screen == screen)
    }

    @Test func elementsRoundTripOnScreensAndTheCanvas() throws {
        let screen = UUID(), element = UUID()
        let onScreen = try #require(EntityKey.parseElement(EntityKey.element(design: "local:A.layer", host: .screen(screen), element: element)))
        #expect(onScreen.design == "local:A.layer")
        #expect(onScreen.ref == NodeRef(host: .screen(screen), node: element))

        let loose = try #require(EntityKey.parseElement(EntityKey.element(design: "local:A.layer", host: .canvas, element: element)))
        #expect(loose.ref.host == .canvas)
    }

    @Test func designPathsInsideTheLibraryAreRelative() throws {
        let local = DesignLibrary.roots.local
        let url = local.appendingPathComponent("Sub/My Design.layer")
        let id = DesignLibrary.id(for: url)
        #expect(id == "local:Sub/My Design.layer")
        #expect(DesignLibrary.url(for: id)?.standardizedFileURL.path == url.standardizedFileURL.path)
    }

    /// The board of `GroupModelTests.groupItemsAreLeftOutOfWhatIsDrawnExportedAndDescribed`, which this part of it
    /// came from (plan 6, Task 1, F11): B and D grouped on the screen, and the two notes on the canvas.
    @MainActor @Test func aGroupsMembersAreSirisElements() {
        let board = OrderBoard()
        let g = board.group(board.b, board.d)
        let notes = board.group(board.note1, board.note2, named: "N")
        let content = board.store.tree

        // Siri's elements are the members too.
        let entities = DesignSnapshot(id: "design", name: "Design", content: content, modified: nil).elements
        #expect(entities.count == 8)
        #expect(!entities.contains { $0.ref?.node == g.node || $0.ref?.node == notes.node })
    }
}

@Suite("Colours")
struct ColourTests {
    @Test func namesAndHexCodes() throws {
        #expect(ColourWords.parse("Blue") == ColourWords.named["blue"])
        #expect(ColourWords.parse("#0A84FF") == RGBColor(hex: 0x0A84FF))
        #expect(ColourWords.parse("0a84ff") == RGBColor(hex: 0x0A84FF))
        #expect(ColourWords.parse("not a colour") == nil)
        #expect(try ColourOption.resolve(nil, hex: "#FFFFFF") == RGBColor(hex: 0xFFFFFF))
        #expect(throws: LayerIntentError.self) { try ColourOption.resolve(nil, hex: "#12") }
    }
}

@Suite("Designs on disk")
struct DesignLibraryTests {
    @Test func readsAPackageWithoutItsInk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var file = DesignFile()
        file.content.title = "Travel"
        file.content.screens = [TreeScreen(name: "Login", origin: .zero, scale: 1, deviceID: nil,
                                                root: .container(children: [.standard(.title)]))]
        let url = folder.appendingPathComponent("Travel.layer")
        try file.wrapper().write(to: url, options: .atomic, originalContentsURL: nil)

        let summary = try #require(DesignLibrary.read(url))
        #expect(summary.title == "Travel")
        #expect(summary.content.screens.map(\.name) == ["Login"])
        #expect(summary.content.leaves(on: summary.content.screens[0].id).count == 1)
    }

    /// A folder with one design in it, named "Trip" on disk and "Travel" inside.
    private func savedDesign() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var file = DesignFile()
        file.content.title = "Travel"
        file.content.screens = [TreeScreen(name: "Login", origin: .zero, scale: 1, deviceID: nil)]
        let url = folder.appendingPathComponent("Trip.layer")
        try file.wrapper().write(to: url, options: .atomic, originalContentsURL: nil)
        return url
    }

    @Test func aDesignICloudHasNotDownloadedIsListedByItsNameWithoutBeingRead() throws {
        let url = try savedDesign()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Reading it would download it, and wait for that.
        let listed = try #require(DesignLibrary.listed(url, isDownloaded: { _ in false }))
        #expect(listed.title == "Trip")
        #expect(listed.content.screens.isEmpty)
        #expect(listed.id == DesignLibrary.id(for: url))

        let downloaded = try #require(DesignLibrary.listed(url, isDownloaded: { _ in true }))
        #expect(downloaded.title == "Travel")
        #expect(downloaded.content.screens.map(\.name) == ["Login"])
        // A design asked for by name is read whatever it takes.
        #expect(try #require(DesignLibrary.read(url)).title == "Travel")
    }

    @Test func everyDesignIsListedWithThoseICloudHasNotDownloadedByTheirNamesAlone() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".Trash"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A design, one iCloud keeps here only as its placeholder, one in a hidden folder,
        // and something that isn't a design.
        var file = DesignFile()
        file.content.title = "Travel"
        try file.wrapper().write(to: folder.appendingPathComponent("Real.layer"), options: .atomic, originalContentsURL: nil)
        try Data().write(to: folder.appendingPathComponent(".Away.layer.icloud"))
        try file.wrapper().write(to: folder.appendingPathComponent(".Trash/Old.layer"), options: .atomic, originalContentsURL: nil)
        try Data("notes".utf8).write(to: folder.appendingPathComponent("notes.txt"))

        let listing = DesignLibrary.list(in: [folder], isDownloaded: { _ in true })
        #expect(Set(listing.designs.map(\.url.lastPathComponent)) == ["Real.layer", "Away.layer"])
        #expect(listing.folders == [folder])
        let away = try #require(listing.designs.first { $0.url.lastPathComponent == "Away.layer" })
        #expect(!away.isRead)
        #expect(away.title == "Away")
        #expect(away.id == DesignLibrary.id(for: folder.appendingPathComponent("Away.layer")))
        #expect(listing.designs.first { $0.url.lastPathComponent == "Real.layer" }?.title == "Travel")

        // The list goes by what iCloud has downloaded, and reads nothing that it hasn't.
        let undownloaded = DesignLibrary.list(in: [folder], isDownloaded: { _ in false })
        #expect(undownloaded.designs.allSatisfy { !$0.isRead && $0.content.screens.isEmpty })
        #expect(undownloaded.designs.contains { $0.title == "Real" })
    }

    @Test func aDesignMissingFromTheListHasGoneOnlyIfItsFolderWasLookedThrough() {
        let listing = DesignLibrary.Listing(designs: [], folders: [DesignLibrary.roots.local])
        #expect(listing.hasGone("local:Gone.layer"))
        #expect(!listing.hasGone("icloud:There.layer"), "iCloud's folder wasn't looked through")
        #expect(listing.hasGone("file:/elsewhere/Opened.layer"), "a design opened from outside Layer's folders")
        #expect(!DesignLibrary.Listing(designs: [], folders: []).hasGone("local:Gone.layer"))
    }

    @Test func aDesignUnchangedSinceItWasListedIsNotReadAgain() throws {
        let url = try savedDesign()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try #require(DesignLibrary.listed(url, isDownloaded: { _ in true })).title == "Travel")

        // The design inside changes, but its dates are put back as they were.
        let design = url.appendingPathComponent(DesignPackage.design)
        let dates = try [url, design].map { try #require(try FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date) }
        var renamed = try DesignFile(wrapper: FileWrapper(url: url))
        renamed.content.title = "Holiday"
        try renamed.wrapper().fileWrappers?[DesignPackage.design]?.regularFileContents?.write(to: design)
        for (item, date) in zip([url, design], dates) {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: item.path)
        }
        #expect(try #require(DesignLibrary.listed(url, isDownloaded: { _ in true })).title == "Travel")

        // Changed in the usual way, it is read again.
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(5)], ofItemAtPath: design.path)
        #expect(try #require(DesignLibrary.listed(url, isDownloaded: { _ in true })).title == "Holiday")
    }
}

/// A Spotlight index kept in memory, to see what the indexer leaves in it.
private actor FakeSpotlight: SpotlightIndex {
    private(set) var designs: Set<String> = []
    private(set) var screens: Set<String> = []

    func index(designs entities: [DesignEntity]) { designs.formUnion(entities.map(\.id)) }
    func index(screens entities: [ScreenEntity]) { screens.formUnion(entities.map(\.id)) }
    func delete(designs ids: [String]) { designs.subtract(ids) }
    func delete(screens ids: [String]) { screens.subtract(ids) }
    func deleteAll() {
        designs = []
        screens = []
    }
}

/// Defaults that count how often the indexer's record of what is in the index is read and written.
private final class CountingDefaults: UserDefaults {
    let counts = OSAllocatedUnfairLock(initialState: (reads: 0, writes: 0))

    override func object(forKey defaultName: String) -> Any? {
        if defaultName == "spotlightIndexedScreens" { counts.withLock { $0.reads += 1 } }
        return super.object(forKey: defaultName)
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        if defaultName == "spotlightIndexedScreens" { counts.withLock { $0.writes += 1 } }
        super.set(value, forKey: defaultName)
    }
}

/// One test at a time: each swaps the indexer's index and record for its own.
@Suite("Spotlight's index of designs", .serialized)
@MainActor
struct DesignIndexTests {
    /// Runs `body` with the indexer writing to `index` and keeping its record in `record`.
    /// `suite` is named after the test, so each test has one set of defaults, emptied as it
    /// starts and when it is done: one named afresh each time left a file behind every run.
    private func using(_ index: FakeSpotlight, record: UserDefaults, suite: String, _ body: () async throws -> Void) async rethrows {
        record.removePersistentDomain(forName: suite)
        let (systemIndex, systemRecord) = (DesignIndexer.spotlight, DesignIndexer.recordDefaults)
        DesignIndexer.spotlight = index
        DesignIndexer.recordDefaults = record
        defer {
            DesignIndexer.spotlight = systemIndex
            DesignIndexer.recordDefaults = systemRecord
            record.removePersistentDomain(forName: suite)
        }
        try await body()
    }

    @Test func aLaunchPassReadsAndWritesItsRecordOnce() async throws {
        let suite = "DesignIndexTests-\(#function)"
        let record = try #require(CountingDefaults(suiteName: suite))
        let index = FakeSpotlight()
        let tag = UUID().uuidString
        let designs = (0..<6).map { snapshot("local:Design \($0) \(tag).layer", screens: ["A", "B"]) }
        await using(index, record: record, suite: suite) {
            for _ in 0..<2 {
                record.counts.withLock { $0 = (0, 0) }
                await DesignIndexer.reindex(designs)
                let counts = record.counts.withLock { $0 }
                #expect(counts.reads <= 1, "read \(counts.reads) times")
                #expect(counts.writes == 1, "written \(counts.writes) times")
            }
        }
    }

    @Test func withoutARecordToReadTheIndexIsBuiltAgain() async throws {
        let suite = "DesignIndexTests-\(#function)"
        let record = try #require(UserDefaults(suiteName: suite))
        let index = FakeSpotlight()
        let tag = UUID().uuidString
        let kept = snapshot("local:Kept \(tag).layer", screens: ["Login"])
        let stale = snapshot("local:Stale \(tag).layer", screens: ["Old"])
        await using(index, record: record, suite: suite) {
            await DesignIndexer.reindex([kept, stale])
            // The record is lost, though a pass once completed: what is in the index isn't known.
            record.removeObject(forKey: "spotlightIndexedScreens")
            await DesignIndexer.reindex([kept])
            #expect(!(await index.designs.contains(stale.id)))
            #expect(!(await index.screens.contains(stale.screens[0].id)))
            #expect(await index.designs.contains(kept.id))
        }
    }

    @Test func aDesignRenamedAfterItClosedIsIndexedUnderItsNewIdentifier() async throws {
        let suite = "DesignIndexTests-\(#function)"
        let record = try #require(UserDefaults(suiteName: suite))
        let index = FakeSpotlight()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try await using(index, record: record, suite: suite) {
            let model = AppModel(document: LayerDocument(file: DesignFile()))
            model.fileURL = folder.appendingPathComponent("Untitled.layer")
            model.store.addScreen(.iPhone, at: Placement(origin: .zero, scale: 1))
            model.close()
            // The rename the board's name started finishes now.
            model.fileURL = folder.appendingPathComponent("Login.layer")
            let renamed = try #require(model.designID)
            for _ in 0..<40 where !(await index.designs.contains(renamed)) {
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(await index.designs.contains(renamed))
            #expect(await index.screens.count { $0.hasPrefix(renamed) } == 1)
        }
    }

    @Test func designsInAFolderThatCouldNotBeLookedThroughAreKept() async throws {
        let suite = "DesignIndexTests-\(#function)"
        let record = try #require(UserDefaults(suiteName: suite))
        let index = FakeSpotlight()
        let tag = UUID().uuidString
        let local = snapshot("local:Here \(tag).layer", screens: ["Login"])
        let cloud = snapshot("icloud:There \(tag).layer", screens: ["Map"])
        await using(index, record: record, suite: suite) {
            await DesignIndexer.reindex([local, cloud])
            // iCloud's folder can't be found this launch: its designs aren't listed, but
            // they haven't gone.
            await DesignIndexer.reindex([local]) { !$0.hasPrefix("icloud:") }
            #expect(await index.designs.contains(cloud.id))
            #expect(await index.screens.contains(cloud.screens[0].id))
        }
    }

    private func snapshot(_ id: String, screens names: [String]) -> DesignSnapshot {
        var content = TreeContent()
        for (index, name) in names.enumerated() {
            content.screens.append(TreeScreen(name: name, origin: CGPoint(x: CGFloat(index) * 500, y: 0), scale: 1, deviceID: nil))
        }
        return DesignSnapshot(id: id, name: name(of: id), content: content, modified: nil)
    }

    private func name(of id: String) -> String {
        String(id.split(separator: ":").last ?? "")
    }

    @Test func aLaunchPassKeepsWhatItCouldNotReadAndTakesOutWhatHasGone() async throws {
        let index = FakeSpotlight()
        let suite = "DesignIndexTests-\(#function)"
        let record = try #require(UserDefaults(suiteName: suite))
        record.removePersistentDomain(forName: suite)
        let (systemIndex, systemRecord) = (DesignIndexer.spotlight, DesignIndexer.recordDefaults)
        DesignIndexer.spotlight = index
        DesignIndexer.recordDefaults = record
        defer {
            DesignIndexer.spotlight = systemIndex
            DesignIndexer.recordDefaults = systemRecord
            record.removePersistentDomain(forName: suite)
        }

        let tag = UUID().uuidString
        let kept = snapshot("local:Kept \(tag).layer", screens: ["Login", "Home"])
        let away = snapshot("icloud:Away \(tag).layer", screens: ["Map", "Trips"])
        let gone = snapshot("local:Gone \(tag).layer", screens: ["Old"])
        // A launch that read all three.
        await DesignIndexer.reindex([kept, away, gone])
        #expect(await index.designs.isSuperset(of: [kept.id, away.id, gone.id]))

        // The next: Kept has lost a screen, Away is in iCloud and not on this iPad, and
        // Gone has been deleted.
        var fewer = kept.content
        fewer.screens.removeAll { $0.id == kept.content.screens[1].id }
        let keptNow = DesignSnapshot(id: kept.id, name: kept.name, content: fewer, modified: nil)
        let awayNow = DesignSnapshot(id: away.id, name: away.name, content: TreeContent(), modified: nil, isRead: false)
        await DesignIndexer.reindex([keptNow, awayNow])

        let designs = await index.designs, screens = await index.screens
        #expect(designs.contains(kept.id))
        #expect(designs.contains(away.id))
        #expect(Set(away.screens.map(\.id)).isSubset(of: screens), "what couldn't be read stays as it was indexed")
        #expect(screens.contains(keptNow.screens[0].id))
        #expect(!screens.contains(kept.screens[1].id), "a screen that has gone is taken out")
        #expect(!designs.contains(gone.id), "a design that has gone is taken out")
        #expect(!screens.contains(gone.screens[0].id))
    }
}

@Suite("Opening designs")
@MainActor
struct OpeningDesignTests {
    /// What happened, in order.
    private final class Steps {
        var all: [String] = []
    }

    @Test func oneOpeningWaitsForTheOneBefore() async {
        let turns = OneAtATime(limit: .seconds(2))
        let steps = Steps()
        let opens = ["A", "B"].map { name in
            Task {
                try await turns.run {
                    steps.all.append("start \(name)")
                    try? await Task.sleep(for: .milliseconds(50))
                    steps.all.append("end \(name)")
                }
            }
        }
        for open in opens { _ = try? await open.value }
        #expect(steps.all == ["start A", "end A", "start B", "end B"], "\(steps.all)")
    }

    /// A wait that may never end, let go when the test is done with it.
    private final class Held {
        var continuation: CheckedContinuation<Void, Never>?
        func letGo() {
            continuation?.resume()
            continuation = nil
        }
    }

    private func couldNotOpen(_ error: any Error) -> Bool {
        if case .couldNotOpen? = error as? LayerIntentError { true } else { false }
    }

    /// What `task` came to, if it finished within `limit`. Nil if it is still waiting. The
    /// limits the tests give are generous: with every suite running at once, the main
    /// thread can be busy for seconds; what they check would otherwise never finish.
    private final class Box<T> {
        var outcome: Result<T, any Error>?
    }

    private func outcome<T>(of task: Task<T, any Error>, within limit: Duration) async -> Result<T, any Error>? {
        let box = Box<T>()
        Task { box.outcome = await task.result }
        let deadline = ContinuousClock.now + limit
        while box.outcome == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return box.outcome
    }

    @Test func aTurnThatRunsOverGivesUpAndTheNextGoes() async throws {
        let turns = OneAtATime(limit: .milliseconds(300))
        let held = Held()
        defer { held.letGo() }
        let stuck = Task { try await turns.run { await withCheckedContinuation { held.continuation = $0 } } }
        let next = Task { try await turns.run { "next" } }

        guard case .failure(let error)? = await outcome(of: stuck, within: .seconds(10)) else {
            Issue.record("the stuck turn should have given up")
            return
        }
        #expect(couldNotOpen(error), "\(error)")
        guard case .success(let value)? = await outcome(of: next, within: .seconds(10)) else {
            Issue.record("the next turn should have gone")
            return
        }
        #expect(value == "next")
    }

    @Test func aWaiterThatIsCancelledLeavesTheQueue() async throws {
        let turns = OneAtATime(limit: .seconds(30))
        let held = Held()
        defer { held.letGo() }
        let stuck = Task { try await turns.run { await withCheckedContinuation { held.continuation = $0 } } }
        let waiter = Task { try await turns.run { "never" } }
        for _ in 0..<50 where turns.queued == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(turns.queued == 1)

        waiter.cancel()
        guard case .failure(let error)? = await outcome(of: waiter, within: .seconds(10)) else {
            Issue.record("a cancelled waiter should stop waiting")
            return
        }
        #expect(error is CancellationError)
        #expect(turns.queued == 0)
        _ = stuck
    }

    /// A window with a stand-in browser and a design presented over it.
    private func browserShowingADesign(animated: Bool) throws -> (window: UIWindow, browser: UIViewController, design: UIViewController) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let browser = UIViewController(), design = UIViewController()
        window.rootViewController = browser
        window.isHidden = false
        browser.present(design, animated: animated)
        return (window, browser, design)
    }

    @Test func aDesignOverTheBrowserIsReadiedThenPutAwayBeforeAnotherIsPicked() async throws {
        let (window, browser, design) = try browserShowingADesign(animated: false)
        defer { window.isHidden = true }
        #expect(browser.presentedViewController === design)

        var steps: [String] = []
        let url = URL(fileURLWithPath: "/designs/B.layer")
        // A real dismiss, on a main thread every suite running alongside shares: the app's
        // 2 s for it ran out now and then. The limit isn't what this test is about.
        try await DocumentBrowser.pick(url, in: browser, limit: .seconds(8)) { presented in
            steps.append(presented === design && browser.presentedViewController === design ? "readied while shown" : "readied too late")
        } picking: { picked in
            steps.append(browser.presentedViewController == nil ? "picked \(picked.lastPathComponent)" : "picked over the design")
        }
        #expect(steps == ["readied while shown", "picked B.layer"])
        #expect(browser.presentedViewController == nil)
    }

    @Test func aDismissThatNeverFinishesGivesUpAndTheNextOpenGoes() async throws {
        let (window, browser, _) = try browserShowingADesign(animated: false)
        defer { window.isHidden = true }
        let turns = OneAtATime(limit: .seconds(5))
        let url = URL(fileURLWithPath: "/designs/B.layer")
        let stuck = Task {
            try await turns.run {
                try await DocumentBrowser.pick(url, in: browser, limit: .milliseconds(300), dismissing: { _, _ in }) { _ in } picking: { _ in
                    Issue.record("picked over a design that wasn't put away")
                }
            }
        }
        let next = Task { try await turns.run { "next" } }
        guard case .failure(let error)? = await outcome(of: stuck, within: .seconds(10)) else {
            Issue.record("an open whose dismiss never finishes should give up")
            return
        }
        #expect(couldNotOpen(error), "\(error)")
        guard case .success? = await outcome(of: next, within: .seconds(10)) else {
            Issue.record("the next open should have gone")
            return
        }
    }

    @Test func anOpenThatTimedOutNeverPicksLate() async throws {
        let (window, browser, design) = try browserShowingADesign(animated: false)
        defer { window.isHidden = true }
        for _ in 0..<100 where design.isBeingPresented { try await Task.sleep(for: .milliseconds(10)) }
        // The turn runs out while the dismiss is still on its way; the dismiss then finishes.
        let turns = OneAtATime(limit: .milliseconds(100))
        let steps = Steps()
        let url = URL(fileURLWithPath: "/designs/B.layer")
        let open = Task {
            try await turns.run {
                try await DocumentBrowser.pick(url, in: browser, dismissing: { _, done in
                    steps.all.append("dismissing")
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        steps.all.append("dismissed")
                        done()
                    }
                }) { _ in steps.all.append("prepared") } picking: { _ in
                    steps.all.append("picked")
                }
            }
        }
        guard case .failure? = await outcome(of: open, within: .seconds(10)) else {
            Issue.record("the open should have run out of time")
            return
        }
        try await Task.sleep(for: .milliseconds(600))
        #expect(steps.all == ["prepared", "dismissing", "dismissed"], "a design was picked after the open gave up: \(steps.all)")
    }

    @Test func aDesignStillComingUpIsPutAwayOnceItIsUp() async throws {
        let (window, browser, design) = try browserShowingADesign(animated: true)
        defer { window.isHidden = true }
        #expect(design.isBeingPresented)
        let url = URL(fileURLWithPath: "/designs/B.layer")
        let picking = Task {
            // Within the ten seconds waited for below: the app's 2 s for a real
            // presentation and dismiss, on a shared main thread, isn't what this is about.
            try await DocumentBrowser.pick(url, in: browser, limit: .seconds(4)) { _ in } picking: { _ in }
        }
        guard case .success? = await outcome(of: picking, within: .seconds(10)) else {
            Issue.record("a dismiss tried while the design was still coming up was never finished")
            return
        }
        #expect(browser.presentedViewController == nil)
    }
}

@Suite("Actions on an open design")
@MainActor
struct DesignActionTests {
    private func model() -> AppModel {
        let model = AppModel(document: LayerDocument())
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.store.undoManager = undo
        return model
    }

    @Test func anEditIsOneUndoStep() throws {
        let model = model()
        let screen = model.store.addFreeScreen([])
        let written = Outline.parse("title: A\nbody: B\nbutton: C", isComplete: true)
        DesignActions.edit(model, undoManager: nil, actionName: "Build Screen") {
            model.store.replaceChildren(of: .screen(screen), with: written.children)
            model.store.updateTreeScreen(screen) { $0.name = "Login" }
        }
        #expect(model.store.screenLeaves(screen).count == 3)
        #expect(model.store.treeScreen(screen)?.name == "Login")
        model.store.undoManager?.undo()
        #expect(model.store.screenLeaves(screen).isEmpty)
        #expect(model.store.treeScreen(screen)?.name == "Screen 1")
    }

    @Test func theActionsOwnUndoPutsTheDesignBack() throws {
        let model = model()
        let screen = model.store.addFreeScreen([])
        let before = model.store.tree
        let siriUndo = UndoManager()
        siriUndo.groupsByEvent = false
        DesignActions.edit(model, undoManager: siriUndo, actionName: "Add Title") {
            var title = LayerNode.standard(.title)
            title.frame = model.store.newElementFrame(.title, on: screen) ?? title.frame
            model.store.add(title, to: .screen(screen))
        }
        #expect(model.store.tree != before)
        #expect(siriUndo.canUndo)
        siriUndo.undo()
        #expect(model.store.tree == before)
    }

    @Test func siriUndoTakesBackOnlyItsOwnAction() {
        let model = model()
        let siri = UndoManager()
        siri.groupsByEvent = false
        DesignActions.edit(model, undoManager: siri, actionName: "Rename Design") { model.store.setTitle("A") }
        // Then a screen is added by hand.
        model.store.addFreeScreen([])
        siri.undo()
        #expect(model.store.title == nil)
        #expect(model.store.tree.screens.count == 1)
        // Taking it back is a step of the design's own, which its Undo can take back in turn.
        model.store.undoManager?.undo()
        #expect(model.store.title == "A")
        #expect(model.store.tree.screens.count == 1)
    }

    @Test func siriUndoLeavesWhatWasChangedSinceAndBringsBackWhatItTookAway() throws {
        let model = model()
        let title = LayerNode.standard(.title), button = LayerNode.standard(.button), note = LayerNode.standard(.body)
        let screen = model.store.addFreeScreen([title, button, note])
        let other = model.store.addFreeScreen([], name: "Screen 2", origin: CGPoint(x: 500, y: 0))
        let siri = UndoManager()
        siri.groupsByEvent = false
        let red = RGBColor(hex: 0xFF0000)

        // One action recolours the title and the button, deletes the note, adds a symbol
        // and moves the second screen.
        DesignActions.edit(model, undoManager: siri, actionName: "Restyle") {
            model.store.update(title.id) { $0.style.tint = red }
            model.store.update(button.id) { $0.style.tint = red }
            model.store.delete(nodes: [note.id])
            model.store.add(.standard(.symbol), to: .screen(screen))
            model.store.updateTreeScreen(other) { $0.origin.x = 900 }
        }
        // By hand since: the button is given words of its own, and a screen is added.
        model.store.update(button.id) { $0.content.text = "Go" }
        let third = model.store.addFreeScreen([], name: "Screen 3", origin: CGPoint(x: 1400, y: 0))

        siri.undo()
        let elements = model.store.screenLeaves(screen)
        #expect(elements.map(\.id) == [title.id, button.id, note.id], "the note is back where it was, the symbol gone")
        #expect(elements[0].style.tint == title.style.tint, "the title is as it was")
        #expect(elements[1].style.tint == red && elements[1].content.text == "Go", "the button, changed since, is left as it is")
        #expect(model.store.treeScreen(other)?.origin.x == 500)
        #expect(model.store.treeScreen(third) != nil)
    }

    /// F6: a selected group is no single element to Siri, as several things aren't. Taken as
    /// one, Siri would move the group item alone, and every member would be ungrouped. A
    /// member selected inside the group is the one, as an element is.
    @Test func aSelectedGroupIsNoSingleElementForSiri() throws {
        let model = model()
        var button = LayerNode.standard(.button)
        button.frame.origin.y = 200
        let title = LayerNode.standard(.title)
        let screen = model.store.addFreeScreen([title, button])
        let refs = [title.id, button.id].map { NodeRef(host: .screen(screen), node: $0) }
        let both = try #require(CanvasSelection(refs.map(CanvasSelection.element)))
        let g = try #require(model.store.group(both))
        // What Siri is offered, as the design's snapshot lists it: the title, then the button.
        let entities = DesignSnapshot(id: "design", name: "Design", content: model.store.tree, modified: nil).elements
        #expect(entities.compactMap(\.ref) == refs)
        func isNotFound(_ error: LayerIntentError?) -> Bool {
            error.map { if case .elementNotFound = $0 { true } else { false } } == true
        }

        // The one leaf selected is `selectedLeaf(in:)`, and Siri's "this element" (`selected(in:)`, which
        // `nodeOrSelected` calls) throws `elementNotFound` when it is nil.
        model.selection = .element(g)
        #expect(DesignActions.selectedLeaf(in: model) == nil)
        #expect(isNotFound(#expect(throws: LayerIntentError.self) { try DesignActions.selected(in: model) }))
        #expect(DesignActions.suggested(entities, in: model).map(\.id) == entities.map(\.id), "nothing is put first")

        model.selection = .element(refs[1])
        #expect(DesignActions.selectedLeaf(in: model)?.ref == refs[1])
        #expect(try DesignActions.selected(in: model).ref == refs[1])
        #expect(DesignActions.suggested(entities, in: model).first?.ref == refs[1], "the button is put first")
    }

    /// Carried from Task 3: Siri's Lock or Unlock Element acts on the lock that holds a thing.
    /// Unlocking a member locked by its groups unlocks those groups too, as the popover and
    /// the panel do (ruling D); locking a member locks only it.
    @Test func siriUnlocksAMemberWithTheGroupsThatLockIt() throws {
        let board = OrderBoard()
        let i = board.group(board.c, board.e, named: "I") { $0.isLocked = true }
        let g = board.group(board.a, i, named: "G") { $0.isLocked = true }
        #expect(board.store.isLocked(.element(board.c)))
        let locked = board.store.tree

        try SetElementLockedIntent.setLocked(false, board.c, in: board.model, undoManager: nil)

        #expect(!board.store.isLocked(.element(board.c)))
        #expect(board.store.node(i.node)?.isLocked == false && board.store.node(g.node)?.isLocked == false)
        board.undo.undo()
        #expect(board.store.tree == locked, "one step")

        let unlocked = OrderBoard()
        let inner = unlocked.group(unlocked.c, unlocked.e, named: "I")
        let outer = unlocked.group(unlocked.a, inner, named: "G")
        try SetElementLockedIntent.setLocked(true, unlocked.c, in: unlocked.model, undoManager: nil)
        #expect(unlocked.store.node(unlocked.c.node)?.isLocked == true)
        #expect(unlocked.store.node(inner.node)?.isLocked == false && unlocked.store.node(outer.node)?.isLocked == false)
        #expect(!unlocked.store.isLocked(.element(unlocked.e)))
    }

    /// Siri doesn't move, align or delete a member of a locked group, as a finger can't,
    /// though the member's own lock isn't set (F4).
    @Test func siriLeavesAMemberOfALockedGroupWhereItIs() throws {
        let board = OrderBoard()
        board.group(board.b, board.d) { $0.isLocked = true }
        let before = board.store.tree
        func isLocked(_ error: LayerIntentError?) -> Bool {
            error.map { if case .locked = $0 { true } else { false } } == true
        }

        // What Move, Move to Screen, Align and Delete ask before they act.
        #expect(isLocked(#expect(throws: LayerIntentError.self) { try DesignActions.requireUnlocked(board.b, in: board.model) }))
        #expect(isLocked(#expect(throws: LayerIntentError.self) {
            try MoveElementIntent.move(board.b, in: board.model, x: 0, y: 0, width: nil, height: nil, undoManager: nil)
        }))
        #expect(isLocked(#expect(throws: LayerIntentError.self) {
            try DeleteElementIntent.delete(board.d, in: board.model, undoManager: nil)
        }))
        #expect(board.store.tree == before)

        // What isn't locked is moved and deleted.
        try MoveElementIntent.move(board.a, in: board.model, x: 10, y: nil, width: nil, height: nil, undoManager: nil)
        #expect(board.store.ownFrame(board.a.node)?.minX == 10)
        try DeleteElementIntent.delete(board.c, in: board.model, undoManager: nil)
        #expect(board.store.node(board.c.node) == nil)
    }

    @Test func anElementMovedOffAScreenThatHasSinceGoneStaysWhereItIs() throws {
        let model = model()
        let button = LayerNode.standard(.button)
        let first = model.store.addFreeScreen([button])
        let second = model.store.addFreeScreen([], name: "Screen 2", origin: CGPoint(x: 500, y: 0))
        let siri = UndoManager()
        siri.groupsByEvent = false
        DesignActions.edit(model, undoManager: siri, actionName: "Move Button") {
            // Onto the second screen, where its frame puts it there.
            model.store.move(button.id, to: .screen(second))
            model.store.update(button.id) { $0.frame = button.frame }
        }
        // The screen it came from is deleted by hand.
        model.store.deleteScreen(first)
        let now = model.store.content
        #expect(!(model.takenActions.first?.canTakeBack(from: now) ?? true), "there is nowhere to put it back")

        siri.undo()
        #expect(model.store.tree == now)
        // (b): the tree holds nothing on a screen that has gone, so the flat list's check of that is dropped.
        #expect(model.store.screenLeaves(second).map(\.id) == [button.id])
    }

    @Test func siriUndoDuringADragIsAStepOfItsOwnAndLeavesTheDragOne() throws {
        let model = model()
        let button = LayerNode.standard(.button)
        model.store.addFreeScreen([button])
        let siri = UndoManager()
        siri.groupsByEvent = false
        DesignActions.edit(model, undoManager: siri, actionName: "Rename Design") { model.store.setTitle("A") }

        // Siri's undo comes while a drag is under way.
        let drag = model.store.beginEdit(by: .hand)
        model.store.update(button.id) { $0.frame.origin.x += 10 }
        siri.undo()
        model.store.update(button.id) { $0.frame.origin.x += 10 }
        model.store.endEdit(drag)
        #expect(model.store.title == nil)
        #expect(model.store.ownFrame(button.id)?.minX == button.frame.minX + 20)

        // Siri's undo is a step of its own, and the drag one step of its own.
        model.store.undoManager?.undo()
        #expect(model.store.title == "A")
        #expect(model.store.ownFrame(button.id)?.minX == button.frame.minX + 20)
        model.store.undoManager?.undo()
        #expect(model.store.title == "A")
        #expect(model.store.ownFrame(button.id)?.minX == button.frame.minX)
    }

    @Test func siriIsNotOfferedAnUndoOnceTheDesignHasClosed() throws {
        let model = model()
        let siri = UndoManager()
        siri.groupsByEvent = false
        _ = DesignActions.edit(model, undoManager: siri, actionName: "Add Screen") {
            model.store.addFreeScreen([])
        }
        #expect(siri.canUndo)
        model.close()
        // Nothing for Siri to undo, rather than an undo that does nothing and says it did.
        #expect(!siri.canUndo)
        let reopened = AppModel(document: LayerDocument(file: model.document.current))
        if siri.canUndo { siri.undo() }
        #expect(reopened.store.tree.screens.count == 1)
        reopened.close()
    }

    @Test func anUndoWithNothingLeftToTakeBackChangesNothingAndSaysSo() throws {
        let model = model()
        let button = LayerNode.standard(.button)
        model.store.addFreeScreen([button])
        let siri = UndoManager()
        siri.groupsByEvent = false

        DesignActions.edit(model, undoManager: siri, actionName: "Style Button") {
            model.store.update(button.id) { $0.style.tint = RGBColor(hex: 0xFF0000) }
        }
        // The button is recoloured again by hand: what Siri changed is gone.
        model.store.update(button.id) { $0.style.tint = RGBColor(hex: 0x00FF00) }
        let now = model.store.tree
        siri.undo()
        #expect(model.store.tree == now)
        #expect(model.undoNotice?.contains("Style Button") == true)

        // Checked before Siri can be asked, as the app stops being active, such an undo
        // is taken out of Siri's history instead.
        model.undoNotice = nil
        DesignActions.edit(model, undoManager: siri, actionName: "Style Button") {
            model.store.update(button.id) { $0.style.tint = RGBColor(hex: 0x0000FF) }
        }
        model.withdrawTakenActionsWithNothingLeft()
        #expect(siri.canUndo, "the button is still as Siri left it")
        model.store.update(button.id) { $0.style.tint = RGBColor(hex: 0x00FF00) }
        model.withdrawTakenActionsWithNothingLeft()
        #expect(!siri.canUndo)
    }

    @Test func newElementsGoBelowWhatIsThere() throws {
        let model = model()
        let screen = model.store.addFreeScreen([])
        var title = LayerNode.standard(.title)
        title.frame = try #require(model.store.newElementFrame(.title, on: screen))
        model.store.add(title, to: .screen(screen))
        let device = try #require(model.store.device(of: screen))
        let frame = try #require(model.store.newElementFrame(.button, on: screen))
        #expect(frame.minY >= title.frame.maxY)
        #expect(frame.maxY <= device.size.height - device.safeBottom)
    }

    @Test func entitiesDescribeTheDesign() {
        let content = {
            var content = TreeContent()
            content.title = "Shop"
            var button = LayerNode.standard(.button)
            button.content.text = "Buy now"
            var checkout = TreeScreen(name: "Checkout", origin: .zero, scale: 1, deviceID: nil)
            checkout.root.children = [button]
            content.screens = [checkout]
            return content
        }()
        let snapshot = DesignSnapshot(id: "local:Shop.layer", name: "Shop", content: content, modified: nil)
        #expect(snapshot.entity.screenNames == ["Checkout"])
        #expect(snapshot.screens.first?.summary == "button “Buy now”")
        let element = snapshot.elements.first
        #expect(element?.text == "Buy now")
        #expect(element?.screenName == "Checkout")
        #expect(element.flatMap { EntityKey.parseElement($0.id)?.design } == "local:Shop.layer")
        #expect(DesignDescriber.describe(snapshot).contains("Checkout (iPhone): button “Buy now”"))
    }
}

@Suite("Image Playground")
@MainActor
struct ImagePlaygroundTests {
    private func modelWithScreen() -> (AppModel, TreeScreen.ID) {
        let model = AppModel(document: LayerDocument())
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.store.undoManager = undo
        model.store.setTitle("Wander")
        let screen = model.store.addFreeScreen([], name: "Welcome")
        let written = Outline.parse("title: Plan your trip\nbody: Beaches, cities and mountains\nbutton: Get started\ntext field", isComplete: true)
        model.store.replaceChildren(of: .screen(screen), with: written.children)
        return (model, screen)
    }

    /// A small square picture, as Image Playground hands one back.
    private func picture(width: Int = 64, height: Int = 32) throws -> ImageImport.Prepared {
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let data = try #require(image.pngData())
        return try #require(ImageImport.prepare(data))
    }

    @Test func conceptsTakeThePromptAndTheScreensOwnWords() {
        let (model, screen) = modelWithScreen()
        let request = ImagePlaygroundRequest(target: .newImage(onScreen: screen), prompt: "  a lighthouse  ")
        let concepts = model.imageConcepts(for: request)
        #expect(concepts.prompt == "a lighthouse")
        // Placeholder words, such as an untouched text field's, are left out.
        #expect(concepts.context == "Plan your trip. Beaches, cities and mountains. Get started")
        #expect(concepts.title == "Wander – Welcome")
    }

    @Test func aNewImageGoesBelowWhatIsOnTheScreenAndIsSelected() throws {
        let (model, screen) = modelWithScreen()
        let lowestBefore = model.store.screenLeaves(screen).compactMap { model.store.ownFrame($0.id)?.maxY }.max() ?? 0
        let size = try #require(model.store.device(of: screen)).size
        let request = ImagePlaygroundRequest(target: .newImage(onScreen: screen))
        model.imagePlaygroundRequest = request
        let ref = try #require(model.placeGeneratedImage(try picture(), for: request))
        let placed = try #require(model.store.placed(ref)?.node)
        let frame = try #require(model.store.ownFrame(ref.node))
        #expect(placed.kind == .image)
        #expect(placed.content.imageID != nil)
        #expect(model.document.current.images[placed.content.imageID!.uuidString] != nil)
        // Its shape follows the picture's, 2:1 here.
        #expect(frame.width == size.width - 40)
        #expect(frame.height == (frame.width / 2).rounded())
        #expect(frame.minY >= lowestBefore)
        #expect(model.selection == .element(ref))
        #expect(model.imagePlaygroundRequest == nil)
    }

    @Test func aNewPictureForAnImageKeepsItsPlaceAndUndoes() throws {
        let (model, screen) = modelWithScreen()
        let image = LayerNode.leaf(.image, frame: CGRect(x: 30, y: 400, width: 200, height: 120))
        model.store.add(image, to: .screen(screen))
        let ref = NodeRef(host: .screen(screen), node: image.id)

        let request = ImagePlaygroundRequest(target: .replace(ref), prompt: "mountains")
        #expect(model.imageSize(for: request) == CGSize(width: 200, height: 120))
        try #require(model.placeGeneratedImage(try picture(), for: request) == ref)
        let replaced = try #require(model.store.placed(ref)?.node)
        #expect(replaced.content.imageID != nil)
        #expect(model.store.ownFrame(image.id) == image.frame)

        model.store.undoManager?.undo()
        #expect(model.store.placed(ref)?.node.content.imageID == nil)
    }
}

@Suite("Stroke scripts")
struct StrokeScriptTests {
    private func observation(_ paths: [[CGPoint]]) -> SketchObservation? {
        SketchAnalyzer.observe(paths.enumerated().map { SketchStroke(key: Double($0.offset), points: $0.element) })
    }

    @Test func readsFreehandPointsAndFillsThemIn() throws {
        let strokes = try StrokeScript.parse("20,40 120,40 120,90")
        #expect(strokes.count == 1)
        let stroke = strokes[0]
        #expect(stroke.first == CGPoint(x: 20, y: 40))
        #expect(stroke.last == CGPoint(x: 120, y: 90))
        // Filled in no more than three points apart, so PencilKit doesn't round the corner off.
        for (a, b) in zip(stroke, stroke.dropFirst()) {
            #expect(hypot(b.x - a.x, b.y - a.y) <= 3.01)
        }
        #expect(stroke.contains(CGPoint(x: 120, y: 40)))
    }

    @Test func readsShapesCommentsAndSemicolons() throws {
        let strokes = try StrokeScript.parse("""
        # an image placeholder
        box 34 186 326 364 radius 40
        cross 34 186 326 364
        // and a title
        wave 150 112 96 40 3; tick 300 640 24 24
        """)
        // The cross is two strokes.
        #expect(strokes.count == 5)
        let box = strokes[0]
        let xs = box.map(\.x), ys = box.map(\.y)
        #expect(abs((xs.min() ?? 0) - 34) < 3 && abs((xs.max() ?? 0) - 360) < 3)
        #expect(abs((ys.min() ?? 0) - 186) < 3 && abs((ys.max() ?? 0) - 550) < 3)
    }

    @Test func readsNegativeAndDecimalNumbers() {
        #expect(StrokeScript.numbers(in: "line -10.5 4 20,-3") == [-10.5, 4, 20, -3])
    }

    @Test func readsJSON() throws {
        let pairs = try StrokeScript.parse("[[[0, 0], [30, 0]], [{\"x\": 5, \"y\": 5}, {\"x\": 5, \"y\": 50}]]")
        #expect(pairs.count == 2)
        #expect(pairs[1].first == CGPoint(x: 5, y: 5))
        #expect(pairs[1].last == CGPoint(x: 5, y: 50))
        let wrapped = try StrokeScript.parse("{\"strokes\": [[[0, 0], [10, 10]]]}")
        #expect(wrapped.count == 1)
    }

    @Test func saysWhichLineItCouldNotRead() {
        #expect(throws: StrokeScript.ParseError.self) { try StrokeScript.parse("box 1 2 3 4\ntriangle 1 2 3") }
        do {
            _ = try StrokeScript.parse("box 1 2 3 4\ntriangle 1 2 3")
        } catch let error as StrokeScript.ParseError {
            #expect(error.line == 2)
            #expect(error.text == "triangle 1 2 3")
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(throws: StrokeScript.ParseError.self) { try StrokeScript.parse("10,10 20") }
        #expect(throws: StrokeScript.ParseError.self) { try StrokeScript.parse("[[[0, 0]]]") }
    }

    /// A number past Int's range used to trap working out how many points a line needs
    /// (G9): a Siri or Shortcuts script could crash the app.
    @Test func aNumberTooLargeToDrawIsRefusedNotATrap() {
        #expect(throws: StrokeScript.ParseError.self) { try StrokeScript.parse("line 0 0 99999999999999999999 0") }
        #expect(throws: StrokeScript.ParseError.self) { try StrokeScript.parse("[[[0, 0], [1e300, 0]]]") }
    }

    /// Strokes that would take hundreds of millions of points, or that many passes or
    /// humps, were built anyway and the app was killed for memory (G9). They are refused
    /// with a reason, and a stroke the size of a board still draws.
    @Test func aStrokeTooLongToDrawIsRefused() throws {
        for script in ["line 0 0 200000 0", "wave 0 0 100 40 1000", "scribble 0 0 10 10 1000", "box 0 0 30000 30000"] {
            #expect(throws: StrokeScript.ParseError.self, "\(script)") { try StrokeScript.parse(script) }
        }
        #expect(try StrokeScript.parse("line 0 0 4000 3000").count == 1)
        #expect(try StrokeScript.parse("wave 0 0 300 40 12").count == 1)
    }

    /// A line of many long segments was built, tens of millions of points, before it was
    /// refused (review M-6). Its length is weighed first.
    @Test func aStrokeTooLongIsRefusedBeforeItIsBuilt() {
        let corners = (0..<1000).map { $0.isMultiple(of: 2) ? "0 0" : "100000 100000" }.joined(separator: " ")
        let clock = ContinuousClock()
        let took = clock.measure {
            #expect(throws: StrokeScript.ParseError.self) { try StrokeScript.parse("line " + corners) }
            #expect(throws: StrokeScript.ParseError.self) { try StrokeScript.parse(corners.replacingOccurrences(of: " 100000", with: ",100000")) }
        }
        #expect(took < .milliseconds(200))
    }

    @Test func aScriptedBoxIsReadLikeADrawnOne() throws {
        let observed = try #require(observation(try StrokeScript.parse("box 100 80 260 560 10")))
        guard case .enclosure = observed.form else {
            Issue.record("expected an enclosure, got \(observed.form)")
            return
        }
        let pill = try #require(observation(try StrokeScript.parse("pill 40 500 220 40")))
        guard case .enclosure(let roundness, _) = pill.form else {
            Issue.record("expected an enclosure, got \(pill.form)")
            return
        }
        #expect(roundness > 0.75)
    }
}

@Suite("Look words")
struct LookWordTests {
    @Test func controlsTakeTheirState() {
        let root = TreeRules.laidOut(Outline.parse("""
        checkbox [off]
        radio [selected]
        progress [40%]
        button: Skip [plain, centre, shadow, border red, opacity 50%]
        """, isComplete: true), deviceID: DeviceFrame.iPhone.id, settings: CanvasSettings(), previous: nil)
        func leaves(_ node: LayerNode) -> [LayerNode] { node.isContainer ? node.children.flatMap(leaves) : [node] }
        let laid = leaves(root)
        #expect(laid.map(\.kind) == [.checkbox, .radio, .progress, .button])
        guard laid.count == 4 else { return }
        #expect(laid[0].content.isOn == false)
        #expect(laid[1].content.isOn == true)
        #expect(laid[2].content.value == 0.4)
        let skip = laid[3]
        #expect(skip.content.buttonLook == .plain)
        #expect(skip.style.textAlignment == .center)
        #expect(skip.style.hasShadow == true)
        #expect(skip.style.borderColor == ColourWords.named["red"])
        #expect(skip.style.borderWidth == 1)
        #expect(skip.style.opacity == 0.5)
    }
}

/// Siri's Move to Screen (`MoveElementToScreenIntent.move`), the live path since plan 6's Task 5: the store's flat
/// `move(_:toScreen:origin:)`, which these tests drove before, is called by nothing in the app.
@Suite("Moving things from code")
@MainActor
struct MovingTests {
    private func model() -> AppModel {
        let model = AppModel(document: LayerDocument())
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.store.undoManager = undo
        return model
    }

    @Test func anElementMovesToAnotherScreenAndBack() throws {
        let model = model()
        let button = LayerNode.leaf(.button, frame: CGRect(x: 20, y: 700, width: 353, height: 50))
        let first = model.store.addFreeScreen([button], scale: 0.5)
        let second = model.store.addFreeScreen([], name: "Screen 2", origin: CGPoint(x: 400, y: 0), scale: 0.5)
        let ref = NodeRef(host: .screen(first), node: button.id)

        let moved = try MoveElementToScreenIntent.move(ref, toScreen: second, x: 20, y: 100, in: model, undoManager: nil)
        #expect(moved.host == .screen(second))
        #expect(model.store.screenLeaves(first).isEmpty)
        #expect(model.store.placed(moved)?.frame == CGRect(x: 20, y: 100, width: 353, height: 50))

        model.store.undoManager?.undo()
        #expect(model.store.placed(ref)?.frame == button.frame)
        #expect(model.store.screenLeaves(second).isEmpty)
    }

    @Test func offAScreenItKeepsItsPlaceAndSize() throws {
        let model = model()
        let title = LayerNode.leaf(.title, frame: CGRect(x: 40, y: 80, width: 200, height: 40))
        let screen = model.store.addFreeScreen([title], origin: CGPoint(x: 100, y: 100), scale: 0.5)
        let ref = NodeRef(host: .screen(screen), node: title.id)
        let before = try #require(model.store.placed(ref)).placement.canvasRect(for: title.frame)

        let moved = try MoveElementToScreenIntent.move(ref, toScreen: nil, x: nil, y: nil, in: model, undoManager: nil)
        #expect(moved.host == .canvas)
        let after = try #require(model.store.placed(moved))
        #expect(after.placement.canvasRect(for: after.frame) == before)
    }

    @Test func stickyNotesStayOffScreens() {
        let model = model()
        let screen = model.store.addFreeScreen([])
        let note = NodeRef(host: .canvas, node: model.store.addCanvasNode(.standard(.stickyNote)))
        let refused = #expect(throws: LayerIntentError.self) {
            try MoveElementToScreenIntent.move(note, toScreen: screen, x: 0, y: 0, in: model, undoManager: nil)
        }
        #expect(refused.map { if case .cantGoOnScreens = $0 { true } else { false } } == true)
        #expect(model.store.tree.canvas.count == 1)
    }

    @Test func theLayoutReadsBackAsJSON() throws {
        let model = model()
        let screen = model.store.addFreeScreen([], origin: CGPoint(x: 10, y: 20), scale: 0.5)
        let written = Outline.parse("title: Hello\ntoggle [off]", isComplete: true)
        model.store.replaceChildren(of: .screen(screen), with: written.children)
        model.store.addCanvasNode(.standard(.stickyNote), scale: 0.5)
        let snapshot = DesignSnapshot(id: "local:Test.layer", name: "Test", content: model.store.tree, modified: nil)

        let json = DesignLayoutWriter.json(for: snapshot, ink: (count: 3, bounds: CGRect(x: 0, y: 0, width: 10, height: 10)))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let screens = try #require(root["screens"] as? [[String: Any]])
        #expect(screens.count == 1)
        #expect(screens[0]["x"] as? Double == 10)
        #expect(screens[0]["scale"] as? Double == 50)
        let elements = try #require(screens[0]["elements"] as? [[String: Any]])
        #expect(elements.map { $0["kind"] as? String } == ["title", "toggle"])
        #expect(elements[0]["text"] as? String == "Hello")
        #expect(elements[1]["on"] as? Bool == false)
        let id = try #require(elements[0]["id"] as? String)
        #expect(EntityKey.parseElement(id)?.design == "local:Test.layer")
        #expect((root["canvasElements"] as? [[String: Any]])?.count == 1)
        #expect((root["ink"] as? [String: Any])?["strokes"] as? Int == 3)
    }
}
