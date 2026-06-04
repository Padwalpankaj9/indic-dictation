#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from sarvamai import SarvamAI


APP_SUPPORT = Path.home() / "Library/Application Support/Indic Dictation"
MODEL_NAME = "hey_vaani"
MODEL_DIR = APP_SUPPORT / "WakeWordTraining/output" / MODEL_NAME
MANIFEST_PATH = MODEL_DIR / "sarvam_synthetic_manifest.jsonl"

SPEAKERS = [
    "shubh",
    "priya",
    "aditya",
    "neha",
    "rahul",
    "pooja",
    "rohan",
    "simran",
    "kavya",
    "amit",
    "varun",
    "tanya",
    "tarun",
    "shruti",
    "mohit",
    "kavitha",
    "rehan",
    "soham",
    "rupali",
]

PACES = [0.85, 1.0, 1.15, 1.3]


@dataclass(frozen=True)
class Phrase:
    text: str
    language_code: str
    label: str


POSITIVE_PHRASES = [
    Phrase("Hey Vaani", "en-IN", "wake"),
    Phrase("Hey Vani", "en-IN", "wake"),
    Phrase("हे वाणी", "mr-IN", "wake"),
]


NEGATIVE_PHRASES = [
    Phrase("Hey Vanita", "en-IN", "near_miss_name"),
    Phrase("Hey Vayu", "en-IN", "near_miss_name"),
    Phrase("Hey Vaibhav", "en-IN", "near_miss_name"),
    Phrase("Hey Varun", "en-IN", "near_miss_name"),
    Phrase("Hey Vasu", "en-IN", "near_miss_name"),
    Phrase("Hey Rani", "en-IN", "near_miss_name"),
    Phrase("Hey Wani", "en-IN", "near_miss_name"),
    Phrase("Hey Veda", "en-IN", "near_miss_name"),
    Phrase("Hey Vihan", "en-IN", "near_miss_name"),
    Phrase("Hey Vaani nahi", "hi-IN", "explicit_not_wake"),
    Phrase("Okay Vaani", "en-IN", "near_miss_command"),
    Phrase("Hi Vaani", "en-IN", "near_miss_command"),
    Phrase("Hello Vaani", "en-IN", "near_miss_command"),
    Phrase("Are Vaani", "en-IN", "near_miss_command"),
    Phrase("Vaani", "en-IN", "partial_wake"),
    Phrase("हे वनिता", "mr-IN", "near_miss_name"),
    Phrase("हे वायू", "mr-IN", "near_miss_name"),
    Phrase("हे वैभव", "mr-IN", "near_miss_name"),
    Phrase("हे वाणी नाही", "mr-IN", "explicit_not_wake"),
    Phrase("हाय वाणी", "mr-IN", "near_miss_command"),
    Phrase("मी वाणीबद्दल बोलतोय", "mr-IN", "normal_speech"),
    Phrase("वनिता आज आली आहे", "mr-IN", "normal_speech"),
    Phrase("वायू वेगाने वाहतोय", "mr-IN", "normal_speech"),
    Phrase("मला हे इंग्रजीत लिहायचे आहे", "mr-IN", "normal_speech"),
    Phrase("आज आपण काय करणार आहोत", "mr-IN", "normal_speech"),
    Phrase("मी मराठीत बोलतो आहे", "mr-IN", "normal_speech"),
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate Sarvam TTS hard-negative clips for the Hey Vaani wake-word model."
    )
    parser.add_argument("--negative-count", type=int, default=int(os.getenv("NEGATIVE_COUNT", "80")))
    parser.add_argument("--positive-count", type=int, default=int(os.getenv("POSITIVE_COUNT", "0")))
    parser.add_argument("--speakers", default=os.getenv("SARVAM_TTS_SPEAKERS", ",".join(SPEAKERS[:10])))
    parser.add_argument("--paces", default=os.getenv("SARVAM_TTS_PACES", ",".join(str(p) for p in PACES)))
    parser.add_argument("--model", default=os.getenv("SARVAM_TTS_MODEL", "bulbul:v3"))
    parser.add_argument("--sample-rate", type=int, default=int(os.getenv("SARVAM_TTS_SAMPLE_RATE", "16000")))
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def split_dir(kind: str, generated_index: int) -> Path:
    if kind == "positive":
        split = "positive_test" if generated_index % 5 == 4 else "positive_train"
    else:
        split = "negative_test" if generated_index % 5 == 4 else "negative_train"
    path = MODEL_DIR / split
    path.mkdir(parents=True, exist_ok=True)
    return path


def initial_next_index(directory: Path) -> int:
    existing = []
    for file in directory.glob("clip_*.wav"):
        stem = file.stem
        if stem.startswith("clip_") and stem[5:].isdigit():
            existing.append(int(stem[5:]))
    return max(existing, default=-1) + 1


