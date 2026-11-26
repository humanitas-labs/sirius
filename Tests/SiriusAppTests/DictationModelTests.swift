import XCTest
import ParrotCore
@testable import SiriusApp

// The speech model dictation starts with, the saved choice that wins over
// it, and the Settings picker's write-through.
@MainActor
final class DictationModelTests: XCTestCase {
    private func scratchDefaults() -> UserDefaults {
        let suite = "dictation-model-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testDictationStartsAtWhisperSmall() {
        let model = DictationModel(defaults: scratchDefaults())
        XCTAssertEqual(DictationModel.defaultID, "whisper-small.en")
        XCTAssertEqual(model.model.id, "whisper-small.en")
        XCTAssertNotNil(ModelRegistry.find(DictationModel.defaultID), "the default is in the registry")
        XCTAssertTrue(DictationModel.catalog.contains { $0.id == DictationModel.defaultID })
    }

    func testASavedModelWinsAndAnUnknownOneFallsBackToTheDefault() {
        let defaults = scratchDefaults()
        defaults.set("whisper-large-v3-turbo", forKey: DictationModel.defaultsKey)
        XCTAssertEqual(DictationModel(defaults: defaults).model.id, "whisper-large-v3-turbo")
        defaults.set("parakeet-tdt-ultra", forKey: DictationModel.defaultsKey)
        XCTAssertEqual(DictationModel(defaults: defaults).model.id, DictationModel.defaultID,
                       "a model the registry does not know is not guessed at")
    }
}
