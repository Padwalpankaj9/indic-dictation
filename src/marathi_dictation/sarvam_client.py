from __future__ import annotations

import os
import subprocess
import tempfile
import wave
from pathlib import Path
from typing import Any

import requests


SARVAM_STT_URL = "https://api.sarvam.ai/speech-to-text"
SARVAM_TRANSLATE_URL = "https://api.sarvam.ai/speech-to-text"
MAX_REST_AUDIO_SECONDS = 25.0


class SarvamError(RuntimeError):
    """Raised when Sarvam cannot process the audio."""


def load_sarvam_api_key() -> str:
    key = os.environ.get("SARVAM_API_KEY")
    if key:
        return key

    secrets_file = Path.home() / ".config" / "shell" / "secrets.env"
    if not secrets_file.exists():
        raise SarvamError("SARVAM_API_KEY is not set, and secrets.env was not found.")

    # Source the existing shell secrets file without printing any secret values.
    command = f"source {secrets_file!s} >/dev/null 2>&1; printf %s \"$SARVAM_API_KEY\""
    result = subprocess.run(
        ["zsh", "-lc", command],
        check=False,
        capture_output=True,
        text=True,
    )
    key = result.stdout.strip()
    if not key:
        raise SarvamError("SARVAM_API_KEY is not set in the environment or secrets.env.")
    return key


def _post_audio(url: str, audio_path: Path, data: dict[str, str]) -> dict[str, Any]:
    api_key = load_sarvam_api_key()
    headers = {"api-subscription-key": api_key}

    with audio_path.open("rb") as audio_file:
        files = {"file": (audio_path.name, audio_file, "audio/wav")}
        response = requests.post(
            url,
            headers=headers,
            data=data,
            files=files,
            timeout=90,
        )

    if response.ok:
        return response.json()

    try:
        detail = response.json()
    except ValueError:
        detail = response.text
    raise SarvamError(f"Sarvam request failed with HTTP {response.status_code}: {detail}")


def transcribe_marathi(audio_path: Path) -> dict[str, Any]:
    return _post_audio(
        SARVAM_STT_URL,
        audio_path,
        {
            "model": "saaras:v3",
            "mode": "transcribe",
            "language_code": "mr-IN",
        },
    )


def translate_to_english(audio_path: Path) -> dict[str, Any]:
    audio_duration = _wav_duration_seconds(audio_path)
    if audio_duration <= MAX_REST_AUDIO_SECONDS:
        return _translate_short_audio(audio_path)

    with tempfile.TemporaryDirectory(prefix="indic-dictation-chunks-") as temp_dir:
        chunk_paths = _split_wav(audio_path, Path(temp_dir), MAX_REST_AUDIO_SECONDS)
        chunk_results = [_translate_short_audio(chunk_path) for chunk_path in chunk_paths]

    combined_text = " ".join(
        result.get("transcript", "").strip()
        for result in chunk_results
        if result.get("transcript", "").strip()
    )
    return {
        "transcript": combined_text,
        "chunk_count": len(chunk_results),
        "source_duration_seconds": round(audio_duration, 2),
        "chunk_duration_seconds": MAX_REST_AUDIO_SECONDS,
        "chunks": chunk_results,
    }


def _translate_short_audio(audio_path: Path) -> dict[str, Any]:
    return _post_audio(
        SARVAM_TRANSLATE_URL,
        audio_path,
        {
            "model": "saaras:v3",
            "mode": "translate",
            "language_code": "mr-IN",
        },
    )


def _wav_duration_seconds(audio_path: Path) -> float:
    with wave.open(str(audio_path), "rb") as wav_file:
        return wav_file.getnframes() / wav_file.getframerate()


def _split_wav(audio_path: Path, output_dir: Path, chunk_seconds: float) -> list[Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    chunk_paths: list[Path] = []

    with wave.open(str(audio_path), "rb") as source:
        channels = source.getnchannels()
        sample_width = source.getsampwidth()
        frame_rate = source.getframerate()
        chunk_frames = max(1, int(frame_rate * chunk_seconds))

        part_number = 1
        while True:
            frames = source.readframes(chunk_frames)
            if not frames:
                break

            chunk_path = output_dir / f"{audio_path.stem}-part{part_number:02d}.wav"
            with wave.open(str(chunk_path), "wb") as chunk:
                chunk.setnchannels(channels)
                chunk.setsampwidth(sample_width)
                chunk.setframerate(frame_rate)
                chunk.writeframes(frames)

            chunk_paths.append(chunk_path)
            part_number += 1

    return chunk_paths
