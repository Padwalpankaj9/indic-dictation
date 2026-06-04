# Security Policy

## Reporting security issues

Please do not open public issues for security-sensitive reports.

Email the maintainer at `padwalpankaj9@gmail.com` with:

- A short description of the issue.
- Steps to reproduce.
- Impact and affected versions, if known.

## Sensitive data

Indic Dictation handles microphone audio and API keys. Contributors should avoid logging, committing, or uploading:

- API keys or credentials.
- Wake-word access keys or generated keyword files.
- Local recordings.
- Generated API responses containing private text.
- macOS permission or profile data.

## API key handling

The app reads `SARVAM_API_KEY` from the process environment or from:

```bash
~/.config/shell/secrets.env
```

Project `.env` files and key material are ignored by git. Do not add code that prints or persists API keys.

Experimental wake-word support can read `PICOVOICE_ACCESS_KEY` from the environment or from:

```bash
~/Library/Application Support/Indic Dictation/WakeWord/picovoice_access_key.txt
```

Do not commit Picovoice keys, `.ppn` keyword files, Porcupine model files, or downloaded Porcupine runtime binaries.
