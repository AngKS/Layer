import Observation
import os
import UIKit

/// The designs open in Layer's windows, so that Siri and Shortcuts can work on them, and
/// the way their actions open a design or make a new one.
@MainActor @Observable
final class OpenDesigns {
    static let shared = OpenDesigns()

    @ObservationIgnored private var models: [Weak] = []
    /// The identifier each design had before its file was renamed, with the one it moved
    /// to. A design is known by its file's path (see `DesignLibrary`), so a rename, Layer's
    /// own included, would leave Siri and Shortcuts holding an identifier that finds
    /// nothing. Kept while Layer runs.
    @ObservationIgnored private var renamed: [String: String] = [:]

    private struct Weak {
        weak var model: AppModel?
    }

    private init() {}

    // MARK: Kept up to date by the open designs

    func opened(_ model: AppModel) {
        models.removeAll { $0.model == nil || $0.model === model }
        models.append(Weak(model: model))
        // A design open under an identifier is the one it means now.
        if let id = model.designID { renamed[id] = nil }
    }

    /// A design's file moved, as when it was renamed: it is known by `new` from now on,
    /// and still found by `old`.
    func designMoved(from old: String, to new: String) {
        guard old != new else { return }
        renamed[old] = new
        renamed[new] = nil
    }

    /// The design came to the front, or its window became the active one.
    func activated(_ model: AppModel) {
        opened(model)
    }

    func closed(_ model: AppModel) {
        models.removeAll { $0.model == nil || $0.model === model }
    }

    // MARK: Looking designs up

    /// The design last brought to the front.
    var current: AppModel? {
        models.last(where: { $0.model?.designID != nil })?.model ?? models.last?.model
    }

    /// The open design an identifier means, which may be one it had before its file was renamed.
    func model(forDesign id: String) -> AppModel? {
        let id = currentID(for: id)
        return models.last(where: { $0.model?.designID == id })?.model
    }

    var all: [AppModel] { models.compactMap(\.model) }

    /// The identifier a design is known by now, following its renames from `id`. A design
    /// open under `id` itself, or any file now at its path, is the one it means: a rename
    /// is followed only while nothing is where the design was, and forgotten once something
    /// is, as when another device syncs a new "Untitled" into the folder.
    func currentID(for id: String) -> String {
        var id = id
        var seen: Set<String> = [id]
        while !models.contains(where: { $0.model?.designID == id }), let next = renamed[id] {
            if Self.somethingIsAt(id) {
                renamed[id] = nil
                break
            }
            guard seen.insert(next).inserted else { break }
            id = next
        }
        return id
    }

