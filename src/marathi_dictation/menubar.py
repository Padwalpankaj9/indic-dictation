from __future__ import annotations

import queue
import subprocess
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

import pyperclip
import Quartz
import rumps
import sounddevice as sd

from marathi_dictation.cli import CHANNELS, SAMPLE_RATE, write_json, write_wav
from marathi_dictation.hotkey import ShortcutStateMachine
from marathi_dictation.indicator import VoiceIndicator
from marathi_dictation.mac_paste import PasteError, TargetApp, capture_frontmost_app, paste_text_to_app
from marathi_dictation.paths import data_path, resource_path
from marathi_dictation.sarvam_client import SarvamError, translate_to_english
from marathi_dictation.settings import MODIFIER_KEY_CODES, SHORTCUT_PRESETS, load_shortcut, save_shortcut


ICON_PATH = resource_path("assets", "icons", "menubar-icon-22@2x.png")


class IndicDictationMenuBar(rumps.App):
    def __init__(self) -> None:
        self.selected_shortcut = load_shortcut()
        self.hotkey_enabled = True
        self.audio_queue: queue.Queue[bytes] = queue.Queue()
        self.audio_stream: sd.RawInputStream | None = None
        self.started_at: float | None = None
        self.target_app: TargetApp | None = None
        self.latest_english = ""
        self.indicator = VoiceIndicator.alloc().init()
        self.shortcut_state = ShortcutStateMachine(
            start_recording=self.start_recording,
            stop_recording=self.stop_recording,
            status_changed=self._refresh_menu_state,
        )

        menu = [
            rumps.MenuItem("Status: Ready", callback=None),
            None,
            rumps.MenuItem("Hotkey Enabled", callback=self.toggle_hotkey),
            self._build_shortcut_menu(),
            rumps.MenuItem("Open Debug Window", callback=self.open_debug_window),
            rumps.MenuItem("Copy Last English", callback=self.copy_last_english),
            None,
        ]
        super().__init__(
            "Indic Dictation",
            title="",
            icon=str(ICON_PATH),
            template=True,
            menu=menu,
            quit_button="Quit Indic Dictation",
        )
        self.status_item = self.menu["Status: Ready"]
        self.hotkey_item = self.menu["Hotkey Enabled"]
        self.shortcut_items = {
            shortcut: self.menu["Shortcut"][shortcut]
            for shortcut in SHORTCUT_PRESETS
        }
        self._refresh_menu_state("Ready")
        self.poll_timer = rumps.Timer(self.poll_hotkey, 0.04)
        self.poll_timer.start()
        self.indicator_timer = rumps.Timer(self.tick_indicator, 0.08)
        self.indicator_timer.start()

    def _build_shortcut_menu(self) -> rumps.MenuItem:
        shortcut_menu = rumps.MenuItem("Shortcut")
        for shortcut in SHORTCUT_PRESETS:
            shortcut_menu.add(rumps.MenuItem(shortcut, callback=self.set_shortcut))
        return shortcut_menu

    def toggle_hotkey(self, _sender: rumps.MenuItem) -> None:
        self.hotkey_enabled = not self.hotkey_enabled
        if not self.hotkey_enabled:
            self.shortcut_state.reset()
        self._refresh_menu_state("Ready" if self.hotkey_enabled else "Hotkey off")

    def set_shortcut(self, sender: rumps.MenuItem) -> None:
        if sender.title not in SHORTCUT_PRESETS:
            return
        self.selected_shortcut = sender.title
        save_shortcut(self.selected_shortcut)
        self._refresh_menu_state(f"Shortcut: {self.selected_shortcut}")

    def open_debug_window(self, _sender: rumps.MenuItem) -> None:
        subprocess.Popen(
            [sys.executable, "-m", "marathi_dictation.gui"],
            cwd=str(resource_path()),
            env=None,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    def copy_last_english(self, _sender: rumps.MenuItem) -> None:
        if not self.latest_english:
            self._refresh_menu_state("No English yet")
            return
        pyperclip.copy(self.latest_english)
        self._refresh_menu_state("Copied last English")

    def poll_hotkey(self, _timer: rumps.Timer) -> None:
        if not self.hotkey_enabled:
            return

        is_pressed = self._is_selected_shortcut_pressed()
        self.shortcut_state.update(is_pressed, time.perf_counter())

    def tick_indicator(self, _timer: rumps.Timer) -> None:
        self.indicator.tick()

    def _is_selected_shortcut_pressed(self) -> bool:
        modifier_states = {
            name: any(self._is_key_down(key_code) for key_code in key_codes)
            for name, key_codes in MODIFIER_KEY_CODES.items()
        }
        required_modifiers = SHORTCUT_PRESETS[self.selected_shortcut]
        return all(modifier_states[modifier] for modifier in required_modifiers)

    def _is_key_down(self, key_code: int) -> bool:
        state = Quartz.kCGEventSourceStateHIDSystemState
        return bool(Quartz.CGEventSourceKeyState(state, key_code))

    def start_recording(self, locked: bool = False) -> None:
        if self.audio_stream is not None:
            return
        self.audio_queue = queue.Queue()
        self.started_at = time.perf_counter()
        self.latest_english = ""
        try:
            self.target_app = capture_frontmost_app()
        except PasteError:
            self.target_app = None

        try:
            self.audio_stream = sd.RawInputStream(
                samplerate=SAMPLE_RATE,
                channels=CHANNELS,
                dtype="int16",
                callback=self._audio_callback,
            )
            self.audio_stream.start()
        except Exception as exc:  # noqa: BLE001
            self.audio_stream = None
            self.started_at = None
            self._refresh_menu_state(f"Mic error: {exc}")
            rumps.notification("Indic Dictation", "Microphone error", str(exc))
            return

        mode = "Locked recording" if locked else "Recording"
        target_name = self.target_app.name if self.target_app else "unknown target"
        self.indicator.show_recording()
        self._refresh_menu_state(f"{mode} into {target_name}")

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

        self.indicator.show_processing()
        self._refresh_menu_state("Translating...")
        worker = threading.Thread(target=self.process_audio, args=(audio_path, duration), daemon=True)
        worker.start()

    def process_audio(self, audio_path: Path, duration: float) -> None:
        try:
            started = time.perf_counter()
            english = translate_to_english(audio_path)
            latency = time.perf_counter() - started
            english_text = english.get("transcript", "").strip()

            result = {
                "mode": "menubar",
                "audio_path": str(audio_path),
                "duration_seconds": round(duration, 2),
                "sarvam_latency_seconds": round(latency, 2),
                "sarvam_request_count": english.get("chunk_count", 1),
                "english": english,
            }
            result_path = data_path("outputs", f"{audio_path.stem}.json")
            write_json(result_path, result)

            self.latest_english = english_text
            pyperclip.copy(english_text)
            if english_text and self.target_app is not None:
                paste_text_to_app(english_text, self.target_app)
                self._refresh_menu_state(f"Pasted. {latency:.1f}s")
            elif english_text:
                self._refresh_menu_state(f"Copied. {latency:.1f}s")
            else:
                self._refresh_menu_state("Empty result")
            self.indicator.hide()
        except (SarvamError, PasteError) as exc:
            self.indicator.hide()
            self._refresh_menu_state("Error")
            rumps.notification("Indic Dictation", "Dictation error", str(exc))
        except Exception as exc:  # noqa: BLE001
            self.indicator.hide()
            self._refresh_menu_state("Error")
            rumps.notification("Indic Dictation", "Unexpected error", str(exc))

    def _audio_callback(self, indata, frames, time_info, status) -> None:  # noqa: ANN001
        self.audio_queue.put(bytes(indata))

    def _refresh_menu_state(self, status: str) -> None:
        self.status_item.title = f"Status: {status}"
        self.hotkey_item.state = 1 if self.hotkey_enabled else 0
        for shortcut, item in self.shortcut_items.items():
            item.state = 1 if shortcut == self.selected_shortcut else 0


def main() -> int:
    app = IndicDictationMenuBar()
    app.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
