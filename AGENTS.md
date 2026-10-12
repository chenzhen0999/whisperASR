# Repository Guidelines

## Project Structure & Module Organization

WhisperASR is a Swift Package Manager app for Apple Silicon Macs running macOS 14+. `Sources/` contains SwiftUI views, models, and services. `WhisperASRApp.swift` is the entry point; `AppState.swift` coordinates the transcription queue; `TranscriptionService.swift` routes Whisper and Nemotron engines; `TranscriptionStore.swift` persists results. Keep audio processing and networking in services rather than views.

`Frameworks/CWhisper.xcframework/` supplies the native Whisper library. `Scripts/` holds library builds, model conversion, and release packaging. `Assets/` and `docs/screenshots/` contain images; `docs/index.html` is the website. Read [architecture notes](docs/architecture.md) before changing engine routing, diarization, persistence, or the local API.

## Build, Test, and Development Commands

- `swift build`: compile the debug executable.
- `swift run`: build and launch locally.
- `open Package.swift`: open the package in Xcode; use Cmd+R to run.
- `bash Scripts/build_release.sh`: build an optimized `WhisperASR.app` bundle.
- `bash Scripts/build_whisper_lib.sh`: rebuild the included Whisper framework with Metal and Accelerate.
- `bash Scripts/convert_model.sh`: convert Breeze-ASR-25 into `Models/ggml-model.bin`; requires Python and the dependencies listed in `README.md`.

After code changes, run `swift run &` for immediate user verification. Model downloads are available in the app.

## Coding Style & Naming Conventions

Follow existing Swift style: four-space indentation, `UpperCamelCase` types, and `lowerCamelCase` methods and properties. Name files after their principal type, using established suffixes such as `View`, `Service`, and `Provider`. Use `// MARK:` for substantial sections. Preserve actor isolation and move expensive audio work off the UI thread. No formatter or linter is configured.

## Testing Guidelines

There are no automated test targets or coverage requirements. Build and manually exercise affected workflows: file import, recording, model switching, playback, exports, and persistence after relaunch. Include reproduction steps and results in pull requests. If introducing tests, add an SPM test target under `Tests/WhisperASRTests/`, use descriptive `test...` names, and run `swift test`.

## Commit & Pull Request Guidelines

Use Conventional Commits, e.g.: `feat: add speaker diarization`, `fix: restore pending items`, or `refactor: extract audio loading`. Mark breaking changes with `!`. Use only the configured assistant attribution trailer; omit session URLs. Describe the problem, resulting behavior, validation, and linked issues; include screenshots for UI changes. `cap` means commit and push, then follow the user's ADR publishing workflow for non-release commits.

## Security & Configuration

Keep API keys, bearer tokens, recordings, and transcripts out of Git. Runtime models and JSON stores live in `~/Library/Application Support/WhisperASR/`. Remote translation and diarization can send content to configured services; preserve explicit user choices.
