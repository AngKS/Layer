import Testing
import UIKit

/// The suites that put a window of their own in the app's scene and make it key, to see
/// focus, the keyboard or SwiftUI's updates.
///
/// Not serialized, though one could take the key window from another at a pause. Run one at
/// a time they made the whole run 11-12 s rather than 8, and in each of four runs a voice
/// call test failed: a call started by another suite ends the current one (`VoiceCall.start`
/// ends `VoiceCall.current`), and the longer run gave that more chances. Run alongside each
/// other they passed in every run, and the run did too. Their fields keep the on-screen
/// keyboard down where they can (`quietTextField`).
@MainActor
@Suite("In a window of their own")
enum HostedWindowSuites {}

/// A window of its own in the app's scene, for a test that needs UIKit or SwiftUI on screen:
/// focus, the keyboard, a hosted view's updates. The tests start as the app launches, before
/// its scene has connected, so this waits for it: up to 30 seconds, while other builds keep
/// the Mac busy.
@MainActor
func testWindow(frame: CGRect) async throws -> UIWindow {
    for _ in 0..<600 {
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            let window = UIWindow(windowScene: scene)
            window.frame = frame
            return window
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw NoScene()
}

private struct NoScene: Error {}

/// A text field that takes the keyboard without the on-screen keyboard coming up: the tests
/// look at which view has the keyboard, and the keyboard's own showing and hiding only
/// keeps the main thread, and every other suite on it, waiting.
@MainActor
func quietTextField(frame: CGRect) -> UITextField {
    let field = UITextField(frame: frame)
    quiet(field)
    return field
}

/// Keeps the on-screen keyboard down for a field already made, such as SwiftUI's.
@MainActor
func quiet(_ field: UITextField) {
    field.inputView = UIView()
    field.inputAssistantItem.leadingBarButtonGroups = []
    field.inputAssistantItem.trailingBarButtonGroups = []
}

/// The same for a text view.
@MainActor
func quietTextView(frame: CGRect) -> UITextView {
    let view = UITextView(frame: frame)
    view.inputView = UIView()
    view.inputAssistantItem.leadingBarButtonGroups = []
    view.inputAssistantItem.trailingBarButtonGroups = []
    return view
}