    /// Whether a file is at a design identifier's path, downloaded or not: iCloud may keep
    /// one that isn't as a hidden placeholder, `.Name.layer.icloud`. Only looked at for an
    /// identifier a design was renamed away from.
    private static func somethingIsAt(_ id: String) -> Bool {
        guard let url = DesignLibrary.url(for: id) else { return false }
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        return FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: placeholder.path)
    }

    // MARK: Opening and making designs

    /// Gets the designs shown in `controller` ready to go, as the back button does, before
    /// an action puts it away to open another: their pictures drawn as they were left,
    /// their names settled and their files named after them. Put away without this, a
    /// design kept the picture of the board from before its last edits, and a name still
    /// being thought up was dropped. The design with identifier `keeping`, the one being
    /// opened, is left alone.
    func prepareToPutAway(_ controller: UIViewController, keeping id: String?) async {
        let target = id.map(currentID(for:))
        for model in all where model.designID != target && model.isShown(in: controller.view) {
            await model.prepareToClose()
        }
    }

    /// Opens a design, if it isn't open already, and waits for its window.
    func open(design id: String) async throws -> AppModel {
        if let model = model(forDesign: id) { return model }
        guard let url = DesignLibrary.url(for: currentID(for: id)) else { throw LayerIntentError.designNotFound }
        guard FileManager.default.fileExists(atPath: url.path) else { throw LayerIntentError.designNotFound }
        // A design still closing can keep the browser from taking the request, so it is
        // asked again if the design hasn't opened after a few seconds.
        for _ in 0..<3 {
            try await DocumentBrowser.open(url) { [weak self] presented in
                await self?.prepareToPutAway(presented, keeping: id)
            }
            for _ in 0..<30 {
                if let model = model(forDesign: id) { return model }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw LayerIntentError.couldNotOpen
    }

    /// Makes a new, empty design in Layer's folder, opens it, and waits for its window.
    func makeNew(named title: String?) async throws -> AppModel {
        let name = title.map(DesignFileName.fileName(for:)).flatMap { $0.isEmpty ? nil : $0 } ?? DesignFileName.untitled
        let url = try await Task.detached(priority: .userInitiated) { () throws -> URL in
            let roots = DesignLibrary.roots
            let folder = roots.cloud ?? roots.local
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = DesignFileName.unused(name, extension: "layer", in: folder) {
                FileManager.default.fileExists(atPath: $0.path)
            }
            var file = DesignFile()
            file.content.title = title
            file.content.canvas.model = ModelPreferences.defaultChoice
            let wrapper = try file.wrapper()
            var coordinationError: NSError?
            var writeError: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { target in
                do { try wrapper.write(to: target, options: .atomic, originalContentsURL: nil) } catch { writeError = error }
            }
            if let error = coordinationError ?? writeError { throw error }
            return destination
        }.value
        let id = DesignLibrary.id(for: url)
        // A design renamed away from this name earlier isn't what the new one is.
        renamed[id] = nil
        return try await open(design: id)
    }
}

/// Runs one piece of work at a time, in the order asked: each waits for the one before
/// it to finish, or to run out of time. A waiter that is cancelled leaves the queue.
@MainActor
final class OneAtATime {
    /// How long one piece of work may hold the turn. Its caller is then told the design
    /// couldn't be opened, and the next goes, whatever the work is still waiting for.
    let limit: Duration
    private var isRunning = false
    private var waiting: [(id: Int, continuation: CheckedContinuation<Void, any Error>)] = []
    private var lastWaiter = 0

    init(limit: Duration) {
        self.limit = limit
    }

    /// How many are waiting for their turn.
    var queued: Int { waiting.count }

    func run<T: Sendable>(_ work: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
        try await waitForTurn()
        // The turn passes straight to the next in line, given up on or not.
        defer { passTurnOn() }
        try Task.checkCancellation()
        return try await withinLimit(work)
    }

    private func waitForTurn() async throws {
        guard isRunning else {
            isRunning = true
            return
        }
        lastWaiter += 1
        let id = lastWaiter
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                waiting.append((id, continuation))
            }
        } onCancel: {
            Task { @MainActor in self.leave(id) }
        }
    }

    /// A waiter that was cancelled before its turn came stops waiting.
    private func leave(_ id: Int) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func passTurnOn() {
        if waiting.isEmpty {
            isRunning = false
        } else {
            waiting.removeFirst().continuation.resume()
        }
    }

    /// The work's outcome, or, if it hasn't one within `limit`, that the design couldn't be
    /// opened. Work still waiting then is cancelled and left to end by itself.
    private func withinLimit<T: Sendable>(_ work: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
        let limit = limit
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            let first = FirstToFinish()
            let job = Task { @MainActor in
                do {
                    let value = try await work()
                    if first.claim() { continuation.resume(returning: value) }
                } catch {
                    if first.claim() { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(for: limit)
                guard first.claim() else { return }
                job.cancel()
                continuation.resume(throwing: LayerIntentError.couldNotOpen)
            }
        }
    }
}

/// Of several ways a wait can end, lets the first through and no other.
final class FirstToFinish: Sendable {
    private let finished = OSAllocatedUnfairLock(initialState: false)

    /// True for the first caller only.
    func claim() -> Bool {
        finished.withLock { finished in
            defer { finished = true }
            return !finished
        }
    }
}

