# Indic Dictation

Local Mac dictation app for speaking Indic languages and inserting final English text into the active app. It uses Sarvam Saaras v3 through the streaming speech-to-text API.

## Why this exists

General-purpose dictation tools are often excellent for English, but they can struggle with local languages and accents, especially Indic languages. The goal of this project is to make a low-latency dictation layer for people who think and speak best in their mother tongue, but need polished English text in their day-to-day apps.

The app is a native macOS wrapper around Sarvam's speech-to-text translation API. You hold a global shortcut, speak naturally in Marathi, release the shortcut, and the app inserts the English translation wherever your cursor is. It is designed to feel like normal dictation, but optimized for Indian-language speech.

The current implementation is Marathi-first. The architecture is intentionally small enough to adapt to other Indic languages supported by Sarvam.

## Project status

Indic Dictation is early but usable. The native macOS app supports low-latency Marathi-to-English dictation today, and the next major direction is making the language layer configurable so the same workflow can support more Indian languages.

## What it does

- Runs as a native Swift menu bar app.
- Streams 16 kHz PCM microphone audio to Sarvam Saaras v3.
- Translates Marathi speech to English while recording.
- Automatically inserts the English translation into the focused app.
- Supports hold-to-record and double-tap lock recording modes.
- Lets the shortcut be changed from the menu bar.
- Lets the microphone input be selected from the menu bar.
- Includes response modes for latency/accuracy tuning: Fast, Balanced, and Accurate.
- Shows a small bottom-center floating indicator while recording and processing, with optional live English preview.
- Includes a debug window for permissions, current shortcut, microphone, target, latency marks, and last English result.

## Setup

The app expects `SARVAM_API_KEY` to be available in the shell environment or in this local file:

```bash
~/.config/shell/secrets.env
```

Example:

```bash
export SARVAM_API_KEY="your_key_here"
```

Do not commit real API keys. `.env`, `.env.*`, key files, app bundles, build folders, recordings, and generated outputs are ignored by git.

Python MVP dependencies are still available for fallback testing:

```bash
uv sync
```

## Run

Native Swift menu bar app during development:

```bash
cd SwiftMarathiDictation
swift build
.build/debug/IndicDictationApp
```

Build an installable Mac app:

```bash
cd SwiftMarathiDictation
./scripts/package_app.sh --release --install
```

The installed app is:

```bash
/Applications/Indic Dictation.app
```

## UI workflow

Menu bar workflow:

1. Start `/Applications/Indic Dictation.app`.
2. Click where the English text should appear.
3. Use either shortcut mode:
   - Hold mode: hold the selected shortcut, speak, then release to translate and paste.
   - Lock mode: quickly tap the selected shortcut twice, speak hands-free, then tap once to translate and paste.

Use the menu bar menu to:

- Enable or disable the hotkey.
- Choose the shortcut.
- Choose the microphone input or refresh connected microphones.
- Choose the response mode:
  - Fast: lowest latency for short commands.
  - Balanced: recommended default for normal dictation.
  - Accurate: waits longer for more context.
- Toggle the live preview text.
- Copy the last English result.
- Open permission settings.
- Open the debug window.

The bottom-center indicator shows animated voice bars while recording and a spinner while translating.

## macOS permissions

The installed Swift app needs these macOS permissions:

- Microphone: records your voice.
- Input Monitoring: reads the selected global modifier shortcut.
- Accessibility: posts the paste keystroke into the target app.
- Notifications: shows permission and error notifications.

The menu bar app shows a permission summary and has direct links to the relevant System Settings panes.

## Privacy and API keys

- Audio is captured locally and streamed to Sarvam for speech-to-text translation.
- Final English text is inserted into the currently focused app on your Mac.
- API keys are read from the local environment or `~/.config/shell/secrets.env`.
- API keys, recordings, generated responses, app bundles, build outputs, and local settings are excluded from git.
- Do not commit personal recordings or real API keys.

## Roadmap

- Configurable source language selection for additional Indic languages.
- Cleaner first-run permission onboarding.
- Signed release builds with a simple installer flow.
- Better streaming diagnostics for latency and network failures.
- Optional post-processing layer for tone, grammar, and formatting.
- Automated tests for shortcut state, settings, and Sarvam response parsing.

## Contributing

Contributions are welcome. Good first areas are language selection, installation docs, macOS permission UX, latency instrumentation, and tests. See `CONTRIBUTING.md`.

## Python fallback

The earlier Python MVP is kept for fallback/debugging:

```bash
uv run indic-dictation-menubar
uv run indic-dictation-ui
```

Terminal-only MVP:

```bash
uv run indic-dictation
```

To copy the English result:

```bash
uv run indic-dictation --copy
```

To reprocess an existing audio file:

```bash
uv run indic-dictation --audio-in samples/example.wav
```

## Output

Swift recorded audio goes to:

```bash
~/Library/Application Support/Indic Dictation/samples
```

Swift long-recording chunks go to:

```bash
~/Library/Application Support/Indic Dictation/chunks
```

Python fallback recordings go to `samples/`, and Python Sarvam responses go to `outputs/`.

Local recordings, generated outputs, app bundles, build folders, virtualenvs, IDE state, and secret files are ignored by git.

## License

MIT. See `LICENSE`.
