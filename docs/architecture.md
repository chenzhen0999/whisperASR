# WhisperASR Architecture

Native macOS SwiftUI app (macOS 14+, arm64) that transcribes audio using whisper.cpp with Metal GPU acceleration. Built with Swift Package Manager.

### Data flow

`SidebarView` (drag-drop/file picker) → `AppState.addFile()` → `TranscriptionService.transcribe()` → whisper.cpp C API → results stored in `TranscriptionItem` → persisted by `TranscriptionStore`

### Key layers

- **C interop / engine routing** (`TranscriptionService`): Bridges Swift to whisper.cpp C API. Manages model lifecycle (`whisper_init`/`whisper_free`), runs `whisper_full()` on a background dispatch queue, uses `withCheckedThrowingContinuation` to bridge C callbacks to async/await. Progress is reported via a `ProgressBox` wrapper that passes Swift closures through C function pointers. Also routes by engine: when the selected model resolves to a *directory* (a Nemotron Core ML bundle) instead of a `.bin` file, transcription is delegated to `NemotronEngine` and the whisper context is freed (the two engines never stay loaded together).

- **Nemotron engine** (`NemotronEngine`): Actor wrapping FluidAudio's `StreamingNemotronMultilingualAsrManager` (Core ML on the Apple Neural Engine, [FluidAudio](https://github.com/FluidInference/FluidAudio) is an SPM dependency). Feeds 16 kHz mono PCM in 5 s slices for progress, then converts per-token RNNT timings into `TranscriptionSegment`s (splitting on sentence-final punctuation, >1.5 s gaps, or a 30 s cap). Language hints are locale codes ("zh-TW", "ja", nil = auto-detect); the detected locale is reported as an ISO-639-1 base code. Translation to English is whisper-only and returns an error on this engine. First-ever load triggers ANE compilation (minutes); afterwards the OS caches it and loads take ~1 s.

- **Diarization** (`DiarizationProvider` / `DiarizationService`): Optional "who spoke when" pass run from the transcript view *after* transcription — never part of it. `diarizationUseRemote` selects `OpenAIDiarizationProvider`; otherwise `diarizationUseOfflineVBx` selects `OfflineDiarizationProvider`, with `LocalDiarizationProvider` remaining the default. The better-model checkbox in Settings downloads and loads the offline VBx bundles immediately through the shared `OfflineDiarizationModels` store. Concurrent callers share one preparation task; failure unchecks the option and displays a retryable error. VBx models live under `WhisperASR/Models/Diarization-VBx/`, separate from the standard FluidAudio cache, and remain downloaded when disabled. The offline provider processes the complete file with `OfflineDiarizerManager` and matches known voices using references extracted with the same pipeline, without reusing or overwriting legacy cached embeddings. Providers return `SpeakerTurn`s; `assignSpeakers(to:turns:)` labels each `TranscriptionSegment` with the turn it overlaps the most.

- **Voice library** (`SpeakerLibrary`, `VoiceSampleExtractor`, `SpeakerEmbeddingMatcher`): `@MainActor` JSON store in `~/Library/Application Support/WhisperASR/Speakers/` holding `SpeakerProfile`s and short WAV samples per speaker. Naming speakers in `SpeakerAssignmentView` creates the profiles and leaves behind a ~3 s clip of each voice; the next diarization enrolls those clips (`extractSpeakerEmbedding` → `initializeKnownSpeakers`) so recognized speakers come back named rather than numbered. Clusters the diarizer leaves unnamed get a second pass through `SpeakerEmbeddingMatcher` (cosine similarity over the 256-dim embeddings). Extraction is the expensive step, so embeddings are cached back onto the `VoiceSample`.

- **State** (`AppState`): Single `@Observable` object injected via SwiftUI environment. Owns the `TranscriptionService` and the item collection. Orchestrates transcription lifecycle (add → transcribe → save, or retry/remove).

- **Persistence** (`TranscriptionStore`): JSON file-per-item storage in `~/Library/Application Support/WhisperASR/Transcriptions/`. Saves on completion/failure/removal. Items mid-transcription at quit restore as "pending".

- **Audio** (`AudioLoader`): Converts any audio/video to 16 kHz mono Float32 PCM via `AVAssetReader`, falling back to `ffmpeg` (if found in `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, or `PATH`) for containers macOS can't decode natively — notably WebM/Opus from browser `MediaRecorder`, which the OpenAI API server commonly receives. `AudioPlayerManager` wraps `AVPlayer` for playback with periodic time observation for synced transcript highlighting.

- **API server** (`APIServer`): Optional OpenAI-compatible HTTP server (built on [FlyingFox](https://github.com/swhitty/FlyingFox), an SPM dependency). `APIServer.shared` is a `@MainActor @Observable` singleton that `AppState` injects its `TranscriptionService` into (via `attach`) so the model loads once and all requests serialize on the existing whisper queue. Serves `POST /v1/audio/transcriptions`, `POST /v1/audio/translations`, and `GET /v1/models`; supports `json`/`verbose_json`/`text`/`srt`/`vtt` response formats. Config (enable, port, optional bearer token, LAN binding) lives in UserDefaults / `SettingsView`; the token is read per-request so it takes effect without a restart, while port/LAN changes require toggling off and on. Multipart parsing is hand-rolled in `MultipartParser`.

### UI structure

`ContentView` is a `NavigationSplitView` with `SidebarView` (file list) + `DetailView` (status-dependent: progress/transcript/error) + `PlayerView` (audio controls, shown when a completed item is selected). `TranscriptContentView` syncs segment highlighting with audio playback position via `ScrollViewReader`, and heads the transcript with `SpeakerSummaryView` (who spoke how much, plus the Diarize / Identify… actions that open `PreDiarizationView` and `SpeakerAssignmentView`).

### Model resolution

`ModelCatalog` defines the downloadable models (Breeze-ASR-25, Nemotron 3.5 Multilingual, plus official whisper.cpp tiny/base/small/medium/large-v3-turbo); `ModelManager` (shared `@Observable`) tracks downloaded files in `~/Library/Application Support/WhisperASR/Models/`, per-model `ModelDownloader` instances, and the active selection (UserDefaults `"selectedModelFile"`, settable from `SettingsView` or the toolbar `ModelPickerMenu`).

A catalog entry's `engine` is `.whisper` (single `.bin` file, `DownloadSource.file`) or `.nemotron` (a directory bundle of Core ML models + `metadata.json`/`tokenizer.json`, `DownloadSource.hfFolder`). Folder models download by listing the Hugging Face repo subtree at download time, staging files sequentially under `Models/.partial-<name>/` (skipping already-complete files on resume), then moving the directory into place atomically. `ModelCatalog.isComplete(_:)` guards against half-downloaded bundles counting as installed.

`TranscriptionService.resolveModelPath()` checks `"selectedModelFile"` first, then the custom `"modelPath"` (set via `SettingsView`), then the App Support default `ggml-model.bin`, then falls back to `{projectRoot}/Models/ggml-model.bin` using `#filePath` to locate the project root. The model is lazily (re)loaded whenever the resolved path changes, so switching models takes effect on the next transcription.
