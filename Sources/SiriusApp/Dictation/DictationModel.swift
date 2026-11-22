import Foundation
import ParrotCore
import SiriusCore

// The speech model dictation uses: whisper-small.en unless
// UserDefaults' `dictation.model` names another in ParrotCore's registry
// (Sirius keeps its own setting, beside `composer.last_agent`, not read from
// Parrot's settings.json). The registry's models are the picker in Settings
// → Dictation (ModelRegistry.shared); a choice made there is applied at
// once (DictationService.applyModel). The weights
// live in Parrot's folder (Paths.appSupport), so a Parrot user downloads
// nothing new for a model Parrot already has (dictation.md §2).
//
// whisper-small.en is the default since it holds about a third of
// whisper-base.en's errors on English at three times the download, and
// still transcribes a held sentence in a fraction of a second on Apple
// Silicon; whisper-large-v3-turbo, the registry's most accurate, is one
// picker click away for those who want it (docs/dictation.md lists the
// candidates considered, Parakeet among them).
@MainActor
final class DictationModel {
    static let defaultID = "whisper-small.en"
    static let defaultsKey = "dictation.model"

    let model: TranscriptionModel

    init(defaults: UserDefaults = .standard) {
        let saved = defaults.string(forKey: Self.defaultsKey)
        if let saved, let found = ModelRegistry.find(saved) {
            model = found
        } else {
            if let saved { SiriusLog.dictation.error("dictation: unknown model \"\(saved)\"; using \(Self.defaultID)") }
            // The registry lists the default; the recommended model stands in
            // only if a ParrotCore update drops it.
            model = ModelRegistry.find(Self.defaultID) ?? ModelRegistry.recommended() ?? ModelRegistry.shared[0]
        }
    }

    // Every model the picker can offer, in the registry's order.
    static var catalog: [TranscriptionModel] { ModelRegistry.shared }

    // Where WhisperKitTranscriber.warmUp puts the model:
    // WhisperKit.download(variant:downloadBase:) under Paths.appSupport,
    // from its default repo, argmaxinc/whisperkit-coreml.
    var folder: URL? {
        model.whisperKitID.map {
            Paths.appSupport.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\($0)", isDirectory: true)
        }
    }

    // The model's three CoreML parts are on disk. A download cut short can
    // leave the folder with some of them, so each is checked; warmUp fetches
    // only what is missing. The tokenizer, a small download beside it, is
    // left to warmUp.
    var isOnDisk: Bool {
        guard let folder else { return false }
        return ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"].allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    // A transcriber with the model loaded, downloading it first if it is not
    // on disk. `progress` gets the download's fraction done, 0 to 1, from
    // any thread, only while there is something to download.
    func transcriber(progress: @escaping @Sendable (Double) -> Void) async throws -> WhisperKitTranscriber {
        let transcriber = WhisperKitTranscriber(model: model)
        try await transcriber.warmUp(progress: progress)
        return transcriber
    }
}
