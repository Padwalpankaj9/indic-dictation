from __future__ import annotations

import argparse
import json
import queue
import sys
import time
import wave
from datetime import datetime
from pathlib import Path

import pyperclip
import sounddevice as sd

from marathi_dictation.sarvam_client import SarvamError, transcribe_marathi, translate_to_english


SAMPLE_RATE = 16_000
CHANNELS = 1


def write_wav(output_path: Path, audio_chunks: list[bytes]) -> None:
    # WAV keeps the MVP simple and matches Sarvam's recommended 16 kHz input.
    with wave.open(str(output_path), "wb") as wav_file:
        wav_file.setnchannels(CHANNELS)
        wav_file.setsampwidth(2)
        wav_file.setframerate(SAMPLE_RATE)
        for chunk in audio_chunks:
            wav_file.writeframes(chunk)


def record_until_enter(output_path: Path) -> float:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    audio_queue: queue.Queue[bytes] = queue.Queue()

    def callback(indata, frames, time_info, status) -> None:  # noqa: ANN001
        if status:
            print(f"Audio warning: {status}", file=sys.stderr)
        audio_queue.put(bytes(indata))

    print("Press Enter to start recording.")
    input()
    print("Recording. Speak Marathi now. Press Enter again to stop.")

    started = time.perf_counter()
    with sd.RawInputStream(
        samplerate=SAMPLE_RATE,
        channels=CHANNELS,
        dtype="int16",
        callback=callback,
    ):
        input()

    duration = time.perf_counter() - started

    chunks: list[bytes] = []
    while not audio_queue.empty():
        chunks.append(audio_queue.get())
    write_wav(output_path, chunks)

    return duration


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def run_once(args: argparse.Namespace) -> int:
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    audio_path = Path(args.audio_in) if args.audio_in else Path(args.audio_out or f"samples/{timestamp}.wav")
    result_path = Path(args.result_out or f"outputs/{timestamp}.json")

    if args.audio_in:
        duration = None
        print(f"Using existing audio: {audio_path}")
    else:
        duration = record_until_enter(audio_path)
        print(f"Saved audio: {audio_path} ({duration:.1f}s)")

    started = time.perf_counter()
    marathi = None
    english = translate_to_english(audio_path)
    marathi = transcribe_marathi(audio_path) if args.show_marathi else None
    latency = time.perf_counter() - started

    result = {
        "audio_path": str(audio_path),
        "duration_seconds": round(duration, 2) if duration is not None else None,
        "mode": "rest",
        "sarvam_latency_seconds": round(latency, 2),
        "sarvam_request_count": english.get("chunk_count", 1),
        "english": english,
    }
    if marathi is not None:
        result["marathi"] = marathi
    write_json(result_path, result)

    english_text = english.get("transcript", "")

    if marathi is not None:
        marathi_text = marathi.get("transcript", "")
        print("\nMarathi transcript:")
        print(marathi_text or "(empty)")

    print("\nEnglish translation:")
    print(english_text or "(empty)")
    print(f"\nSaved result: {result_path}")
    print(f"Sarvam latency: {latency:.1f}s")

    if args.copy and english_text:
        pyperclip.copy(english_text)
        print("Copied English translation to clipboard.")

    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Record Indic speech, currently Marathi, and translate it to English.")
    parser.add_argument("--copy", action="store_true", help="Copy the English translation to the clipboard.")
    parser.add_argument("--audio-in", help="Use an existing audio file instead of recording from the microphone.")
    parser.add_argument("--audio-out", help="Path for the recorded WAV file.")
    parser.add_argument("--result-out", help="Path for the JSON result file.")
    parser.add_argument("--show-marathi", action="store_true", help="Also fetch and print the Marathi transcript.")
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        return run_once(args)
    except KeyboardInterrupt:
        print("\nStopped.")
        return 130
    except SarvamError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
