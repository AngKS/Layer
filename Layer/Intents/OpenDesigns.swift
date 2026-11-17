import Observation
import UIKit

/// The designs open in Layer's windows, so that Siri and Shortcuts can work on them, and
/// the way their actions open a design or make a new one.
@MainActor @Observable
final class OpenDesigns {
    static let shared = OpenDesigns()

    @ObservationIgnored private var models: [Weak] = []

    private struct Weak {
        weak var model: AppModel?
    }

    private init() {}

    // MARK: Kept up to date by the open designs

    func opened(_ model: AppModel) {
        models.removeAll { $0.model == nil || $0.model === model }
        models.append(Weak(model: model))
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

    func model(forDesign id: String) -> AppModel? {
        models.last(where: { $0.model?.designID == id })?.model
    }

    var all: [AppModel] { models.compactMap(\.model) }

    // MARK: Opening and making designs

    /// Opens a design, if it isn't open already, and waits for its window.
    func open(design id: String) async throws -> AppModel {
        if let model = model(forDesign: id) { return model }
        guard let url = DesignLibrary.url(for: id) else { throw LayerIntentError.designNotFound }
        guard FileManager.default.fileExists(atPath: url.path) else { throw LayerIntentError.designNotFound }
        // A design still closing can keep the browser from taking the request, so it is
        // asked again if the design hasn't opened after a few seconds.
        for _ in 0..<3 {
            try await DocumentBrowser.open(url)
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
        return try await open(design: DesignLibrary.id(for: url))
    }
}

/// Opens a design the way picking it in Layer's document browser does. SwiftUI's own
/// `openDocument` action isn't available on iPadOS, so this asks the browser that
/// `DocumentGroup` puts in each window, through its delegate, which is how the browser
/// itself opens what is picked.
@MainActor
enum DocumentBrowser {
    static func open(_ url: URL) async throws {
        // An app Siri has just launched may not have its window up yet.
        for _ in 0..<30 {
            if let browser = find(), let delegate = browser.delegate,
               delegate.responds(to: #selector(UIDocumentBrowserViewControllerDelegate.documentBrowser(_:didPickDocumentsAt:))) {
                // A design open over the browser is put away first, as tapping Back would.
                if let presented = browser.presentedViewController {
                    await withCheckedContinuation { continuation in
                        presented.dismiss(animated: false) { continuation.resume() }
                    }
                }
                delegate.documentBrowser?(browser, didPickDocumentsAt: [url])
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LayerIntentError.couldNotOpen
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
