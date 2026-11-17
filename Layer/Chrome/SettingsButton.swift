import SwiftUI
import UIKit

/// Puts a settings cog among the document browser's own buttons, at the top of the
/// Recents panel beside its view options, More and Search buttons. `DocumentGroup`
/// builds the browser itself, so the button is added to the browser it made, through
/// the browser's own place for an app's extra buttons.
@MainActor
enum SettingsButton {
    static let identifier = "layer.settings"

    /// Adds the cog to every browser on screen, waiting briefly for one to appear: the
    /// launch screen puts its browser up a moment after its own view.
    static func install() async {
        for _ in 0..<50 {
            let browsers = DocumentBrowser.all()
            if !browsers.isEmpty {
                browsers.forEach(add(to:))
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func add(to browser: UIDocumentBrowserViewController) {
        if browser.additionalTrailingNavigationBarButtonItems.contains(where: { $0.accessibilityIdentifier == identifier }) { return }
        let button = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"),
            primaryAction: UIAction { [weak browser] _ in
                if let browser { present(from: browser) }
            }
        )
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = "Settings"
        browser.additionalTrailingNavigationBarButtonItems.append(button)
    }

    /// Shows the settings as a sheet from the bottom: a half-height sheet that can be
    /// pulled up in a narrow window, a centered card at full width.
    private static func present(from browser: UIDocumentBrowserViewController) {
        let presenter = browser.presentedViewController ?? browser
        weak var shown: UIViewController?
        let host = UIHostingController(rootView: ModelSettingsView(onDone: { shown?.dismiss(animated: true) }))
        shown = host
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        }
        presenter.present(host, animated: true)
    }
}