/// Opens a design the way picking it in Layer's document browser does. SwiftUI's own
/// `openDocument` action isn't available on iPadOS, so this asks the browser that
/// `DocumentGroup` puts in each window, through its delegate, which is how the browser
/// itself opens what is picked.
@MainActor
enum DocumentBrowser {
    /// One action puts away a design and picks another at a time: two at once would each
    /// put away the design the other picked. A turn holds up to three waits of two seconds,
    /// for a rename, a design coming up and its dismissal, so may last eight.
    private static let turns = OneAtATime(limit: .seconds(8))

    /// `prepare` is given the controller of a design open over the browser, before it is
    /// put away. Throws `couldNotOpen` when putting it away doesn't finish in time.
    static func open(_ url: URL, preparing prepare: @escaping @MainActor @Sendable (UIViewController) async -> Void = { _ in }) async throws {
        // An app Siri has just launched may not have its window up yet.
        for _ in 0..<30 {
            if let browser = find(), let delegate = browser.delegate,
               delegate.responds(to: #selector(UIDocumentBrowserViewControllerDelegate.documentBrowser(_:didPickDocumentsAt:))) {
                try await turns.run {
                    try await pick(url, in: browser, preparing: prepare) { url in
                        delegate.documentBrowser?(browser, didPickDocumentsAt: [url])
                    }
                }
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LayerIntentError.couldNotOpen
    }

    /// Picks `url` in a browser, with `picking`, as the browser itself does. A design open
    /// over the browser is put away first, as tapping Back would: given to `prepare` while
    /// it is still shown, then dismissed, unless it went or began to go meanwhile. A design
    /// still coming up is waited for first, since UIKit can leave a dismiss asked for then
    /// unanswered. Each wait lasts at most `limit`; past it, the design couldn't be opened.
    static func pick(
        _ url: URL, in browser: UIViewController, limit: Duration = .seconds(2),
        dismissing dismiss: (UIViewController, @escaping @Sendable () -> Void) -> Void = { controller, done in controller.dismiss(animated: false) { done() } },
        preparing prepare: (UIViewController) async -> Void, picking: (URL) -> Void
    ) async throws {
        if let presented = browser.presentedViewController {
            await prepare(presented)
            // An open given up on meanwhile goes no further: the next may already be under way.
            try Task.checkCancellation()
            let deadline = ContinuousClock.now + limit
            while presented.isBeingPresented, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            if browser.presentedViewController === presented, !presented.isBeingDismissed {
                guard !presented.isBeingPresented, await finishes(within: limit, { done in dismiss(presented, done) }) else {
                    throw LayerIntentError.couldNotOpen
                }
            }
        }
        // Nor does one given up on while its design was being dismissed.
        try Task.checkCancellation()
        picking(url)
    }

    /// Whether `start` says it has finished within `limit`.
    private static func finishes(within limit: Duration, _ start: (@escaping @Sendable () -> Void) -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            let first = FirstToFinish()
            start {
                if first.claim() { continuation.resume(returning: true) }
            }
            Task {
                try? await Task.sleep(for: limit)
                if first.claim() { continuation.resume(returning: false) }
            }
        }
    }

    /// The document browser in every window.
    static func all() -> [UIDocumentBrowserViewController] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .compactMap { search($0.rootViewController) }
    }

    /// The document browser in the frontmost window.
    private static func find() -> UIDocumentBrowserViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .sorted { rank($0.activationState) < rank($1.activationState) }
        for scene in scenes {
            for window in scene.windows {
                if let browser = search(window.rootViewController) { return browser }
            }
        }
        return nil
    }

    private static func rank(_ state: UIScene.ActivationState) -> Int {
        switch state {
        case .foregroundActive: 0
        case .foregroundInactive: 1
        case .background: 2
        default: 3
        }
    }

    private static func search(_ controller: UIViewController?) -> UIDocumentBrowserViewController? {
        guard let controller else { return nil }
        if let browser = controller as? UIDocumentBrowserViewController { return browser }
        for child in controller.children {
            if let browser = search(child) { return browser }
        }
        // On iPadOS 26 and later the launch screen presents the browser over itself.
        return search(controller.presentedViewController)
    }
}
