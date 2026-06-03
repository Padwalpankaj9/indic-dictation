from __future__ import annotations

import argparse
import asyncio
import base64
import json
import queue
import sys
import time
import wave
from pathlib import Path
from typing import Any

import sounddevice as sd
from sarvamai import AsyncSarvamAI

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from marathi_dictation.sarvam_client import load_sarvam_api_key  # noqa: E402

SAMPLE_RATE = 16000
CHANNELS = 1
SAMPLE_WIDTH_BYTES = 2


def _message_to_dict(message: Any) -> dict[str, Any]:
    if isinstance(message, dict):
        return message
    if hasattr(message, "model_dump"):
        return message.model_dump()
    if hasattr(message, "dict"):
        return message.dict()
    if hasattr(message, "__dict__"):
        return dict(message.__dict__)
    return {"raw": str(message)}


def _extract_text(message: dict[str, Any]) -> str:
    for key in ("text", "transcript", "translation"):
        value = message.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()

    data = message.get("data")
    if isinstance(data, dict):
        nested = _extract_text(data)
        if nested:
            return nested

    return ""


def _print_message(message: Any) -> str:
    message_dict = _message_to_dict(message)
    print(json.dumps(message_dict, ensure_ascii=False, indent=2, default=str), flush=True)
    return _extract_text(message_dict)


async def _receive_until_text(ws: Any, timeout_seconds: float) -> str:
    started = time.perf_counter()
    final_text = ""
    while time.perf_counter() - started < timeout_seconds:
        remaining = max(0.1, timeout_seconds - (time.perf_counter() - started))
        message = await asyncio.wait_for(ws.recv(), timeout=remaining)
        final_text = _print_message(message) or final_text
        message_type = str(_message_to_dict(message).get("type", "")).lower()
        if final_text and message_type in {"data", "translation", "transcript"}:
            break
    return final_text


async def _connect(
    client: AsyncSarvamAI,
    endpoint: str,
    *,
    input_audio_codec: str,
    vad_signals: bool,
    flush_signal: bool,
) -> Any:
    if endpoint == "stt":
        return client.speech_to_text_streaming.connect(
            model="saaras:v3",
            mode="translate",
            language_code="mr-IN",
            sample_rate=str(SAMPLE_RATE),
            input_audio_codec=input_audio_codec,
            high_vad_sensitivity="true",
            vad_signals=str(vad_signals).lower(),
            flush_signal=str(flush_signal).lower(),
        )

    return client.speech_to_text_translate_streaming.connect(
        model="saaras:v3",
        mode="translate",
        sample_rate=str(SAMPLE_RATE),
        input_audio_codec=input_audio_codec,
        high_vad_sensitivity="true",
        vad_signals=str(vad_signals).lower(),
        flush_signal=str(flush_signal).lower(),
    )


async def _send_audio(ws: Any, endpoint: str, audio: str, encoding: str) -> None:
    if endpoint == "stt":
        await ws.transcribe(audio=audio, encoding=encoding, sample_rate=SAMPLE_RATE)
    else:
        await ws.translate(audio=audio, encoding=encoding, sample_rate=SAMPLE_RATE)


async def run_file_probe(args: argparse.Namespace) -> int:
    audio_path = Path(args.audio)
    if not audio_path.is_absolute():
        audio_path = ROOT / audio_path
    if not audio_path.exists():
        print(f"Audio file not found: {audio_path}", file=sys.stderr)
        return 2

    client = AsyncSarvamAI(api_subscription_key=load_sarvam_api_key(), timeout=args.timeout)
    started = time.perf_counter()
    final_text = ""

    async with await _connect(
        client,
        args.endpoint,
        input_audio_codec=args.codec,
        vad_signals=args.vad,
        flush_signal=args.flush,
    ) as ws:
        if args.strategy == "wav-once":
            audio_data = base64.b64encode(audio_path.read_bytes()).decode("utf-8")
            await _send_audio(ws, args.endpoint, audio_data, args.encoding)
        else:
            with wave.open(str(audio_path), "rb") as wav_file:
                if wav_file.getframerate() != SAMPLE_RATE or wav_file.getnchannels() != CHANNELS:
                    raise ValueError("Expected mono 16 kHz WAV for streaming probe.")
                frames_per_chunk = int(SAMPLE_RATE * args.chunk_ms / 1000)
                while True:
                    frames = wav_file.readframes(frames_per_chunk)
                    if not frames:
                        break
                    audio_data = base64.b64encode(frames).decode("utf-8")
                    await _send_audio(ws, args.endpoint, audio_data, args.encoding)
                    await asyncio.sleep(args.chunk_ms / 1000)

        if args.flush:
            await ws.flush()

        final_text = await _receive_until_text(ws, args.timeout)

    elapsed = time.perf_counter() - started
    print("\n--- streaming summary ---")
    print(f"endpoint: {args.endpoint}")
    print(f"strategy: {args.strategy}")
    print(f"codec: {args.codec}")
    print(f"encoding: {args.encoding}")
    print(f"audio: {audio_path}")
    print(f"elapsed_seconds: {elapsed:.2f}")
    print(f"english: {final_text or '(no final text extracted)'}")
    return 0 if final_text else 1


