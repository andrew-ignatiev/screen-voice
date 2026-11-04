# ScreenVoice

**English** · [Русский](README.ru.md)

ScreenVoice is a native macOS app that reads subtitles (or any text) from a window or screen region, translates new lines into Russian, and speaks them aloud. Everything happens on your Mac: Apple Vision reads the text, Apple Translation translates it, and either a system voice or the **Qwen3-TTS** neural model speaks it. The original video and its sound keep playing; the Russian voice-over plays on top.

Typical use: a film, stream, or game with English subtitles, and you want to *hear* them in Russian.

> **Status:** MVP. The UI is in Russian; the target language is Russian.

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Install and build](#install-and-build)
- [Usage](#usage)
- [Settings](#settings)
- [How it works](#how-it-works)
- [Neural voice (Qwen3-TTS)](#neural-voice-qwen3-tts)
- [Project structure](#project-structure)
- [Tests](#tests)
- [Privacy](#privacy)
- [Known limitations](#known-limitations)
- [Credits and licenses](#credits-and-licenses)

## Features

- **Any source on screen:** pick an app window, draw a region (ideally just the subtitle strip), or use the whole main display.
- **Fully local:** OCR (Vision), translation (Apple Translation) and speech run on the device. No frames or text are saved or sent anywhere.
- **Two voices:**
  - **System voice:** any installed ru-RU voice (Milena, Yuri, …) via `AVSpeechSynthesizer`.
  - **Qwen3-TTS:** an on-device neural voice via [MLX](https://github.com/ml-explore/mlx-swift). It streams audio and starts speaking about 0.1 s after a line is ready (M5 Pro, Release build), and falls back to the system voice automatically.
- **Smart de-duplication:** each line is spoken once. OCR jitter, flicker, multi-line subtitles and rolling captions don't cause repeats.
- **Stays in sync:** the speech queue is bounded and lines that waited too long are dropped, so the voice doesn't fall behind the video.
- **Speaker labels:** "Dutch: Let's go" can be spoken as just "Let's go"; the screen keeps the full line.
- **Floating panel** with the current original and translation, a history list, and a **menu-bar** control (Start / Pause / Stop).

## Requirements

| | |
|---|---|
| macOS | 26 Tahoe or later |
| Hardware | Apple silicon (M1 or later) |
| Xcode | 26 or later (to build) |
| Metal Toolchain | Required to build MLX: `xcodebuild -downloadComponent MetalToolchain` |
| Russian system voice | e.g. Milena or Yuri. Needed for the system engine and as the fallback for Qwen |
| Apple Translation model | For the chosen language pair; the app offers to download it |
| Qwen3-TTS (optional) | ~1.9 GB download, ~3 GB RAM while running |

## Install and build

There are no prebuilt releases yet; build from source.

```sh
# 1. One-time: the Metal compiler needed by MLX
xcodebuild -downloadComponent MetalToolchain

# 2. Get the code
git clone https://github.com/andrew-ignatiev/screen-voice.git
cd screen-voice
open ScreenVoice.xcodeproj
```

3. In Xcode, select the **ScreenVoice** target → **Signing & Capabilities** → choose **your Team**. The project is set to the author's team, so change it.
4. Choose the **ScreenVoice** scheme and **My Mac**, then press **Run** (⌘R). Swift packages (MLX, mlx-audio-swift) resolve on the first build; versions are pinned in `Package.resolved`.

From the terminal:

```sh
xcodebuild -project ScreenVoice.xcodeproj -scheme ScreenVoice -destination 'platform=macOS' build
```

> **Why Run uses Release:** the shared scheme launches the app in the **Release** configuration. In Debug, MLX runs slower than real time (0.63 s to first audio and 1.37× slower than playback in our measurement), so neural speech would stutter. Tests still build in Debug.

### Screen recording permission and signing

macOS ties the "Screen & System Audio Recording" permission to the app's code signature. With "Sign to Run Locally" the permission may reset after every rebuild, which is why step 3 matters. If the permission gets stuck:

```sh
tccutil reset ScreenCapture app.screenvoice.ScreenVoice
```

## Usage

1. On first launch, grant **Screen & System Audio Recording** (System Settings → Privacy & Security). macOS may ask you to relaunch the app.
2. Click **«Выбрать область/окно…»** (Choose region/window). Selecting only the subtitle strip gives the best speed and accuracy.
3. If a language-model warning appears, click **«Загрузить модель»** (Download model) and confirm. This is Apple Translation's model for the language pair.
4. Optional: choose the neural voice in **Settings → Озвучка → Движок → Qwen3-TTS** and click **«Загрузить»** (Download), about 1.9 GB.
5. Click **«Старт»** (Start). Translations appear in the floating panel and are spoken.
6. **«Пауза»** (Pause) pauses recognition and speech; **«Стоп»** (Stop) stops capture and unloads the neural model. **«Пропустить реплику»** (Skip line) and **«Очистить очередь»** (Clear queue) control the speech queue.

The menu-bar icon (filled while capturing) offers Start / Pause / Resume / Stop, the floating-panel toggle, Settings and Quit.

## Settings

Open with **ScreenVoice → Settings…** (⌘,) or from the menu-bar icon. Settings are saved in `UserDefaults` and apply immediately, even while capturing (except the source language).

### Languages

| Setting | Values | Default | Notes |
|---|---|---|---|
| Source language | English, German, French, Spanish, Japanese | English | Locked while capturing. Support for the pair is checked at runtime |
| Target language | Russian | Russian | Fixed in the MVP |

### Speech

| Setting | Values | Default | Notes |
|---|---|---|---|
| Engine | System voice / Qwen3-TTS (neural) | System voice | Qwen falls back to the system voice while the model is missing, loading, or failing |
| Model *(Qwen)* | Download / progress / Delete | – | 1.9 GB, verified by SHA-256 |
| Qwen voice *(Qwen)* | Variant N + «Другой голос» (another voice) | Variant 1 | Each variant is a different generated voice; see [Placeholder voice](#placeholder-voice) |
| Voice / Fallback voice | Best installed Russian, or a specific ru-RU voice | Best installed | Used by the system engine, and as the fallback for Qwen |
| Speed | Slider | Normal | System: `AVSpeechUtterance` rate. Qwen: 0.5×–2× time-stretch, pitch preserved |
| Volume | 0–100 % | 100 % | Speech volume only; the video's volume is not changed |
| Skip name before colon | On / Off | On | Doesn't speak speaker labels such as "Dutch:" |
| Max queued phrases | 1–10 | 3 | When full, the oldest waiting phrase is dropped |
| Preview («Прослушать») | Button | – | Speaks a sample phrase with the current engine |

### Recognition

| Setting | Values | Default | Notes |
|---|---|---|---|
| Analysis rate | 1–10 frames/s | 4 | How often OCR runs. Lower means less CPU and a slower reaction |
| OCR mode | Accurate / Fast | Accurate | Fast is Latin-script only (Japanese always uses Accurate) |
| Min OCR confidence | 10–90 % | 40 % | Lines below this confidence are ignored |

### Display

| Setting | Default | Notes |
|---|---|---|
| Show floating panel | On | Hiding the panel doesn't stop processing |

### Advanced (in code)

De-duplication thresholds live in `TextChangeDetector.Configuration` (`ScreenVoice/Services/OCR/TextChangeDetector.swift`):

| Parameter | Default | Meaning |
|---|---|---|
| `requiredStableFrames` | 2 | Consecutive ticks a line must be visible |
| `minimumStableDuration` | 0.3 s | Minimum time visible before it is spoken |
| `similarityThreshold` | 0.8 | Edit-distance similarity at which two texts count as the same |
| `historyLifetime` | 20 s | How long a spoken line suppresses repeats |
| `historyLimit` | 40 | How many spoken lines are remembered |
| `rowGapFactor` | 1.0 | Max gap between rows of one subtitle, in line heights |

Speech queue age limit: a phrase that waited more than **10 s** is skipped (`SpeechQueue.maxAge`).

**Speaker-label rules** (`Services/Speech/SpeakerLabelFilter.swift`): the name is one to four words, each capitalized or a number ("Dutch", "DUTCH", "Mr. Smith", "Soldier 2"). It appears at the start of the line, after a dialogue dash, or after the end of a sentence. The colon must be followed by a space, so times like "10:30" are untouched, and ordinary phrases like "I'll say: yes" stay as they are.

## How it works

### Pipeline

```mermaid
flowchart LR
    subgraph cap["Capture"]
        SC["ScreenCaptureKit<br/>window or region"] -->|latest frame only| F[(Frame slot)]
    end
    subgraph rec["Recognition loop"]
        F --> OCR["Vision OCR<br/>VNRecognizeTextRequest"]
        OCR --> TCD["TextChangeDetector<br/>filter · merge rows · track<br/>stability · de-dup"]
    end
    subgraph tra["Translation loop"]
        TCD -->|confirmed phrase| BQ[(Bounded buffer<br/>newest N)]
        BQ --> TR["Apple Translation<br/>TranslationSession"]
    end
    TR -->|event stream| AC["AppCoordinator<br/>main actor"]
    AC --> UI["Floating panel<br/>history · menu bar"]
    AC --> SLF["SpeakerLabelFilter"] --> SS["SpeechService<br/>bounded queue, 10 s max age"]
    SS -->|System| AV["AVSpeechSynthesizer<br/>ru-RU voice"]
    SS -->|Qwen3-TTS| QW["QwenSynthesizer<br/>MLX"] --> AE["AVAudioEngine<br/>time-stretch"]
```

Key decisions:

- **No frame backlog.** Capture overwrites a single "latest frame" slot and the OCR loop takes it at its own pace. If OCR is slow, the effective rate drops by itself instead of queuing.
- **Static screens still confirm.** ScreenCaptureKit sends no frames while the picture is unchanged, so the detector keeps ticking on the last OCR result and a subtitle on a paused video still gets confirmed.
- **The app never reads itself.** When capturing a region, ScreenVoice's own windows are excluded from the stream.
- **Stale lines are dropped.** The translation buffer and the speech queue are bounded, and a phrase older than 10 s is not spoken.
- **Translation outside SwiftUI.** On macOS 26, `TranslationSession(installedSource:target:)` is created directly for an installed pair, so translation runs in a background loop. Downloading a missing model still needs SwiftUI's `.translationTask`, so that button lives in the main window.

### Text change detection

`TextChangeDetector` is a pure value type with no clock or I/O, so it is fully unit-tested. On every tick:

```mermaid
flowchart TD
    A[OCR lines] --> B["1. Filter<br/>confidence ≥ min, length ≥ 2,<br/>normalize whitespace"]
    B --> C["2. Merge<br/>fragments on one row,<br/>adjacent rows into one block"]
    C --> D["3. Track blocks across ticks<br/>fuzzy match, similarity ≥ 0.8"]
    D --> E{"Seen ≥ 2 ticks<br/>and ≥ 0.3 s?"}
    E -- no --> W[wait]
    E -- yes --> G{"Row spoken in<br/>the last 20 s?"}
    G -- yes --> X[drop]
    G -- no --> H[Emit phrase]
```

### Speech engine selection

```mermaid
sequenceDiagram
    participant C as AppCoordinator
    participant S as SpeechService
    participant Q as QwenVoiceController
    participant N as QwenSynthesizer (actor)
    participant P as QwenPhraseSpeaker
    participant Y as SystemPhraseSpeaker

    C->>Q: Start → prepare(voiceSeed)
    Q->>N: load model + voice conditioning
    C->>S: enqueue(translated phrase)
    alt Qwen selected and ready
        S->>P: speak(text)
        P->>N: synthesize(text)
        loop every ~0.5 s of audio
            N-->>P: PCM chunk
            P->>P: schedule on AVAudioPlayerNode
        end
        P-->>S: finished
    else model missing / loading / error
        S->>Y: speak(text) with the ru-RU system voice
        Y-->>S: finished
    end
    C->>Q: Stop → unload (frees ~3 GB)
```

### Run states

```mermaid
stateDiagram-v2
    [*] --> Idle
    Idle --> Starting: Start (permission, source,<br/>translation model OK)
    Starting --> Running: capture started<br/>(Qwen loaded if selected)
    Starting --> Idle: error
    Running --> Paused: Pause
    Paused --> Running: Resume
    Running --> Idle: Stop / capture ended by the system
    Paused --> Idle: Stop
```

### Concurrency

The project builds with Swift 6 and `SWIFT_STRICT_CONCURRENCY = complete`.

- UI state, `AppCoordinator`, `SpeechService` and the audio players live on the **main actor**.
- Recognition and translation run as two background tasks in `PipelineCoordinator`. Their options sit behind a `Mutex`, so settings apply on the next tick without a restart.
- `QwenSynthesizer` is an **actor** with an internal FIFO gate, so only one MLX operation (load, voice preparation, generation, unload) runs at a time.
- `QwenVoiceController` chains loads and unloads in call order, so a quick Stop → Start can't interleave them.

## Neural voice (Qwen3-TTS)

| | |
|---|---|
| Model | [`mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit`](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit), revision `50f45ef` (pinned) |
| Runtime | [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) `624fd54` on [mlx-swift](https://github.com/ml-explore/mlx-swift) `ac4ae9a`, pinned before MLX 0.32.2, which slows Metal token generation by ~50% |
| Storage | `~/Library/Containers/app.screenvoice.ScreenVoice/Data/Library/Application Support/ScreenVoice/Models/` |
| Download | 12 files, 1.99 GB. Each file's size and SHA-256 are checked before the folder is moved into place. Resumes per file |
| Memory | ~3 GB peak while loaded. Loaded on Start; unloaded on Stop and 2 min after a preview |

### Measured latency and quality

Apple M5 Pro, 24 GB, Release build, 20 typical Russian subtitle lines, 0.5 s streaming chunks, standalone benchmark (no OCR or translation running):

| Variant | First audio | Total per line (median / max) | Speed vs real time | Peak memory | Word error rate* |
|---|---|---|---|---|---|
| **8-bit (used)** | **0.12 s** | 0.56 / 0.85 s | 4× faster | 2.95 GB | **0 %** |
| 4-bit | 0.10 s | 0.45 / 0.64 s | 4.8× faster | 2.67 GB | 0.9 % |

\* The output was transcribed with Apple's on-device ru-RU `DictationTranscriber` and compared with the input text.

One-time startup: model load ≈ 1.3 s, voice preparation ≈ 1.9 s.

Not used: the 808 MB "vocab-pruned" Qwen3-TTS builds from AtomGradient. Their pruning removes every Cyrillic token, so they can't speak Russian.

### Placeholder voice

The Base model clones whatever voice it is given as a reference. Until a designed voice ships, ScreenVoice makes one:

```mermaid
flowchart LR
    S[Voice variant N] -->|seed MLX RNG| G["Qwen3 Base speaks a fixed<br/>Russian sentence in a random voice"]
    G --> W[("qwen-voice-N.wav<br/>cached")]
    W --> R["prepareReferenceConditioning<br/>(once per load)"]
    R --> T["Every phrase is generated<br/>in that same voice"]
```

The same variant number always gives the same voice. «Другой голос» (another voice) moves to the next variant.

### Behaviour details

- **Streaming:** audio is scheduled on `AVAudioPlayerNode` as 0.5 s chunks arrive, so playback starts before the line finishes generating.
- **Skip / Stop:** playback stops at once. A generation already running finishes in the background and its audio is discarded. It runs ~4× faster than real time, so it has usually finished anyway. This keeps the model's shared decoder state from being corrupted.
- **Speed:** Qwen3 has no speaking-rate control, so `AVAudioUnitTimePitch` stretches playback (bypassed at 1×).
- **Output device change:** the current phrase ends and the audio engine restarts on the next phrase.

## Project structure

```
ScreenVoice/
├── ScreenVoiceApp.swift              App entry: main window, Settings, menu-bar extra
├── App/
│   ├── AppCoordinator.swift          User actions, permissions, run state, Qwen lifecycle
│   ├── AppState.swift                Observable UI state
│   └── SettingsStore.swift           UserDefaults persistence
├── Models/                           AppSettings, CaptureSource, RecognizedLine, TranslationResult
├── Services/
│   ├── Capture/                      CaptureService (SCStream), RegionSelector
│   ├── OCR/                          OCRService (Vision), TextChangeDetector
│   ├── Translation/                  TranslationService (availability, translation)
│   ├── Pipeline/                     PipelineCoordinator (recognition + translation loops)
│   └── Speech/
│       ├── SpeechService.swift       Queue, engine choice, pause/skip, fallback
│       ├── SystemPhraseSpeaker.swift AVSpeechSynthesizer wrapper
│       ├── SpeakerLabelFilter.swift  "Name:" stripping
│       └── Qwen/
│           ├── QwenModelStore.swift      Pinned download + SHA-256 verification
│           ├── QwenSynthesizer.swift     MLX model actor, voice, streaming generation
│           ├── QwenVoiceController.swift Ordered load/unload, state for the UI
│           └── QwenPhraseSpeaker.swift   AVAudioEngine streaming playback
├── Views/                            Main window, source picker, settings, overlay, menu bar
└── Resources/                        Asset catalog
ScreenVoiceTests/                     Swift Testing suites
```

Dependencies (Swift Package Manager, pinned in `ScreenVoice.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`): `mlx-swift` (`MLX`), `mlx-audio-swift` (`MLXAudioCore`, `MLXAudioTTS`) and their transitive packages.

## Tests

In Xcode: **Product → Test** (⌘U). From the terminal:

```sh
xcodebuild -project ScreenVoice.xcodeproj -scheme ScreenVoice -destination 'platform=macOS' test
```

| Suite | Covers |
|---|---|
| `TextChangeDetectorTests` | Stabilization, de-duplication, OCR jitter, multi-line merge, rolling captions, normalization |
| `PipelineTests` | Bounded speech queue, stale-phrase skipping, settings → pipeline, settings compatibility, region geometry |
| `SpeakerLabelFilterTests` | Speaker-label stripping rules |
| `NeuralVoiceTests` | Engine settings, speed mapping, model install checks, plus **end-to-end Russian synthesis** and serialized generation (these two run only when the model is installed in the app container) |

## Privacy

- Only the selected window or region is captured. Frames stay in memory, and only the latest one is kept.
- No frames, recognized text or translations are written to disk or sent over the network.
- The only network traffic is model downloads: Apple's translation model (by the system) and, if you choose it, Qwen3-TTS from Hugging Face. That is why the sandboxed app has the `com.apple.security.network.client` entitlement.

## Known limitations

- Subtitles that appear word by word may be spoken in parts or repeated.
- Protected content (e.g. DRM video in Safari) may be captured as a black frame.
- The app doesn't lower the video's volume; speech plays on top.
- Latency depends on region size, analysis rate and Mac model. Qwen latency under full OCR and translation load hasn't been measured yet.
- The Qwen voice is a generated placeholder; a designed Russian voice is planned.
- The UI is in Russian only.

## Credits and licenses

- ScreenVoice is released under the [MIT License](LICENSE).
- [Qwen3-TTS](https://huggingface.co/Qwen) by the Qwen team (Alibaba Cloud), Apache-2.0. The model is downloaded at runtime, not bundled.
- [MLX Swift](https://github.com/ml-explore/mlx-swift) (MIT) and [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) (MIT).
- The Qwen integration follows the approach of [Say It](https://github.com/callebtc/sayit) (MIT).
