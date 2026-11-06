# ScreenVoice

**English** · [Русский](README.ru.md)

ScreenVoice is a native macOS app that reads subtitles (or any text) from a window or screen region, translates new lines into Russian, and speaks them aloud. Everything happens on your Mac: Apple Vision reads the text, Apple Translation translates it, and either a system voice or the **Qwen3-TTS** neural model speaks it. The original video and its sound keep playing; the Russian voice-over plays on top.

Typical use: a film, stream, or game with English subtitles, and you want to *hear* them in Russian.

> **Status:** MVP. The interface is available in English and Russian and follows your macOS language. Text is always translated into, and spoken in, Russian.

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Install and build](#install-and-build)
- [Usage](#usage)
- [Settings](#settings)
- [How it works](#how-it-works)
- [Neural voice (Qwen3-TTS)](#neural-voice-qwen3-tts)
- [Project structure](#project-structure)
- [Localization](#localization)
- [Tests](#tests)
- [Privacy](#privacy)
- [Known limitations](#known-limitations)
- [Credits and licenses](#credits-and-licenses)

## Features

- **Any source on screen:** pick an app window, draw a region (ideally just the subtitle strip), or use the whole main display.
- **Fully local:** OCR (Vision), translation (Apple Translation) and speech run on the device. No frames or text are saved or sent anywhere.
- **Two voices:**
  - **System voice:** any installed ru-RU voice (Milena, Yuri, …) via `AVSpeechSynthesizer`.
  - **Qwen3-TTS:** an on-device neural voice via [MLX](https://github.com/ml-explore/mlx-swift), built from a description you write (gender, timbre, manner). VoiceDesign records the voice once; the Base model then clones that recording for every phrase. It streams audio, starts speaking about 0.2 s after a line is ready (M5 Pro, Release build), and falls back to the system voice automatically.
- **Russian stress (optional):** words are stressed by their meaning (*за́мок* / *замо́к*): RUAccent marks the stressed vowels and a stress LoRA makes the voice follow them. See [Russian stress](#russian-stress).
- **Voice presets:** save a voice you like (gender, style, variant, reference length) and switch back to it later. Two narrator presets, male and female, are built in and work without the voice designer.
- **Your own voice:** record yourself reading a suggested passage (8–15 s), or import a WAV or MP3 sample, and the translation is spoken in that voice. No voice designer needed.
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
| Qwen3-TTS (optional) | ~3.1 GB download, ~4 GB RAM while running |

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
2. Click **Choose Region or Window…**. Selecting only the subtitle strip gives the best speed and accuracy.
3. If a language-model warning appears, click **Download Model** and confirm. This is Apple Translation's model for the language pair.
4. Optional: choose the neural voice in **Settings → Speech → Engine → Qwen3-TTS (neural)** and click **Download**, about 3.1 GB. The built-in narrators work right away. To describe your own voice, also download the optional **Voice designer** (another 3.1 GB), then click **Listen**.
5. Click **Start**. Translations appear in the floating panel and are spoken.
6. **Pause** pauses recognition and speech; **Stop** stops capture and unloads the neural model. **Skip Line** and **Clear Queue** control the speech queue. **Catch up** (next to Stop, on by default) speaks 1.25× faster as soon as the next subtitle is waiting and 1.5× from two, then returns to normal speed. The neural voice changes speed at once, even mid-phrase; the system voice from its next phrase. "Faster: 1.25×" shows while it is active.

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
| Model *(Qwen)* | Download / progress / Delete | – | Base, 3.1 GB, verified by SHA-256. Speaks every phrase |
| Voice designer *(Qwen)* | Download / progress / Delete | – | Optional VoiceDesign, 3.1 GB. Only needed to create new voices |
| Russian stress *(Qwen)* | Download / progress / **Mark stress** / Delete | Mark stress on | Optional RUAccent + stress LoRA, ~550 MB; see [Russian stress](#russian-stress) |
| Voice preset *(Qwen)* | Narrator, male / Narrator, female / your saved presets | Narrator, male | Shows **Custom (not saved)** after you change the voice; see [Voices and presets](#voices-and-presets) |
| Gender *(Qwen)* | Male / Female | Male | An unedited default style switches with the gender; an edited style is kept |
| Style *(Qwen)* | Free text, in English | Audiobook narrator description | Timbre, age, accent, manner. **Reset Style** restores the default |
| Voice variant *(Qwen)* | Number field with ± arrows (1–99999) | 6 (male), 3 (female) | A different voice that fits the same description |
| Reference length *(Qwen)* | Number field with ± arrows (5–12 s) | 11 s | Approximate length of the recording the voice is cloned from |
| Delivery *(Qwen)* | Calm (0.7) / Lively (0.9) | Calm | Sampling temperature for every voice. Calm keeps the pitch even; Lively varies intonation more |
| Record Your Voice… *(Qwen)* | Sheet: text to read, record, play, gender, name | – | Saves the recording as a preset that Base clones; see [Voices and presets](#voices-and-presets) |
| Import Voice Sample… *(Qwen)* | WAV or MP3 file, then the same sheet with the recognized text | – | Clones a voice from a file; see [Voices and presets](#voices-and-presets) |
| Text to listen | Text area | empty | Phrase spoken by Listen / Preview; empty uses the default phrase. Handy for checking numbers, names or long sentences |
| Listen / Save as Preset… / Delete Preset *(Qwen)* | Buttons | – | Listen creates a new voice first (10–20 s, once). Saved presets keep gender, style, variant and reference length; a preset with the same name is replaced |
| Voice / Fallback voice | Best installed Russian voice, or a specific ru-RU voice | Best installed | Used by the system engine, and as the fallback for Qwen |
| Speed | Slider | Normal | System: `AVSpeechUtterance` rate. Qwen: 0.5×–2× time-stretch, pitch preserved |
| Volume | 0–100 % | 100 % | Speech volume only; the video's volume is not changed |
| Don’t speak the name before a colon | On / Off | On | Doesn't speak speaker labels such as "Dutch:" |
| Max queued phrases | 1–10 | 3 | When full, the oldest waiting phrase is dropped |
| Preview *(system voice)* | Button | – | Speaks a sample phrase |

### Recognition

| Setting | Values | Default | Notes |
|---|---|---|---|
| Analysis rate | 1–10 frames/s | 4 | How often OCR runs. Lower means less CPU and a slower reaction |
| OCR mode | Accurate / Fast | Accurate | Fast is Latin-script only (Japanese always uses Accurate) |
| Min. OCR confidence | 10–90 % | 40 % | Lines below this confidence are ignored |

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

    C->>Q: Start → prepare()
    Q->>N: load model + warm-up phrase
    C->>S: enqueue(translated phrase)
    alt Qwen selected and ready
        S->>P: speak(text, voice)
        P->>N: synthesize(text, voice)
        N->>N: seed MLX with voice.seed
        loop every ~0.5 s of audio
            N-->>P: PCM chunk
            P->>P: schedule on AVAudioPlayerNode
        end
        P-->>S: finished
    else model missing / loading / error
        S->>Y: speak(text) with the ru-RU system voice
        Y-->>S: finished
    end
    C->>Q: Stop → unload (frees ~4 GB)
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
- `QwenSynthesizer` is an **actor** with an internal FIFO gate, so only one MLX operation (load, generation, unload) runs at a time. That also keeps each phrase's seed from being disturbed by another generation.
- `QwenVoiceController` chains loads and unloads in call order, so a quick Stop → Start can't interleave them.

## Neural voice (Qwen3-TTS)

| | |
|---|---|
| Speech model | [`mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit`](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit), revision `e7dd058` (pinned) |
| Voice designer (optional) | [`mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit`](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit), revision `f90d617` (pinned) |
| Russian stress (optional) | [`ruaccent/accentuator`](https://huggingface.co/ruaccent/accentuator) `b78ae5e` + [`siriusfreak/qwen3-tts-12hz-1.7b-ru-stress-cf`](https://huggingface.co/siriusfreak/qwen3-tts-12hz-1.7b-ru-stress-cf) `c16b3af` LoRA, 19 files (pinned); see [Russian stress](#russian-stress) |
| Runtime | [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) `624fd54` on [mlx-swift](https://github.com/ml-explore/mlx-swift) `ac4ae9a`, pinned before MLX 0.32.2, which slows Metal token generation by ~50% |
| Storage | `~/Library/Containers/app.screenvoice.ScreenVoice/Data/Library/Application Support/ScreenVoice/Models/`; created voices in `…/ScreenVoice/VoiceReferences/` |
| Download | 12 files per model, 3.1 GB each. Each file's size and SHA-256 are checked before the folder is moved into place. Resumes per file. Files of the 0.6B model used by earlier builds are deleted automatically |
| Memory | ~4.4 GB peak while speaking. Only one model is in memory at a time. Loaded on Start; unloaded on Stop and 2 min after a preview |
| Sampling | `top_k 50`, as in the models' `generation_config.json`. mlx-audio-swift leaves it at 0 (no limit), which made speech harsher, misread numbers and let the voice drift |

### Measured latency and quality

Apple M5 Pro, 24 GB, Release build, 0.5 s streaming chunks, standalone benchmark (no OCR or translation running), the same 25 Russian lines including numbers:

| | Base clone, 11 s reference (used) | VoiceDesign + variant (previous build) | Base bf16 (not used) |
|---|---|---|---|
| First audio | 0.19 s | 0.15 s | 0.66 s |
| Speed vs real time | ~3× faster | ~3.5× faster | slower than real time |
| Peak memory while speaking | 4.4 GB | 3.9 GB | 6.1 GB |
| Word errors* (19 lines without numbers) | 3 minor | 1 | 1 |
| Numbers (1500 рублей, 2024, 1984…) | all correct | "1500 рублей" misread | all correct |
| Pitch of the male narrator | 93 Hz, deepest | 109 Hz | 94 Hz |

\* The output was transcribed with Apple's on-device ru-RU `DictationTranscriber` and compared with the input text. A 6 s reference gave 0 word errors but a less steady, higher voice (112 Hz); the 11 s one sounded better in listening tests.

One-time startup: model load ≈ 1 s plus a short warm-up phrase, so the first subtitle is as fast as the rest (without it the first phrase took 2.5 s to start).

Not used: the 808 MB "vocab-pruned" Qwen3-TTS builds from AtomGradient. Their pruning removes every Cyrillic token, so they can't speak Russian.

### Voices and presets

A voice is a description plus a variant number. It is turned into a short reference recording once, then cloned for every phrase:

```mermaid
flowchart LR
    G["Gender<br/>Native Russian male speaker."] --> I[Instruction]
    S["Style<br/>Deep, warm, resonant baritone. …"] --> I
    I --> D["VoiceDesign<br/>loaded only while creating"]
    V["Variant N"] -->|MLXRandom.seed| D
    L["Reference length 5–12 s"] -->|reference text| D
    D --> R[("Reference recording<br/>+ its transcript")]
    R --> B["Qwen3-TTS Base<br/>clones it for every phrase"]
    B --> A["Audio in the same voice"]
    P[("Preset<br/>gender + style + variant + length")] -.->|select| G & S & V & L
```

- **Creating a voice** happens the first time you click **Listen** (or press Start) with a new combination: Base is unloaded, VoiceDesign is loaded, records the reference, and is unloaded; then Base is loaded again. It takes 10–20 s and is saved, so it happens once per voice. Without the voice designer installed, a new voice speaks with the built-in narrator until it is created.
- **Recording your own voice:** **Record Your Voice…** shows a passage to read: complete sentences of calm narration, together covering every Russian letter, with a question and an exclamation. **Another Text** offers three more. Silence at both ends is trimmed and the level normalized; 3–20 s is accepted, 8–15 s clones best. The transcript must match what was said, so the text is editable. The recording becomes a preset and stays in `…/ScreenVoice/VoiceReferences/` until no voice uses it.
- **Importing a sample:** **Import Voice Sample…** (or **Choose File…** in the recording sheet) takes a WAV or MP3 file in any sample rate and channel count. It is mixed to mono, trimmed and normalized like a recording. A sample longer than 20 s is cut at the pause nearest 15 s, so no word is split. The text is recognized on the Mac by Apple's ru-RU dictation model (the system downloads it on first use, and asks for speech recognition permission once), then you check it: the clone needs the exact words. One speaker without music clones best.
- **Delivery** sets the sampling temperature for speaking (references are always created at 0.9). On the same 25 lines, 0.7 narrowed the male narrator's pitch range from 80–126 Hz to 82–111 Hz with the same intelligibility.
- **Built-in narrators** ship their references in the app (male variant 6, female variant 3, every length 5–12 s), so they need only the Base model.
- **Reference length** picks one of eight texts of growing length that share the same opening. The real length depends on the voice. Each length is a slightly different recording, so compare by ear.
- **Why the seed matters:** VoiceDesign invents a new voice every time unless the random generator is seeded. The variant is the seed, both for the reference and for every cloned phrase, so the same text always gives identical audio.
- **Style text** works best in English. The default is an audiobook-narrator description; the male and female defaults differ only in the timbre line.
- **Presets** are stored with the other settings in `UserDefaults`. Built-in presets can't be changed or deleted; picking one and editing anything gives a custom voice you can save under a new name.

### Russian stress

The optional **Russian stress** pack (~550 MB) makes the neural voice stress words by their meaning: *за́мок* (castle) vs *замо́к* (lock), *му́ка* vs *мука́*. It has two parts that only work together:

- **[RUAccent](https://huggingface.co/ruaccent/accentuator)** (revision `b78ae5e`) marks the stressed vowel of every word of the translation: a dictionary of 3.2 million word forms, a model that picks between homographs from the sentence (turbo3.1), a model for ё, one that decides which words carry stress, and a character model for unknown words. ScreenVoice runs a Swift port on [ONNX Runtime](https://github.com/microsoft/onnxruntime-swift-package-manager) 1.24.2 (CPU, a few milliseconds per phrase). The marks are U+0301 after the vowel. Capitalized words are lowercased before marking, because RUAccent stresses them worse.
- **[siriusfreak's stress LoRA](https://huggingface.co/siriusfreak/qwen3-tts-12hz-1.7b-ru-stress-cf)** (revision `c16b3af`, rank 16 on the talker's attention and MLP, 35 MB) teaches Base to follow the marks. Without it the marks garble words; without marks it sounds like the plain model. It is applied at load time to the 196 8-bit layers as `W₈x + 2·BAx`. Merging it into the 8-bit weights would mean re-quantizing them, which adds about 50% more weight error.

| | Without the pack | With the pack |
|---|---|---|
| Stress | The model's guess | RUAccent's marks, followed |
| First audio | ~0.19 s | ~0.21 s |
| Speed | ~0.32 of real time | ~0.35 of real time |
| Memory | ~4.4 GB | +~0.9 GB (RUAccent on ONNX Runtime) |

- The port matches the Python library (RUAccent 1.5.8.3, `use_dictionary=True`) exactly on 485 test lines, with three fixes, also applied to the Python reference:
  - Model labels are matched to words by character offset. RUAccent matched them by list position, so after "..." or "?!" every later label landed on the wrong word.
  - Each homograph variant is scored on its own; the batched path normalized over the whole batch.
  - Sentences are split by a simple rule instead of razdel.
- The ONNX models run with basic graph optimization: full optimization in ONNX Runtime 1.24 shifts the character model's scores enough to change marks on rare words.
- The first load after installing builds a compact table from the dictionary (`dictionary/accents.table`, 88 MB, a few seconds). After that it is memory-mapped.
- In a listening test on 16 hard lines, LoRA + RUAccent marks sounded better than the plain model. Hand-checked marks were better still, because RUAccent got about 8 of the lines' homographs and ё words wrong (*узнаем/узнаём*, *нёбо*, *щавель*). RUAccent's larger big_poetry homograph model made as many mistakes.
- **Mark stress** turns it off without deleting the pack; the model reloads. If the pack fails to load, phrases are spoken without marks and the settings show why.

### Behaviour details

- **Streaming:** audio is scheduled on `AVAudioPlayerNode` as 0.5 s chunks arrive, so playback starts before the line finishes generating.
- **Skip / Stop:** playback stops at once. A generation already running finishes in the background and its audio is discarded. It runs ~3.5× faster than real time, so it has usually finished anyway. This keeps the model's shared decoder state from being corrupted.
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
├── Models/                           AppSettings, NeuralVoice + VoicePreset, CaptureSource, RecognizedLine, TranslationResult
├── Services/
│   ├── Capture/                      CaptureService (SCStream), RegionSelector
│   ├── OCR/                          OCRService (Vision), TextChangeDetector
│   ├── Translation/                  TranslationService (availability, translation)
│   ├── Pipeline/                     PipelineCoordinator (recognition + translation loops)
│   └── Speech/
│       ├── SpeechService.swift       Queue, engine choice, pause/skip, fallback
│       ├── SystemPhraseSpeaker.swift AVSpeechSynthesizer wrapper
│       ├── SpeakerLabelFilter.swift  "Name:" stripping
│       ├── Qwen/
│       │   ├── QwenModelStore.swift      Pinned download + SHA-256 verification
│       │   ├── QwenSynthesizer.swift     MLX model actor: Base cloning, VoiceDesign references
│       │   ├── QwenVoiceController.swift Ordered load/unload, state for the UI
│       │   └── QwenPhraseSpeaker.swift   AVAudioEngine streaming playback
│       └── Stress/
│           ├── RussianStressMarker.swift RUAccent port: stress usage, ё, homographs, dictionary, character model
│           ├── StressText.swift          RUAccent's text rules (splitting, spacing, case)
│           ├── WordPieceTokenizer.swift  BERT tokenizer with offsets
│           ├── ByteLevelBPETokenizer.swift RoBERTa tokenizer with RUAccent's 10 000 added word forms
│           ├── StressDictionary.swift    Memory-mapped table of 3.2 million stressed word forms
│           ├── ONNXModel.swift           ONNX Runtime session wrapper
│           └── StressLoRA.swift          Runtime LoRA on the talker's quantized layers
├── Views/                            Main window, source picker, settings, overlay, menu bar
└── Resources/
    ├── Localizable.xcstrings         String Catalog: English source + Russian translation
    ├── Voices/                       Built-in narrator references (5–12 s)
    └── Assets.xcassets               App icon, accent colour
ScreenVoiceTests/                     Swift Testing suites
```

Dependencies (Swift Package Manager, pinned in `ScreenVoice.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`): `mlx-swift` (`MLX`, `MLXNN`), `mlx-audio-swift` (`MLXAudioCore`, `MLXAudioTTS`), `onnxruntime-swift-package-manager` 1.24.2 (`onnxruntime`) and their transitive packages.

## Localization

The interface is written in English (the development language) and translated with an Xcode **String Catalog**, `ScreenVoice/Resources/Localizable.xcstrings`. The app follows the macOS language: a Mac set to Russian shows the Russian interface, any other language shows English. To pick a language for this app only, use System Settings → General → Language & Region → Applications.

| Language | Status |
|---|---|
| English | Source language |
| Russian | Complete (all translatable strings) |

How strings are handled in code:

- SwiftUI literals (`Text("Start")`, `Button("Retry")`, `Label`, `Section`, `.help`) are localization keys automatically.
- Strings built outside views (status text, errors, enum names) use `String(localized:)`. A `comment:` disambiguates short words, e.g. "Paused" as a status.
- Interpolated values become format specifiers (`"In queue: %lld"`); translations use positional arguments (`%1$@`, `%2$@`) where word order may change.
- Language names come from `Locale.localizedString(forLanguageCode:)`, so the system translates them.
- Text the app *speaks* (the preview phrase) is content in the target language, and the voice description is model input in English; neither is localized.

To add a language: open `Localizable.xcstrings` in Xcode, click **+** to add the language, translate every string, and add the language code to `knownRegions` (Xcode does this when you add it in Project → Info → Localizations). Building in Xcode adds new strings to the catalog automatically.

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
| `LocalizationTests` | English development language, Russian translations present, format strings with arguments, system language names, spoken text stays Russian |
| `NeuralVoiceTests` | Voice description, gender switching, presets (save, replace, delete, built-ins), settings compatibility, reference texts and bundled narrators, reference file naming, recorded voices (file, transcript, trimming, cleanup), delivery temperature, speed mapping, model install checks, removal of old model files, plus **end-to-end**: Russian synthesis speed, identical audio for the same voice, creating a voice with VoiceDesign and speaking it with Base, speaking a 48 kHz recorded voice, serialized generation, the stress LoRA (196 wrapped layers, numeric check), speaking with stress marks, fallback when the pack is broken (these run only when the models are installed in the app container) |
| `RussianStressTests` | RUAccent text rules against Python, pinned stress pack, settings default, and with the pack installed: token ids identical to Hugging Face, marks identical to the Python reference on 485 lines (`RussianStressGolden.json`) |

## Privacy

- Only the selected window or region is captured. Frames stay in memory, and only the latest one is kept.
- No frames, recognized text or translations are written to disk or sent over the network.
- The only network traffic is model downloads: Apple's translation model (by the system) and, if you choose it, Qwen3-TTS from Hugging Face. That is why the sandboxed app has the `com.apple.security.network.client` entitlement.
- The microphone is used only while **Record Your Voice…** is recording (`com.apple.security.device.audio-input`). An imported file is read only after you pick it in the open panel (`com.apple.security.files.user-selected.read-only`); its words are recognized on this Mac. The recording is kept on this Mac and deleted when no voice uses it.

## Known limitations

- Subtitles that appear word by word may be spoken in parts or repeated.
- Protected content (e.g. DRM video in Safari) may be captured as a black frame.
- The app doesn't lower the video's volume; speech plays on top.
- Latency depends on region size, analysis rate and Mac model. Qwen latency under full OCR and translation load hasn't been measured yet.
- VoiceDesign occasionally skips or adds a word in a reference; the clone then sounds less natural. Try another variant.
- Pronunciation of numbers, dates and abbreviations hasn't been tested systematically.
- RUAccent still picks the wrong homograph or ё now and then (about 8 words on 16 hard test lines), and the stress LoRA follows wrong marks too.
- Only English and Russian interface translations so far.

## Credits and licenses

- ScreenVoice is released under the [MIT License](LICENSE).
- [Qwen3-TTS](https://huggingface.co/Qwen) by the Qwen team (Alibaba Cloud), Apache-2.0. The model is downloaded at runtime, not bundled.
- [MLX Swift](https://github.com/ml-explore/mlx-swift) (MIT) and [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) (MIT).
- [RUAccent](https://huggingface.co/ruaccent/accentuator) (MIT) and [ONNX Runtime](https://github.com/microsoft/onnxruntime) (MIT). The stress pack is downloaded at runtime, not bundled.
- [Russian stress LoRA](https://huggingface.co/siriusfreak/qwen3-tts-12hz-1.7b-ru-stress-cf) by siriusfreak (Apache-2.0). Its card notes that part of its training phrases come from a book corpus without a declared license; check before commercial use.
- The Qwen integration follows the approach of [Say It](https://github.com/callebtc/sayit) (MIT).
