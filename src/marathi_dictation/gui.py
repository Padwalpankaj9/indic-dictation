from __future__ import annotations

import queue
import threading
import time
import tkinter as tk
from datetime import datetime
from pathlib import Path
from tkinter import messagebox, ttk

import pyperclip
import Quartz
import sounddevice as sd

from marathi_dictation.cli import CHANNELS, SAMPLE_RATE, write_json, write_wav
from marathi_dictation.hotkey import ShortcutStateMachine
from marathi_dictation.mac_paste import PasteError, TargetApp, capture_frontmost_app, paste_text_to_app
from marathi_dictation.paths import data_path
from marathi_dictation.sarvam_client import SarvamError, translate_to_english
from marathi_dictation.settings import MODIFIER_KEY_CODES, SHORTCUT_PRESETS, load_shortcut, save_shortcut


class DictationApp(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("Indic Dictation MVP")
        self.geometry("820x520")
        self.minsize(720, 460)

        self.audio_queue: queue.Queue[bytes] = queue.Queue()
        self.audio_stream: sd.RawInputStream | None = None
        self.started_at: float | None = None
        self.latest_english = ""
        self.latest_audio_path: Path | None = None
        self.target_app: TargetApp | None = None
        self.hotkey_enabled = False
        self.auto_paste_pending = False
        self.selected_shortcut = load_shortcut()
        self.shortcut_state = ShortcutStateMachine(
            start_recording=self._start_hotkey_recording,
            stop_recording=self._stop_hotkey_recording,
            status_changed=self._set_hotkey_status,
        )

        self._build_ui()
        self._set_status("Ready")
        self.protocol("WM_DELETE_WINDOW", self.on_close)
        self.after(200, self.enable_hotkey)

    def _build_ui(self) -> None:
        self.columnconfigure(0, weight=1)
        self.rowconfigure(6, weight=1)

        controls = ttk.Frame(self, padding=16)
        controls.grid(row=0, column=0, sticky="ew")
        controls.columnconfigure(6, weight=1)

        self.start_button = ttk.Button(controls, text="Start Recording", command=self.start_recording)
        self.start_button.grid(row=0, column=0, padx=(0, 8))

        self.stop_button = ttk.Button(controls, text="Stop and Translate", command=self.stop_recording, state="disabled")
        self.stop_button.grid(row=0, column=1, padx=(0, 8))

        self.copy_button = ttk.Button(controls, text="Copy English", command=self.copy_english, state="disabled")
        self.copy_button.grid(row=0, column=2, padx=(0, 8))

        self.prepare_target_button = ttk.Button(controls, text="Prepare Target", command=self.prepare_target)
        self.prepare_target_button.grid(row=0, column=3, padx=(0, 8))

        self.paste_target_button = ttk.Button(
            controls,
            text="Paste to Target",
            command=self.paste_to_target,
            state="disabled",
        )
        self.paste_target_button.grid(row=0, column=4, padx=(0, 8))

        self.hotkey_button = ttk.Button(controls, text="Enable Cmd+Option", command=self.toggle_hotkey)
        self.hotkey_button.grid(row=0, column=5, padx=(0, 8))

        self.status_var = tk.StringVar()
        ttk.Label(controls, textvariable=self.status_var).grid(row=0, column=6, sticky="e")

        path_frame = ttk.Frame(self, padding=(16, 0, 16, 8))
        path_frame.grid(row=1, column=0, sticky="ew")
        path_frame.columnconfigure(1, weight=1)
        ttk.Label(path_frame, text="Audio").grid(row=0, column=0, sticky="w", padx=(0, 8))
        self.audio_path_var = tk.StringVar(value="No recording yet")
        ttk.Label(path_frame, textvariable=self.audio_path_var).grid(row=0, column=1, sticky="ew")

        target_frame = ttk.Frame(self, padding=(16, 0, 16, 8))
        target_frame.grid(row=2, column=0, sticky="ew")
        target_frame.columnconfigure(1, weight=1)
        ttk.Label(target_frame, text="Target").grid(row=0, column=0, sticky="w", padx=(0, 8))
        self.target_var = tk.StringVar(value="No target selected")
        ttk.Label(target_frame, textvariable=self.target_var).grid(row=0, column=1, sticky="ew")

        shortcut_frame = ttk.Frame(self, padding=(16, 0, 16, 8))
        shortcut_frame.grid(row=3, column=0, sticky="ew")
        shortcut_frame.columnconfigure(3, weight=1)
        ttk.Label(shortcut_frame, text="Shortcut").grid(row=0, column=0, sticky="w", padx=(0, 8))
        self.shortcut_var = tk.StringVar(value=self.selected_shortcut)
        self.shortcut_combo = ttk.Combobox(
            shortcut_frame,
            textvariable=self.shortcut_var,
            values=list(SHORTCUT_PRESETS),
            state="readonly",
            width=22,
        )
        self.shortcut_combo.grid(row=0, column=1, sticky="w", padx=(0, 8))
        self.shortcut_combo.bind("<<ComboboxSelected>>", self.on_shortcut_changed)
        ttk.Label(shortcut_frame, text="Hold selected shortcut to record.").grid(row=0, column=2, sticky="w")

        hotkey_frame = ttk.Frame(self, padding=(16, 0, 16, 8))
        hotkey_frame.grid(row=4, column=0, sticky="ew")
        hotkey_frame.columnconfigure(1, weight=1)
        ttk.Label(hotkey_frame, text="Hotkey").grid(row=0, column=0, sticky="w", padx=(0, 8))
        self.hotkey_state_var = tk.StringVar(value=f"Waiting for {self.selected_shortcut}")
        ttk.Label(hotkey_frame, textvariable=self.hotkey_state_var).grid(row=0, column=1, sticky="ew")

        ttk.Label(self, text="English Translation", padding=(16, 12, 16, 4)).grid(row=5, column=0, sticky="w")
        self.english_text = tk.Text(self, height=8, wrap="word", font=("Helvetica", 18))
        self.english_text.grid(row=6, column=0, sticky="nsew", padx=16, pady=(0, 16))

        self.progress = ttk.Progressbar(self, mode="indeterminate")
        self.progress.grid(row=7, column=0, sticky="ew", padx=16, pady=(0, 16))

    def _set_status(self, text: str) -> None:
        self.status_var.set(text)

    def _set_text(self, widget: tk.Text, value: str) -> None:
        widget.delete("1.0", tk.END)
        widget.insert("1.0", value)

    def _audio_callback(self, indata, frames, time_info, status) -> None:  # noqa: ANN001
        self.audio_queue.put(bytes(indata))

    def start_recording(self) -> None:
        self.audio_queue = queue.Queue()
        self.started_at = time.perf_counter()
        self.latest_english = ""
        self.copy_button.configure(state="disabled")
        self.paste_target_button.configure(state="disabled")
        self._set_text(self.english_text, "")

        try:
            self.audio_stream = sd.RawInputStream(
                samplerate=SAMPLE_RATE,
                channels=CHANNELS,
                dtype="int16",
                callback=self._audio_callback,
            )
            self.audio_stream.start()
        except Exception as exc:  # noqa: BLE001
            messagebox.showerror("Microphone error", str(exc))
            self._set_status("Microphone error")
            if self.audio_stream is not None:
                try:
                    self.audio_stream.stop()
                    self.audio_stream.close()
                except Exception:
                    pass
                self.audio_stream = None
            self.start_button.configure(state="normal")
            self.stop_button.configure(state="disabled")
            return

        self.start_button.configure(state="disabled")
        self.stop_button.configure(state="normal")
        self._set_status("Recording. Speak Marathi now.")

    def stop_recording(self) -> None:
        if self.audio_stream is None or self.started_at is None:
            return

        self.audio_stream.stop()
        self.audio_stream.close()
        self.audio_stream = None

        duration = time.perf_counter() - self.started_at
        self.started_at = None

        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        audio_path = data_path("samples", f"{timestamp}.wav")
        audio_path.parent.mkdir(parents=True, exist_ok=True)

        chunks: list[bytes] = []
        while not self.audio_queue.empty():
            chunks.append(self.audio_queue.get())
        write_wav(audio_path, chunks)

        self.latest_audio_path = audio_path
        self.audio_path_var.set(f"{audio_path} ({duration:.1f}s)")
        self.stop_button.configure(state="disabled")
        self.progress.start(12)

        if duration > 25:
            self._set_status("Long recording. Splitting and uploading to Sarvam...")
        else:
            self._set_status("Uploading to Sarvam...")
        worker = threading.Thread(target=self._process_audio, args=(audio_path, duration), daemon=True)
        worker.start()

    def _process_audio(self, audio_path: Path, duration: float) -> None:
        try:
            started = time.perf_counter()
            english = translate_to_english(audio_path)
            latency = time.perf_counter() - started

            result = {
                "mode": "rest",
                "audio_path": str(audio_path),
                "duration_seconds": round(duration, 2),
                "sarvam_latency_seconds": round(latency, 2),
                "sarvam_request_count": english.get("chunk_count", 1),
                "english": english,
            }
            result_path = data_path("outputs", f"{audio_path.stem}.json")
            write_json(result_path, result)

            self.after(0, self._show_result, english, result_path, latency)
        except SarvamError as exc:
            self.after(0, self._show_error, str(exc))
        except Exception as exc:  # noqa: BLE001
            self.after(0, self._show_error, f"Unexpected error: {exc}")

    def _show_result(self, english: dict, result_path: Path, latency: float) -> None:
        self.progress.stop()
        english_text = english.get("transcript", "")
        self.latest_english = english_text

        self._set_text(self.english_text, english_text or "(empty)")
        self.copy_button.configure(state="normal" if english_text else "disabled")
        self.paste_target_button.configure(
            state="normal" if english_text and self.target_app is not None else "disabled"
        )
        self.start_button.configure(state="normal")
        request_count = english.get("chunk_count", 1)
        request_note = f"{request_count} Sarvam requests" if request_count > 1 else "1 Sarvam request"
        if english_text:
            pyperclip.copy(english_text)
            self._set_status(
                f"Done. Copied English. {request_note}. Sarvam latency {latency:.1f}s. Saved {result_path}."
            )
            if self.auto_paste_pending and self.target_app is not None:
                self.auto_paste_pending = False
                self.after(200, self.paste_to_target)
            else:
                self.auto_paste_pending = False
        else:
            self.auto_paste_pending = False
            self._set_status(f"Done. {request_note}. Sarvam latency {latency:.1f}s. Saved {result_path}.")

    def _show_error(self, message: str) -> None:
        self.progress.stop()
        self.start_button.configure(state="normal")
        self.stop_button.configure(state="disabled")
        self._set_status("Error")
        messagebox.showerror("Sarvam error", message)

    def copy_english(self) -> None:
        if self.latest_english:
            pyperclip.copy(self.latest_english)
            self._set_status("Copied English translation to clipboard.")

    def on_shortcut_changed(self, event=None) -> None:  # noqa: ANN001
        selected = self.shortcut_var.get()
        if selected not in SHORTCUT_PRESETS:
            self.shortcut_var.set(self.selected_shortcut)
            return
        self.selected_shortcut = selected
        save_shortcut(selected)
        if self.audio_stream is None:
            self.hotkey_state_var.set(f"Waiting for {selected}")
        self._set_status(f"Shortcut set to {selected}.")

    def prepare_target(self) -> None:
        self.prepare_target_button.configure(state="disabled")
        self._set_status("Switch to the target app and click where text should go.")
        self.target_var.set("Waiting 3 seconds...")
        self.after(3000, self._capture_target)

    def _capture_target(self) -> None:
        try:
            target = capture_frontmost_app()
        except PasteError as exc:
            self.target_app = None
            self.target_var.set("No target selected")
            self.prepare_target_button.configure(state="normal")
            messagebox.showerror("Target error", str(exc))
            self._set_status("Target capture failed.")
            return

        self.target_app = target
        self.target_var.set(f"{target.name} ({target.bundle_id})")
        self.prepare_target_button.configure(state="normal")
        self.paste_target_button.configure(
            state="normal" if self.latest_english else "disabled"
        )
        self._set_status(f"Target set to {target.name}.")

    def paste_to_target(self) -> None:
        if self.target_app is None:
            messagebox.showerror("Paste error", "Prepare a target app first.")
            return
        try:
            paste_text_to_app(self.latest_english, self.target_app)
        except PasteError as exc:
            messagebox.showerror("Paste error", str(exc))
            self._set_status("Paste failed.")
            return
        self._set_status(f"Pasted English into {self.target_app.name}.")

    def toggle_hotkey(self) -> None:
        if self.hotkey_enabled:
            self.disable_hotkey()
            return
        self.enable_hotkey()

    def enable_hotkey(self) -> None:
        if self.hotkey_enabled:
            return
        self.hotkey_enabled = True
        self.hotkey_button.configure(text="Disable Hotkey")
        self._set_status(f"Hotkey mode on. Hold {self.selected_shortcut} in any app to record.")
        self._poll_hotkey()

    def disable_hotkey(self) -> None:
        self.hotkey_enabled = False
        self.shortcut_state.reset()
        self.auto_paste_pending = False
        self.hotkey_button.configure(text="Enable Hotkey")
        self.hotkey_state_var.set("Hotkey monitoring off")
        self._set_status("Hotkey mode off.")

    def _poll_hotkey(self) -> None:
        if not self.hotkey_enabled:
            return

        modifier_states = {
            name: any(self._is_key_down(key_code) for key_code in key_codes)
            for name, key_codes in MODIFIER_KEY_CODES.items()
        }
        active_modifiers = [name for name, is_down in modifier_states.items() if is_down]
        active_text = ", ".join(active_modifiers) if active_modifiers else "none"
        self.hotkey_state_var.set(
            f"Selected: {self.selected_shortcut} | Pressed: {active_text}"
        )

        required_modifiers = SHORTCUT_PRESETS[self.selected_shortcut]
        is_pressed = all(modifier_states[modifier] for modifier in required_modifiers)
        self.shortcut_state.update(is_pressed, time.perf_counter())

        self.after(40, self._poll_hotkey)

    def _is_key_down(self, key_code: int) -> bool:
        state = Quartz.kCGEventSourceStateHIDSystemState
        return bool(Quartz.CGEventSourceKeyState(state, key_code))

    def _set_hotkey_status(self, status: str) -> None:
        self.hotkey_state_var.set(f"{status} | Shortcut: {self.selected_shortcut}")

    def _start_hotkey_recording(self, locked: bool = False) -> None:
        if self.audio_stream is not None:
            return
        self.auto_paste_pending = False
        try:
            self.target_app = capture_frontmost_app()
            self.target_var.set(f"{self.target_app.name} ({self.target_app.bundle_id})")
        except PasteError:
            self.target_app = None
            self.target_var.set("No target selected")
        self.start_recording()
        if locked:
            self._set_status("Locked recording. Tap shortcut once to stop.")

    def _stop_hotkey_recording(self) -> None:
        if self.audio_stream is None:
            return
        self.auto_paste_pending = self.target_app is not None
        self.stop_recording()

    def on_close(self) -> None:
        self.hotkey_enabled = False
        self.shortcut_state.reset()
        self.destroy()


def main() -> int:
    app = DictationApp()
    app.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
