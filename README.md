<div align="center">

<img src="assets/logo.svg" width="128" alt="HoldTalk logo"/>

# HoldTalk

**Push-to-talk dictation for macOS — 100% free, 100% offline.**

Hold a key. Speak in Bangla or English. Release. Your words appear at the cursor.

[![CI](https://img.shields.io/badge/build-swift-orange)](.github/workflows/ci.yml)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)]()
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Powered by whisper.cpp](https://img.shields.io/badge/powered%20by-whisper.cpp-8A2BE2)](https://github.com/ggerganov/whisper.cpp)

</div>

---

HoldTalk is a Wispr Flow–style dictation tool with none of the strings attached:
no API keys, no accounts, no subscriptions, no audio ever leaving your Mac.
It runs OpenAI's Whisper model locally via
[whisper.cpp](https://github.com/ggerganov/whisper.cpp) and pastes the result
into whatever app you're typing in — your editor, browser, terminal, anywhere.

## Features

- 🎙️ **Hold-to-talk** — hold Right Option (⌥), speak, release. Done.
- 🙌 **Hands-free mode** — double-tap the hotkey, talk freely, tap once to stop.
- 🎛️ **Dictation pill** — floating HUD with a live mic-level waveform and ✕ / ✓ buttons that never steal focus.
- 🕘 **History** — every transcript saved locally; pin, copy, multi-select delete.
- 🌏 **Spoken language** — defaults to Bangla for reliable language selection on short clips. Select English or Auto-detect in Settings for English or multilingual dictation.
- 🔁 **Translate mode** — hold Right Option + Shift to translate the selected spoken language into English.
- ⚡ **Fast** — the model preloads *while you're speaking* and stays warm between dictations: ~1.5–3.5s per dictation instead of ~17s cold.
- 🪶 **Featherweight when idle** — ~57 MB RAM, 0% CPU. The ~600 MB speech model auto-unloads after a configurable idle period. Built for 8 GB Macs running heavy dev workloads.
- ⌨️ **Customizable hotkeys** — rebind both modes from Settings.
- 🔒 **Private by design** — everything runs on-device. Nothing is uploaded, ever.

## How it works

```
Hold hotkey ──► whisper-server preloads model (while you speak)
     │
     ▼
AVAudioRecorder ──► 16 kHz mono WAV
     │  release
     ▼
whisper.cpp (large-v3-turbo / medium) ──► transcript
     │
     ▼
Clipboard swap ──► synthetic ⌘V ──► clipboard restored
```

The Whisper model is **never resident while idle**. On the first key-press a
local `whisper-server` spawns and loads the model during your speech; it stays
warm for fast follow-up dictations, then shuts down after the idle timeout
(default 3 min) to return its RAM to the system. If the server isn't
available, HoldTalk falls back to one-shot `whisper-cli`.

### Performance (Apple M1, 8 GB)

| Path | Latency after release | Idle RAM |
|---|---|---|
| Cold `whisper-cli` spawn | ~17 s | 0 |
| **Warm server (HoldTalk default)** | **~1.5–3.5 s** | 0 after idle timeout |

## Installation

```sh
curl -fsSL https://raw.githubusercontent.com/DevWizardHQ/HoldTalk/main/scripts/install.sh | bash
```

The installer adds `whisper-cpp` via Homebrew, downloads the two models
(~1.1 GB total), and installs the latest prebuilt release (checksum-verified)
to `/Applications/HoldTalk.app`. No Xcode needed.

<details>
<summary>Build from source instead</summary>

```sh
git clone https://github.com/DevWizardHQ/HoldTalk.git
cd HoldTalk
./setup.sh
```

`setup.sh` does the same but builds the app locally (requires Xcode command
line tools).

</details>

Then:

1. Open **HoldTalk** from Launchpad or Spotlight
2. Grant **Microphone** and **Accessibility** permissions
   (System Settings → Privacy & Security) — the hotkey activates the moment
   you grant, no relaunch needed
3. Open any app, hold **Right ⌥**, speak, release

## Usage

| Action | Result |
|---|---|
| Hold **Right ⌥** + speak | Transcribe in selected spoken language (default: Bangla) |
| Hold **Right ⌥ ⇧** + speak | Translate speech → English text |
| Double-tap **Right ⌥**, speak, tap once | Hands-free dictation |
| ✕ / ✓ on the floating pill | Cancel / finish the current dictation |
| Menu bar → History | Browse, pin, copy, delete past transcripts |
| Menu bar → Settings | Spoken language, hotkeys, keep-warm duration, launch at login |

## Models

| Mode | Model | Size | Notes |
|---|---|---|---|
| Transcribe | `ggml-large-v3-turbo-q5_0` | ~574 MB | Best multilingual speed/quality balance |
| Translate | `ggml-medium-q5_0` | ~539 MB | Whisper's built-in any-language → English |

Models live in `~/Library/Application Support/HoldTalk/models/` and can also be
downloaded from in-app Settings.

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/DevWizardHQ/HoldTalk/main/scripts/uninstall.sh | bash
```

Removes the app, downloaded models, history, logs, and preferences.
Flags: `--keep-data` (keep models + history), `--with-whisper` (also remove the
Homebrew `whisper-cpp` package), `-y` (skip confirmation).

## FAQ

**Why not the OpenAI/Groq/Deepgram API?**
HoldTalk's goal is zero cost and zero cloud. Whisper large-v3-turbo locally on
Apple Silicon is fast enough that the API buys you little.

**Does it work with languages other than Bangla/English?**
Choose **Settings → Spoken language → Auto-detect** for other languages, or
**English** for English dictation. The default is **Bangla (Bengali)** in both
transcription and translation; translation output is always English. Changes
apply to the next dictation, including when the server is already warm.
The Bangla→Hindi retry only runs for Auto-detect transcription that produces
Devanagari. It cannot identify an incorrect English sentence or judge the
meaning of a translation.

**Why can short Bangla clips produce unrelated English?**
Automatic language detection can choose the wrong language, and the existing
Devanagari retry does not catch English output. Explicit Bengali input removes
that detection ambiguity, but does not guarantee accurate recognition or
translation of colloquial Bangla. No phrase-specific replacement is applied.
See [the Bengali validation checklist](docs/bengali-validation.md).

**Why does Accessibility permission reset after I rebuild?**
macOS ties permissions to the code signature. Create the stable local signing
certificate described in [CONTRIBUTING.md](CONTRIBUTING.md#signing) once and
the build script signs every build identically — permissions then persist.

**My dictation is longer than 15 seconds — is that OK?**
Yes. The encoder window is tuned to 15 s for speed; longer audio is processed
in sequential chunks automatically.

## Development

```bash
swift build                  # debug build
swift test                   # language selection and inference transport regressions
./scripts/build-app.sh       # release .app bundle in dist/
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for project layout and guidelines.

## License

[MIT](LICENSE)
