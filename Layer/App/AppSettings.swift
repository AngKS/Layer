import Foundation

/// Where the app keeps its own settings: Finger Draws, converting after a pause, the model
/// new designs start with, the name new designs are given, the library's recents and the
/// record of Spotlight's index.
///
/// The app's defaults, except in a process running the unit tests. They run inside the
/// app, so what they set was the app's: a test that touched the Pencil turned Finger Draws
/// off, and UI tests run afterwards in the same simulator drew nothing. They get defaults
/// of their own instead, emptied as the tests start, so that running them never changes
/// the app's settings and each run starts from the same place.
enum AppSettings {
    /// `UserDefaults` is safe to use from any thread, as `.standard` is.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        guard isRunningUnitTests, let defaults = UserDefaults(suiteName: unitTestSuite) else { return .standard }
        defaults.removePersistentDomain(forName: unitTestSuite)
        return defaults
    }()

    /// The defaults the unit tests use in place of the app's.
    static let unitTestSuite = "kahshin.Layer.unit-tests"

    /// Whether this process is running unit tests: XCTest names the test bundle it puts into
    /// the app. A UI test's app is launched without it, and keeps the app's own settings.
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestBundlePath"]?.hasSuffix(".xctest") == true
    }
}
