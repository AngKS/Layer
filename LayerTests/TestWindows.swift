import Testing
import UIKit

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
