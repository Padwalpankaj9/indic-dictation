# Contributing

Thanks for your interest in Indic Dictation.

This project is early. The most useful contributions are focused, small improvements that make the app easier to run, safer to maintain, or more useful for Indic-language dictation.

## Good contribution areas

- Add configurable source language support.
- Improve first-run macOS permission onboarding.
- Improve installation and release documentation.
- Add tests for settings, shortcut behavior, and response parsing.
- Improve latency diagnostics.
- Improve error handling for microphone, network, and API-key failures.
- Document behavior for additional Sarvam-supported Indic languages.

## Development setup

Install the Swift app during development:

```bash
cd SwiftMarathiDictation
swift build
./scripts/package_app.sh --release --install
```

Python fallback tools:

```bash
uv sync
uv run indic-dictation --help
```

## API keys

Do not commit API keys. The app reads `SARVAM_API_KEY` from the environment or from:

```bash
~/.config/shell/secrets.env
```

Local secret files, recordings, app bundles, and generated outputs are ignored by git.

## Pull request guidance

- Keep changes small and focused.
- Include a short explanation of what changed and why.
- Run the relevant build or smoke test before opening a PR.
- Avoid committing generated recordings, JSON responses, local app bundles, or IDE state.

## Current scope

The app is currently Marathi-first and macOS-first. Broader Indic-language support is the main product direction, but changes should keep the current Marathi workflow fast and reliable.
