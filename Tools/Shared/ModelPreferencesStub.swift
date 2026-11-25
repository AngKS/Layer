import Foundation

// The part of `ModelPreferences` (Layer/Providers/ModelChoice.swift) that `HostedProvider`
// needs: where LM Studio's server is. The screen harness reaches it on this Mac, at its
// default address; the app reads the address from Settings.
extension ModelPreferences {
    static func serverURL(for provider: HostedProvider) -> URL {
        URL(string: "http://localhost:1234/v1")!
    }
}
