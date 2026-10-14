# Speech models for dictation

Last updated: `2026.10.11`. Research only; nothing here is adopted. Sirius dictates through ParrotCore on WhisperKit with `whisper-base.en`.

## 1. Measured here

Apple M4 Pro, 24 GB. Parrot's `parrot-bench transcription` on six 2–3 s clips made with macOS `say`, 43 words, each with a reference transcript. TTS speech is clean and not a real user's voice, so the WER column is a rough signal only; the latency column is solid.

| Model | Published WER: LibriSpeech clean / other / CommonVoice 5.1 | WER here, no prompt / names prompt | Per clip, no prompt / prompt | First load (compile, once) / later loads | Download |
|---|---|---|---|---|---|
| whisper-base.en (current) | 4.2 / 10.2 / 19.0 [1] | 9.3% / 4.7% | 50 / 115 ms | not measured (already compiled here) / about 2 s | 145 MB |
| whisper-small.en | 3.1 / 7.4 / 13.1 [1] | not measured (the download on disk is incomplete) | multilingual small: 172 / 344 ms | not measured / about 4 s | 488 MB; 217 MB compressed build [3] |
| whisper-large-v3-turbo | about large-v2: 2.7 / 5.2 / 9.0 [1][4] | 7.0% / 4.7% | 429 / 590 ms | about 110 s / about 4 s | 1.5 GB; 632 MB compressed build [3] |
| distil-large-v3 | 9.7 short-form, against 8.4 for large-v3 [2] | not in ParrotCore's registry | published 6.3x faster than large-v3 [2] | n/a | about 1.5 GB; 594 MB build |

The first-load compile is the CoreML/Neural Engine compile macOS runs once per model per Mac and caches; every later launch loads from the cache. Sirius loads the model in the background at launch, so the later-load column does not delay a press.

## 2. The prompt does nothing today

Sirius passes the agent names in `context.vocabulary` (and passed "dictate" until the Dictate paste mode was removed for now), which `WhisperKitTranscriber` ignores (`WhisperKitTranscriber.swift:74`). The only prompt Whisper sees is Parrot's generic example sentence, which names none of Sirius, Loom or Dictate. A natural sentence carrying them ("Dictate: I asked Sirius to send Claude and Codex the Loom link.") took base.en from 9.3% to 4.7% on these clips, level with turbo, for about 65 ms. An earlier measurement in Parrot found a natural sentence raised term recall from 46% to 85% on base.en, and a bare word list did nothing. No model size learns these names unprompted.

The dictionary is the wrong tool for these: a `serious → Sirius` or `room → Loom` rule rewrites every transcript, real uses of those words included.

## 3. One model or one per mode

The Dictate paste mode was removed for now: every transcript goes to an agent, the composer when it is open, so this question waits until a paste mode returns. As researched, "Dictate:" was a spoken prefix, so the mode was known only after transcription.

- One model for everything: simplest; at about 0.6 s per clip turbo is acceptable for pastes too.
- Choose at press time (composer open, or a focused text field): feasible through ParrotCore's `replaceTranscriber`, but both models stay loaded and the context signal is still open.
- Fast first, then re-transcribe agent messages with the big model: every agent message pays for both, about 50 + 590 ms, worse than turbo alone.

## 4. Other model families

Measured here on the same six clips and M4 Pro: Parakeet TDT 0.6B v2 from the CoreML files FluidAudio had already cached on this Mac (`~/Library/Application Support/FluidAudio/Models`), run through a throwaway greedy TDT decoder rather than FluidAudio itself; and Apple's SpeechTranscriber and DictationTranscriber, whose English assets were already installed. Nothing was downloaded. The current Open ASR Leaderboard uses a newer dataset mix than the model cards, so its averages are higher than the cards' figures for the same model; both are given where they differ.

