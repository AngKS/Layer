import Foundation
import Testing
@testable import Layer

/// Runs `body` with settings of its own, for a test that changes one, such as a design's
/// Finger Draws: emptied as it starts and when it is done, so that nothing it sets reaches
/// another test, or stays behind. Named after the test, so that each has one set: one named
/// afresh each time left a file in the app's container every run. The tests' shared
/// settings are never the app's: see `AppSettings`.
@MainActor
func withOwnSettings<T>(test: String = #function, file: String = #fileID, _ body: (UserDefaults) throws -> T) rethrows -> T {
    let suite = "LayerTests.\(file).\(test)".replacingOccurrences(of: "/", with: ".")
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    return try body(defaults)
}

/// The unit tests run inside the app, so what they set was the app's: a test that touched
/// the Pencil turned Finger Draws off, and UI tests run afterwards drew nothing.
@Suite("The app's own settings")
@MainActor
struct AppSettingsTests {
    /// What a design remembers between launches, and what else the app keeps there.
    private static let keys = [
        "fingerDraws", "fingerDrawsChosen", "convertsAutomatically", "untitledFileName",
        "defaultModelChoice", "assetLibrary.recents", "spotlightIndexedScreens", "pencilVoice.squeezeToTalk",
    ]

    @Test func theTestsKeepSettingsApartFromTheApps() {
        #expect(AppSettings.isRunningUnitTests)
        #expect(AppSettings.defaults !== UserDefaults.standard)
        #expect(AppModel(document: LayerDocument()).settings === AppSettings.defaults)
        #expect(!(DesignIndexer.spotlight is SystemSpotlight))
        #expect(APIKeyStore.service != "kahshin.Layer.model-provider")
    }

    @Test func aDesignsSettingsAreKeptWhereItIsTold() throws {
        let before = Self.keys.map { UserDefaults.standard.object(forKey: $0) as? NSObject }
        try withOwnSettings { settings in
            let model = AppModel(document: LayerDocument(), settings: settings)
            #expect(model.fingerDraws && model.convertsAutomatically)
            model.pencilTouched(at: .zero)
            #expect(!model.fingerDraws)
            #expect(settings.object(forKey: "fingerDraws") as? Bool == false)
            model.convertsAutomatically = false
            model.addAsset(try #require(AssetLibrary.all.first))
            #expect(settings.string(forKey: AssetLibrary.recentsKey)?.isEmpty == false)

            // Remembered for the next design opened with them.
            let next = AppModel(document: LayerDocument(), settings: settings)
            #expect(!next.fingerDraws && !next.convertsAutomatically)
        }
        #expect(Self.keys.map { UserDefaults.standard.object(forKey: $0) as? NSObject } == before)
    }
}