def next_clip_path(directory: Path, next_indexes: dict[Path, int]) -> Path:
    if directory not in next_indexes:
        next_indexes[directory] = initial_next_index(directory)
    next_index = next_indexes[directory]
    next_indexes[directory] += 1
    return directory / f"clip_{next_index:06d}.wav"


def response_audio_bytes(response: Any) -> bytes:
    if isinstance(response, bytes):
        return response

    audios = getattr(response, "audios", None)
    if audios:
        return base64.b64decode("".join(audios))

    audio = getattr(response, "audio", None)
    if audio:
        return base64.b64decode(audio)

    if isinstance(response, dict):
        if response.get("audios"):
            return base64.b64decode("".join(response["audios"]))
        if response.get("audio"):
            return base64.b64decode(response["audio"])

    raise TypeError(f"Unsupported Sarvam TTS response type: {type(response)!r}")


def normalize_wav(audio_bytes: bytes, output_path: Path, sample_rate: int) -> None:
    # Sarvam can emit WAV directly, but afconvert makes the training format exact.
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp_file:
        tmp_file.write(audio_bytes)
        tmp_path = Path(tmp_file.name)
    try:
        subprocess.run(
            [
                "afconvert",
                "-f",
                "WAVE",
                "-d",
                f"LEI16@{sample_rate}",
                "-c",
                "1",
                str(tmp_path),
                str(output_path),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
    finally:
        tmp_path.unlink(missing_ok=True)


def synthesize(
    client: SarvamAI,
    phrase: Phrase,
    speaker: str,
    pace: float,
    model: str,
    sample_rate: int,
) -> bytes:
    response = client.text_to_speech.convert(
        text=phrase.text,
        model=model,
        target_language_code=phrase.language_code,
        speaker=speaker,
        pace=pace,
        speech_sample_rate=sample_rate,
        output_audio_codec="wav",
    )
    return response_audio_bytes(response)


def generate_kind(
    client: SarvamAI | None,
    kind: str,
    count: int,
    phrases: list[Phrase],
    speakers: list[str],
    paces: list[float],
    model: str,
    sample_rate: int,
    dry_run: bool,
) -> None:
    next_indexes: dict[Path, int] = {}
    for generated in range(count):
        phrase = phrases[generated % len(phrases)]
        speaker = speakers[(generated // len(phrases)) % len(speakers)]
        pace = paces[(generated // (len(phrases) * len(speakers))) % len(paces)]
        directory = split_dir(kind, generated)
        output_path = next_clip_path(directory, next_indexes)

        record = {
            "created_at": int(time.time()),
            "kind": kind,
            "text": phrase.text,
            "language_code": phrase.language_code,
            "label": phrase.label,
            "speaker": speaker,
            "pace": pace,
            "model": model,
            "sample_rate": sample_rate,
            "path": str(output_path),
        }

        print(f"[{kind}] {speaker} pace={pace}: {phrase.text} -> {output_path}")
        if dry_run:
            continue

        assert client is not None
        audio_bytes = synthesize(client, phrase, speaker, pace, model, sample_rate)
        normalize_wav(audio_bytes, output_path, sample_rate)
        with MANIFEST_PATH.open("a", encoding="utf-8") as manifest:
            manifest.write(json.dumps(record, ensure_ascii=False) + "\n")


def main() -> None:
    args = parse_args()
    speakers = [speaker.strip() for speaker in args.speakers.split(",") if speaker.strip()]
    paces = [float(pace.strip()) for pace in args.paces.split(",") if pace.strip()]
    if not speakers:
        raise SystemExit("At least one speaker is required.")
    if not paces:
        raise SystemExit("At least one pace is required.")

    client = None
    if not args.dry_run:
        api_key = os.getenv("SARVAM_API_KEY")
        if not api_key:
            raise SystemExit("SARVAM_API_KEY is not set. Add it to your shell secrets before running.")
        client = SarvamAI(api_subscription_key=api_key)

    generate_kind(
        client,
        "positive",
        args.positive_count,
        POSITIVE_PHRASES,
        speakers,
        paces,
        args.model,
        args.sample_rate,
        args.dry_run,
    )
    generate_kind(
        client,
        "negative",
        args.negative_count,
        NEGATIVE_PHRASES,
        speakers,
        paces,
        args.model,
        args.sample_rate,
        args.dry_run,
    )

    print(
        f"Generated {args.positive_count} Sarvam wake clips and "
        f"{args.negative_count} Sarvam hard-negative clips."
    )
    print("Next: ./scripts/train_wakeword_from_samples.sh")


if __name__ == "__main__":
    main()