| Model | WER: Open ASR avg / LS clean / LS other | WER here (43 words) | Download | RAM | Speed, M4 Pro | First load | Vocabulary biasing | License | Swift path | Fit to `Transcriber` |
|---|---|---|---|---|---|---|---|---|---|---|
| whisper-base.en (current, for reference) | 4.2 / 10.2 LS only [1] | 9.3%, 4.7% with names prompt (§1) | 145 MB | not measured | 50–115 ms per clip (§1) | cached | prompt only | MIT | WhisperKit | in place |
| whisper-large-v3-turbo (for reference) | 8.39 / 2.13 / 3.71 [5] | 7.0%, 4.7% with prompt (§1) | 1.5 GB; 632 MB [3] | not measured | 429–590 ms (§1) | about 110 s (§1) | prompt only | MIT | WhisperKit | in place |
| Parakeet TDT 0.6B v2 (English) | 6.43 / 1.28 / 2.73 [5]; card 6.05 / 1.69 / 3.19 [6] | 4.7%, no prompt (misses: omnograph, versal) | about 480 MB (446 MB encoder); 443 MB on disk here; 306 MB 4-bit encoder build [10] | 66 MB peak per FluidAudio [9], not checked | 41–52 ms per clip, measured; RTFx 146 published [17] | 15.8 s measured once, then 0.18 s | yes: CTC keyword boosting with a second 110M model, +104 MB [9][10]; RTFx drops from 156 to 63 [9] | CC-BY-4.0 model [6]; FluidAudio Apache-2.0 [8] | FluidAudio SPM, macOS 14+ [8][18] | medium |
| Parakeet TDT 0.6B v3 (25 languages) | 6.51 / 1.52 / 3.13 [5]; card 6.34 / 1.93 / 3.59 [7] | not measured | about 480 MB; 299 MB 4-bit encoder build [10] | as v2 | RTFx 156 published [17] | not measured | as v2 | CC-BY-4.0 [7] | FluidAudio (its default model) [8] | medium |
| Parakeet via Argmax Pro SDK | earnings22 11.7, against 15.2 base.en and 14.0 SpeechTranscriber [11] | not measured | not published | not published | speed factor 359 on M4 Mac mini [11] | not published | Argmax custom vocabulary [11] | paid: $0.42 per device per month, 1,000-device minimum [12] | Argmax Pro SDK | medium; the price rules it out for testers |
| Apple SpeechTranscriber (macOS 26) | not on the leaderboard; 2.12 / 4.56 LS in one independent test [13]; earnings22 14.0 [11] | 9.3% (misses: a, pool, omnograph, versal) | none (system asset; already installed here for 9 English locales) | system | 64–78 ms per clip, measured | none here | `contextualStrings` accepted but changed nothing here | system | Speech framework | easy, macOS 26 only |
| Apple DictationTranscriber, `.shortDictation` (macOS 26) | none published | 16.3%; 4.7% with the six names as `contextualStrings` (misses: Siri, pool) | none (system asset) | system | 74–159 ms; 102–141 ms with context, measured | none here | yes, and it worked: Sirius, Codex, Vercel fixed | system | Speech framework | easy: `context.vocabulary` maps straight to `contextualStrings`; macOS 26 only |
| SFSpeechRecognizer, on-device | 9.02 / 16.25 LS [13] | not measured | none | system | not measured | none | `contextualStrings`, custom language model | system | Speech framework | easy; accuracy worse than base.en |
| Moonshine Streaming small / medium | 7.84 / 2.49 / 6.78 and 6.65 / 2.08 / 5.00 [14] | not measured | 561 MB / 1,064 MB fp32 [14]; quantized variants exist | not checked | none published for Mac | none (ONNX on CPU) | none documented | MIT [14] | Swift binding ships an iOS-only xcframework; macOS needs a self-built dylib [15] | hard |
| distil-small.en / distil-medium.en | short-form 12.1 / 11.1 on the old leaderboard [16] | not measured | no WhisperKit build [3] | n/a | 5.6x / 6.8x large-v3 [16] | n/a | prompt | MIT [16] | own CoreML conversion | hard; worse than Parakeet at a similar size |
| distil-large-v3.5 | 7.02 / 1.94 / 4.52 [5] | not measured | no WhisperKit build; only distil-large-v3, 594 MB [3] | n/a | n/a | n/a | prompt | MIT [5] | own CoreML conversion | hard |
| whisper-small.en compressed | 3.1 / 7.4 LS [1] | not measured | 217 MB [3] | not measured | multilingual small 172–344 ms (§1) | not measured | prompt | MIT | WhisperKit | in place |