async def _receive_background(ws: Any, stop_event: asyncio.Event, final_text: list[str]) -> None:
    while not stop_event.is_set():
        try:
            message = await asyncio.wait_for(ws.recv(), timeout=0.5)
        except asyncio.TimeoutError:
            continue
        except Exception as exc:
            if not stop_event.is_set():
                print(f"receive stopped: {exc}", file=sys.stderr, flush=True)
            break
        text = _print_message(message)
        if text:
            final_text[:] = [text]


async def run_live_probe(args: argparse.Namespace) -> int:
    audio_queue: queue.Queue[bytes] = queue.Queue()

    def callback(indata: bytes, frames: int, time_info: Any, status: sd.CallbackFlags) -> None:
        if status:
            print(f"audio status: {status}", file=sys.stderr, flush=True)
        audio_queue.put(bytes(indata))

    client = AsyncSarvamAI(api_subscription_key=load_sarvam_api_key(), timeout=args.timeout)
    stop_event = asyncio.Event()
    final_text: list[str] = []

    async with await _connect(
        client,
        args.endpoint,
        input_audio_codec=args.codec,
        vad_signals=args.vad,
        flush_signal=args.flush,
    ) as ws:
        receiver = asyncio.create_task(_receive_background(ws, stop_event, final_text))
        stream = sd.RawInputStream(
            samplerate=SAMPLE_RATE,
            channels=CHANNELS,
            dtype="int16",
            blocksize=int(SAMPLE_RATE * args.chunk_ms / 1000),
            callback=callback,
        )

        print("\nLive streaming probe is listening.")
        print("Speak Marathi now. Press Enter here when you are done.\n")

        with stream:
            wait_for_enter = asyncio.to_thread(sys.stdin.readline)
            enter_task = asyncio.create_task(wait_for_enter)
            while not enter_task.done():
                try:
                    chunk = audio_queue.get_nowait()
                except queue.Empty:
                    await asyncio.sleep(0.01)
                    continue
                audio_data = base64.b64encode(chunk).decode("utf-8")
                await _send_audio(ws, args.endpoint, audio_data, args.encoding)

        if args.flush:
            print("Flushing final audio...", flush=True)
            await ws.flush()
            await asyncio.sleep(min(args.timeout, 2.0))

        stop_event.set()
        receiver.cancel()
        try:
            await receiver
        except asyncio.CancelledError:
            pass

    print("\n--- live streaming summary ---")
    print(f"endpoint: {args.endpoint}")
    print(f"codec: {args.codec}")
    print(f"encoding: {args.encoding}")
    print(f"english: {final_text[-1] if final_text else '(no final text extracted)'}")
    return 0 if final_text else 1


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Probe Sarvam streaming Marathi-to-English translation.")
    parser.add_argument("--live", action="store_true", help="Stream from the microphone until Enter is pressed.")
    parser.add_argument(
        "audio",
        nargs="?",
        default="samples/20260602-190912.wav",
        help="Path to a 16 kHz WAV file for file-based probes.",
    )
    parser.add_argument("--endpoint", choices=["stt", "translate"], default="stt")
    parser.add_argument("--strategy", choices=["wav-once", "pcm-chunks"], default="pcm-chunks")
    parser.add_argument("--codec", default="pcm_s16le", help="Connection input_audio_codec.")
    parser.add_argument("--encoding", default="audio/wav", help="Per-message audio encoding.")
    parser.add_argument("--chunk-ms", type=int, default=100)
    parser.add_argument("--timeout", type=float, default=20.0)
    parser.add_argument("--no-vad", dest="vad", action="store_false")
    parser.add_argument("--no-flush", dest="flush", action="store_false")
    parser.set_defaults(vad=True, flush=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.live:
        return asyncio.run(run_live_probe(args))
    return asyncio.run(run_file_probe(args))


if __name__ == "__main__":
    raise SystemExit(main())
