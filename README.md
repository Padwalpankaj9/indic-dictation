# Marathi Dictation

Local Mac dictation app for speaking Marathi and pasting final English text into the active app. It uses Sarvam Saaras v3 through the REST speech-to-text API.

## What it does

- Runs as a native Swift menu bar app.
- Records a 16 kHz WAV file from the Mac microphone.
- Sends the audio to Sarvam for English translation.
- Splits longer recordings into smaller Sarvam requests and combines the English result.
- Automatically pastes the English translation into the target app.
- Supports hold-to-record and double-tap lock recording modes.
- Lets the shortcut be changed from the menu bar.
- Shows a small bottom-center floating indicator while recording and processing.
- Includes a debug window for permissions, current shortcut, target, and last English result.

## Setup

The app expects `SARVAM_API_KEY` to be available in the shell environment or in:

```bash
~/.config/shell/secrets.env
```

Python MVP dependencies are still available for fallback testing:

```bash
uv sync
```

## Run

Native Swift menu bar app during development:

```bash
cd SwiftMarathiDictation
swift build
.build/debug/MarathiDictationApp
```

Build an installable Mac app:

```bash
cd SwiftMarathiDictation
./scripts/package_app.sh --release --install
```

The installed app is:

```bash
/Applications/Marathi Dictation.app
```

## UI workflow

Menu bar workflow:

1. Start `/Applications/Marathi Dictation.app`.
2. Click where the English text should appear.
3. Use either shortcut mode:
   - Hold mode: hold the selected shortcut, speak, then release to translate and paste.
   - Lock mode: quickly tap the selected shortcut twice, speak hands-free, then tap once to translate and paste.

Use the menu bar menu to enable/disable the hotkey, choose a shortcut, copy the last English result, open permission settings, or open the debug window.
The bottom-center indicator shows animated voice bars while recording and a spinner while translating.

## macOS permissions

The installed Swift app needs these macOS permissions:

- Microphone: records your voice.
- Input Monitoring: reads the selected global modifier shortcut.
- Accessibility: posts the paste keystroke into the target app.
- Notifications: shows permission and error notifications.

The menu bar app shows a permission summary and has direct links to the relevant System Settings panes.

## Python fallback

The earlier Python MVP is kept for fallback/debugging:

```bash
PYTHONPATH=src uv run python -m marathi_dictation.menubar
PYTHONPATH=src uv run python -m marathi_dictation.gui
```

Terminal-only MVP:

```bash
PYTHONPATH=src uv run python -m marathi_dictation.cli
```

To copy the English result:

```bash
PYTHONPATH=src uv run python -m marathi_dictation.cli --copy
```

To reprocess an existing audio file:

```bash
PYTHONPATH=src uv run python -m marathi_dictation.cli --audio-in samples/example.wav
```

## Output

Swift recorded audio goes to:

```bash
~/Library/Application Support/Marathi Dictation/samples
```

Swift long-recording chunks go to:

```bash
~/Library/Application Support/Marathi Dictation/chunks
```

Python fallback recordings go to `samples/`, and Python Sarvam responses go to `outputs/`.

Local recordings, generated outputs, app bundles, build folders, virtualenvs, IDE state, and secret files are ignored by git.