Excluded: whisper-medium.en has no compressed build in Argmax's repo [3] and costs more than turbo for less accuracy. IBM Granite Speech 5.0 470M turbo-CTC scores 6.84 / 1.48 / 2.71 under Apache-2.0 [5], but no CoreML port was found. Kyutai STT has no CoreML path and starts at 1B parameters; it was not checked further.

The Apple results disagree with Argmax's 2025 claim that SpeechAnalyzer lacks custom vocabulary [11]: SpeechTranscriber ignored `contextualStrings` here, DictationTranscriber used them. Both Apple engines ran from an unsigned command-line tool without a permission prompt; an app may still need the speech-recognition usage string.

Recommendation: Parakeet TDT 0.6B v2 through FluidAudio is the middle ground. It beats turbo on the leaderboard (6.43 against 8.39 [5]) at about a third of turbo's download and a tenth of its latency: it matched base.en with the names prompt and turbo with the prompt (4.7%) without any prompt, at about 45 ms per clip. Its first load took 15.8 s here, against about 110 s for turbo. It has no Whisper prompt; the names go through FluidAudio's CTC boosting, which takes a word list and so maps onto `context.vocabulary`, for another 104 MB. Choose v3 instead only if non-English dictation matters; it is 0.1 point worse on English [5].

Integration cost is about two days. ParrotCore needs a FluidAudio dependency, a new `Engine` case and registry entry, and a `ParakeetTranscriber` actor that calls FluidAudio's batch `transcribe` on the `[Float]` buffer and passes `context.vocabulary` as a `CustomVocabularyContext`. Sirius types its loader to `WhisperKitTranscriber` (`DictationService.swift:82`, `DictationModel.swift:52`), so its download, warm-up and progress path must be generalized. CC-BY-4.0 requires an attribution line.

Apple's DictationTranscriber is the zero-download alternative and costs about half a day, but it needs macOS 26, has no published accuracy figure, and heard "Siri" for "Sirius" even with context.

To verify on real recordings: WER and name recall for base.en with prompt, turbo with prompt, Parakeet v2 with and without CTC boosting, and DictationTranscriber with context; Parakeet's lowercase sentence starts ("dictate the reply"); utterances over 15 s, since the encoder takes a fixed 15 s window and FluidAudio must chunk; the 4-bit encoder's accuracy, which would bring the download to about 340 MB; and the first-load time on a Mac that has never compiled the model.

## Sources

1. Whisper paper, Table 8 (greedy): https://arxiv.org/abs/2212.04356
2. https://huggingface.co/distil-whisper/distil-large-v3
3. https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main
4. Turbo near large-v2 per OpenAI's release notes, https://github.com/openai/whisper/discussions/2363 (not re-checked).
5. Open ASR Leaderboard, English short-form results, `english_short_latest.csv` at revision d3c0e9a: https://huggingface.co/spaces/hf-audio/open_asr_leaderboard and https://huggingface.co/datasets/hf-audio/open-asr-leaderboard-results
6. https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2
7. https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
8. https://github.com/FluidInference/FluidAudio
9. FluidAudio custom vocabulary: https://docs.fluidinference.com/asr/custom-vocabulary
10. File sizes from the Hugging Face API for https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml, https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml and https://huggingface.co/FluidInference/parakeet-ctc-110m-coreml
11. Argmax, "Apple and Argmax" (earnings22 10% subset, M4 Mac mini, macOS 26 beta 1): https://www.argmaxinc.com/blog/apple-and-argmax
12. https://www.argmaxinc.com/pricing
13. Inscribe benchmark (LibriSpeech, M2 Pro), as reported by GIGAZINE: https://www.gigazine.net/gsc_news/en/20260714-apple-speech-analyzer-benchmark/ ; original: https://lyonesse.app/blog/apple-speech-api-benchmark.html (not read directly).
14. https://huggingface.co/moonshine-ai/moonshine-streaming-medium and https://huggingface.co/moonshine-ai/moonshine-streaming-small
15. https://github.com/moonshine-ai/moonshine/tree/main/language-bindings/swift
16. https://huggingface.co/distil-whisper/distil-medium.en
17. FluidAudio ASR getting started (benchmarks): https://docs.fluidinference.com/asr/getting-started
18. https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml
