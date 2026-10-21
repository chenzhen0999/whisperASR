# WhisperASR — Live Caption Edition

[简体中文说明](README_zh.md) · [繁體中文（原專案）](README.zh-TW.md)

> A fork of [plateaukao/whisperASR](https://github.com/plateaukao/whisperASR), tuned for **watching livestreams and videos that have no subtitles**: fast on-device speech recognition plus free cloud translation, shown as large, readable captions that float over your video.
>
> All credit for the original app goes to [@plateaukao](https://github.com/plateaukao). This fork is distributed under the same [Apache License 2.0](LICENSE). The changes made in this fork are listed below.

## What this fork changes

### Live caption window
- **Outlined captions** — white text with a thick black outline (like movie subtitles), readable on any background. The translation line is light cyan so you can tell it apart from the original at a glance.
- **Stepped font size** — a font-size button in the bottom bar cycles through 18 → 22 → 28 → 34 → 40 pt.
- **Transparent background** — a transparency button cycles the window background through 35% → 15% → 0% (fully transparent) → 55%, so you can lay the captions directly over the video.

### History / transcript page
- **Independent font size** — its own font-size button in the toolbar (18 → 22 → 28 → 34 → 40), separate from the live caption size.
- **Select & copy text** — drag to select any part of the original text or the translation, then press Cmd+C.
- **Click the timestamp to seek** — seeking moved from the whole row to the timestamp, so selecting text no longer jumps the audio.

### Settings
- Two separate font pickers under **Appearance**: *Live Caption Font* and *History Transcript Font*.

### Translation quality & speed
- Whisper's short fragments are **merged into whole sentences** before display and translation, so translations read naturally instead of word-by-word.
- Translation requests are **capped at 6 lines per batch** with automatic follow-up passes, so a backlog never turns into one huge, slow request.
- If the model returns the wrong number of lines, the app **falls back to translating each line on its own**, so translations never get misaligned or left blank.
- A clearer translation prompt (natural, complete sentences) and a longer 60 s timeout.

### Build
- `swift-tools-version` lowered to 6.1 so it builds with the Swift that ships with current Xcode / Command Line Tools.

## Recommended setup: fast and free

| Part | What to use | Cost |
|---|---|---|
| Speech recognition | **NVIDIA Nemotron 3.5 Multilingual** (streaming, runs locally on the Apple Neural Engine) | Free, offline |
| Translation | **Zhipu GLM `glm-4.7-flash`** (OpenAI-compatible API) | Free |

Nemotron is a streaming model, so captions appear with low delay. Larger Whisper models are more accurate on recordings but are noticeably slower for live use.

## Installation

### Quick start: download the app (no build needed)
1. Download `WhisperASR-LiveCaption.zip` from the [latest release](https://github.com/chenzhen0999/whisperASR/releases/latest) and unzip it.
2. Drag `WhisperASR.app` into **Applications**.
3. The app is not notarized by Apple, so run this once in Terminal before opening it:
   ```bash
   xattr -cr /Applications/WhisperASR.app
   ```
4. Open the app, then follow steps 3–5 below (speech model, translation, live captions).

### Build from source

### 1. Requirements
- Apple Silicon Mac (M1 or newer), macOS 14 or later
- Xcode or the Command Line Tools (`xcode-select --install`), Swift 6.1+
- Git

### 2. Build and install

```bash
git clone https://github.com/chenzhen0999/whisperASR.git
cd whisperASR
bash Scripts/build_release.sh
cp -R WhisperASR.app /Applications/
xattr -cr /Applications/WhisperASR.app
open /Applications/WhisperASR.app
```

The first build takes a few minutes. `xattr -cr` removes the "cannot be opened" block for unsigned apps.

### 3. Download the speech model
Open **Settings** (Cmd+,) → **Speech Recognition Models**, download **Nemotron 3.5 Multilingual**, and select it.

### 4. Set up free translation (Zhipu)
1. Sign up at [Zhipu BigModel](https://open.bigmodel.cn/) and create an API key in the console.
2. In **Settings → OpenAI Translation API**, fill in:
   - **API Endpoint:** `https://open.bigmodel.cn/api/paas/v4`
   - **Model:** `glm-4.7-flash`
   - **API Key:** your Zhipu key
3. Set **Target Language** to the language you want captions in.

If `glm-4.7-flash` reports it is busy (error 1305), switch the model to `glm-4-flash-250414`, which is also free.

### 5. Start live captions
1. Click the record button and choose the app that is playing audio (for example your browser).
2. Turn on live transcription and start recording.
3. macOS will ask for **Screen Recording** permission the first time: allow it in System Settings → Privacy & Security, then restart the app.
4. Use the bottom-bar buttons to change the font size and the background transparency.

### Updating
```bash
cd whisperASR && git pull
bash Scripts/build_release.sh
cp -R WhisperASR.app /Applications/
tccutil reset ScreenCapture com.whisperasr.app
```
Each rebuild changes the app's signature, so reset and grant Screen Recording again after updating.

## Support the author

If this saves you time, feel free to get in touch or buy me a coffee.

| WhatsApp | Alipay — tip the author |
|---|---|
| <img src="docs/donate/whatsapp.jpg" width="220"> | <img src="docs/donate/alipay.jpg" width="220"> |

---

## Original README

# WhisperASR (original project)

[繁體中文](README.zh-TW.md)

A native macOS app for audio transcription using [Breeze-ASR-25](https://github.com/mtkresearch/Breeze-ASR-25) (Whisper large-v2 fine-tuned for Taiwanese Mandarin and code-switching) via [whisper.cpp](https://github.com/ggml-org/whisper.cpp) with Metal GPU acceleration.

![Live transcription with bilingual output](docs/screenshots/live_recording.png)

## Screenshots

| Transcription Progress | Bilingual Transcript |
|---|---|
| ![Progress](docs/screenshots/progress.png) | ![Transcript](docs/screenshots/transcript.png) |

| App Picker | Settings |
|---|---|
| ![App picker](docs/screenshots/recording.png) | ![Settings](docs/screenshots/settings.png) |

## Features

### Live transcription + translation

- **App audio recording** — capture audio from any running app via ScreenCaptureKit (M4A/AAC at 48 kHz)
- **Live transcription** — see transcribed text in real-time while recording
- **Live translation** — per-segment translation displayed inline below each transcribed line, via OpenAI-compatible API
- **Smart auto-scroll** — live transcription view automatically follows new segments
- **Live results reuse** — when recording stops, live transcription results are kept (no re-transcription)
- **Zoom meeting detection** — automatically prompts to stop recording when a Zoom meeting ends

### File transcription

- **Drag-and-drop** audio/video files (MP3, WAV, M4A, MP4, AAC, FLAC, OGG, WMA, AIFF, CAF)
- **Batch processing** — queue multiple files at once
- **Sequential transcription queue** — files wait in queue and transcribe one at a time

### Bilingual output

- **Post-transcription translation** — translate completed transcriptions into any configured language with a single click
- **Configurable languages** — auto-detect or set source language; choose target language for translation
- **Search** — global sidebar filter across all transcriptions, plus in-file find (Cmd+F) with match highlighting and navigation

### Playback

- **Audio playback** with play/pause, seek bar, and skip ±5s controls
- **Synced text highlighting** — the current sentence highlights as audio plays
- **Click-to-seek** — click any segment to jump to that point in the audio

### Models

- **Downloadable model catalog** — download models in-app: Breeze-ASR-25 (best for Mandarin/Taiwanese-accented speech), NVIDIA Nemotron 3.5 Multilingual (~40 languages with native punctuation, runs on the Apple Neural Engine via Core ML), plus official whisper.cpp models from Tiny (78 MB) to Large v3 Turbo (1.6 GB)
- **Switch anytime** — pick the active model from the toolbar or Settings; takes effect on the next transcription
- **Custom model path** — point to any `ggml-*.bin` outside the catalog via Settings

### Local API server (OpenAI-compatible)

- **Drop-in OpenAI transcription API** — enable a local HTTP server in Settings and point any OpenAI-compatible client at `http://127.0.0.1:8080/v1`; transcription runs on-device with your selected model
- **Endpoints** — `POST /v1/audio/transcriptions`, `POST /v1/audio/translations` (translate audio to English), and `GET /v1/models`
- **Response formats** — `json`, `verbose_json` (with timestamped segments), `text`, `srt`, and `vtt`
- **Optional API key** — require a `Bearer` token, and optionally allow access from other devices on your network

### Privacy & performance

- **Metal GPU acceleration** via whisper.cpp — fully on-device, no audio ever leaves your Mac
- **Bring your own API** — translation uses any OpenAI-compatible endpoint, including local models
- **Re-transcribe** and **retry on failure** with copyable error messages

## Requirements

- macOS 14.0+
- Apple Silicon Mac (arm64) — the included xcframework is built for arm64
- Swift 6.2+ toolchain for building (enables dependency feature selection)
- Python 3 with `torch`, `transformers`, `numpy`, `huggingface_hub` (only if converting the model yourself; not needed if downloading the pre-converted GGML file)

## Setup

### 1. Build whisper.cpp (if not already included)

The repo includes a pre-built `CWhisper.xcframework`. To rebuild it from source:

```bash
bash Scripts/build_whisper_lib.sh
```

This clones whisper.cpp, builds it with Metal + Accelerate, and packages the static libraries into an xcframework.

### 2. Get a speech recognition model

**Option A (recommended):** Just launch the app — it offers to download a model on first run (Breeze-ASR-25 or a smaller Whisper model), and you can add, select, or delete models later in **Settings → Speech Recognition Models**.

**Option B:** Download the pre-converted Breeze-ASR-25 GGML file directly from HuggingFace (~3 GB) and place it at `Models/ggml-model.bin`:

```
https://huggingface.co/danielkao0421/Breeze-ASR-25-ggml/blob/main/ggml-model.bin
```

**Option C:** Convert from the original model (requires Python 3 + `torch`, `transformers`, `numpy`, `huggingface_hub`):

```bash
bash Scripts/convert_model.sh
```

This downloads the Breeze-ASR-25 model from HuggingFace, clones the necessary repos, and converts it to GGML format at `Models/ggml-model.bin`.

### 3. Build and run

```bash
swift build
swift run
```

SpeakerKit is the only linked Argmax product. FluidAudio's optional Rust text-normalization engine is disabled to avoid shipping unused tables and code.

Or open in Xcode:

```bash
open Package.swift
```

Then build and run from Xcode (Cmd+R).

### 4. Build release app bundle (optional)

```bash
bash Scripts/build_release.sh
```

This builds an optimized release binary, generates a proper `.icns` icon, and packages everything into `WhisperASR.app` with Info.plist. To install:

```bash
cp -r WhisperASR.app /Applications/
```

If macOS blocks the app with a "cannot be opened" warning (because it is not signed), run the following command with the path to wherever `WhisperASR.app` is located:

```bash
xattr -cr /path/to/WhisperASR.app
```

## Usage

1. **Add files** — drag audio/video files onto the sidebar, or click the **+** button
2. **Record app audio** — click the record button, select a running app, and start recording; recently used apps are listed first
3. **Live transcription & translation** — enable live transcription in the recording dialog to see text as you record; set a target language in Settings to see inline translations below each segment
4. **Wait for transcription** — files are queued and transcribed one at a time with progress and ETA
5. **Review** — click a completed item to see the transcript with timestamps
6. **Translate** — click the translate button to translate a completed transcription into any configured language
7. **Search** — use the sidebar search bar to filter across all files, or press Cmd+F to find within a transcript
8. **Play audio** — use the player controls at the bottom; text highlights in sync
9. **Export** — click the export button (top-right) to save as SRT or plain text

### Settings

Open **Settings** (Cmd+,) to configure:

- **Speakers → Local speaker model** — choose SpeakerKit / Pyannote (Argmax's open-source community-1 pipeline), Nemotron 3 (up to eight speakers), full-recording Offline VBx (automatic speaker count), or legacy Pyannote / WeSpeaker. Nemotron downloads about 190 MB on first use; selecting VBx prepares its models immediately. All four run locally and keep their models cached. SpeakerKit downloads its models on first use and matches known voices using its own acoustic embeddings; no Argmax account or API key is required. Speaker turns split transcripts at word boundaries; re-transcribe older recordings to obtain word timings. Re-running diarization uses the original ASR segments. If splitting changes an existing translation's segments, translate again to regenerate it.
- **Target Language** — choose a language to translate transcriptions into
- **OpenAI Translation API** — only the API key is required; endpoint defaults to OpenAI, model defaults to `gpt-5.4`. Any OpenAI-compatible endpoint (including local models) works. Translation and meeting minutes use the selected model's default sampling settings, including reasoning models that reject explicit temperature values.
- **Speech Recognition Models** — download, select, or delete models; the selected model is used for all transcription
- **Custom Model** — optional path to your own `ggml-*.bin` file, used when no downloaded model is selected

### Diarization checks

Run `swift test` to verify word alignment, text preservation, voice matching, compatibility, and engine selection. To also download/load the offline models and verify local inference and known-voice matching, provide a speech file:

```bash
VBX_TEST_AUDIO=/path/to/single-speaker-speech.wav swift test --filter DiarizationTests
```

The integration check creates a temporary reference clip and leaves the downloaded models cached in `~/Library/Application Support/WhisperASR/Models/Diarization-VBx/`.

To compare all four local engines with the same ASR output:

```bash
DIARIZATION_TEST_AUDIO=/path/to/recording.mp3 \
DIARIZATION_TEST_MODEL="$HOME/Library/Application Support/WhisperASR/Models/ggml-large-v3-turbo.bin" \
swift test --filter DiarizationComparisonTests
```

To check SpeakerKit inference and reference-voice recognition directly, run `SPEAKERKIT_TEST_AUDIO=/path/to/clean-single-speaker.wav swift test --filter SpeakerKitDiarizationTests`.

To reuse a previously exported ASR result, set `DIARIZATION_TEST_ASR=/private/path/asr.json` instead of `DIARIZATION_TEST_MODEL`. It must come from the same audio file. Set `DIARIZATION_TEST_ENGINES=speakerkit` to run only the new engine (or a comma-separated list of `legacy,vbx,nemotron,speakerkit`).

The report defaults to `/private/tmp/whisperasr-diarization-comparison.json`. Projection errors measure lost speaker information when attaching each engine's turns to transcript text; they are not accuracy scores against human annotations. Optional `DIARIZATION_TEST_REFERENCE` accepts JSON turns with `start`, `end`, and `speaker` for reference DER (250 ms collar). Set `DIARIZATION_TEST_OUTPUT_DIRECTORY` to export private before/after SRT and timed JSON files for listening review. See [validation results](docs/diarization-validation.md).


## Project Structure

```
Sources/
├── WhisperASRApp.swift        # App entry point
├── ContentView.swift          # NavigationSplitView layout
├── SidebarView.swift          # File list with drag-and-drop & context menu
├── DetailView.swift           # Transcript display, progress, export
├── PlayerView.swift           # Audio playback controls
├── RecordingView.swift        # App audio recording UI
├── AudioRecorder.swift        # ScreenCaptureKit audio capture
├── AppState.swift             # App state management & transcription queue
├── Models.swift               # Data models
├── TranscriptionService.swift # whisper.cpp C API integration
├── TranslationService.swift   # OpenAI-compatible translation API
├── TranscriptionStore.swift   # JSON file-per-item persistence
├── AudioLoader.swift          # AVAssetReader audio loading
├── AudioPlayerManager.swift   # AVPlayer wrapper
├── AppIconGenerator.swift     # Programmatic app icon rendering
└── SettingsView.swift         # Language, translation & model settings
Scripts/
├── build_whisper_lib.sh       # Build whisper.cpp xcframework
├── convert_model.sh           # Convert HuggingFace model to GGML
└── build_release.sh           # Build release .app bundle with icon
Frameworks/
└── CWhisper.xcframework/      # Pre-built whisper.cpp static library
```

## License

This project uses [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (MIT) and the [Breeze-ASR-25](https://github.com/mtkresearch/Breeze-ASR-25) model by MediaTek Research.
