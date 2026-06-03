from __future__ import annotations

from collections.abc import Callable


HOLD_START_SECONDS = 0.25
DOUBLE_TAP_SECONDS = 0.60


class ShortcutMode:
    IDLE = "idle"
    HOLD_RECORDING = "hold_recording"
    LOCKED_RECORDING = "locked_recording"


class ShortcutStateMachine:
    def __init__(
        self,
        start_recording: Callable[[bool], None],
        stop_recording: Callable[[], None],
        status_changed: Callable[[str], None] | None = None,
    ) -> None:
        self.start_recording = start_recording
        self.stop_recording = stop_recording
        self.status_changed = status_changed
        self.mode = ShortcutMode.IDLE
        self.was_pressed = False
        self.press_started_at: float | None = None
        self.first_tap_at: float | None = None
        self.tap_count = 0

    def reset(self) -> None:
        if self.mode in {ShortcutMode.HOLD_RECORDING, ShortcutMode.LOCKED_RECORDING}:
            self.stop_recording()
        self.mode = ShortcutMode.IDLE
        self.was_pressed = False
        self.press_started_at = None
        self.first_tap_at = None
        self.tap_count = 0
        self._emit("Ready")

    def update(self, is_pressed: bool, now: float) -> None:
        if self.first_tap_at is not None and now - self.first_tap_at > DOUBLE_TAP_SECONDS:
            self.first_tap_at = None
            self.tap_count = 0

        if is_pressed and not self.was_pressed:
            self._on_press(now)
        elif not is_pressed and self.was_pressed:
            self._on_release(now)
        elif is_pressed and self.mode == ShortcutMode.IDLE and self.press_started_at is not None:
            if now - self.press_started_at >= HOLD_START_SECONDS:
                self._start_hold_recording()

        self.was_pressed = is_pressed

    def _on_press(self, now: float) -> None:
        self.press_started_at = now
        if self.mode == ShortcutMode.LOCKED_RECORDING:
            self._emit("Locked recording. Release shortcut to stop.")
        else:
            self._emit("Shortcut pressed")

    def _on_release(self, now: float) -> None:
        if self.mode == ShortcutMode.HOLD_RECORDING:
            self.mode = ShortcutMode.IDLE
            self.stop_recording()
            self._clear_taps()
            self._emit("Translating...")
            return

        if self.mode == ShortcutMode.LOCKED_RECORDING:
            self.mode = ShortcutMode.IDLE
            self.stop_recording()
            self._clear_taps()
            self._emit("Translating...")
            return

        self._register_tap(now)

    def _register_tap(self, now: float) -> None:
        if self.first_tap_at is None or now - self.first_tap_at > DOUBLE_TAP_SECONDS:
            self.first_tap_at = now
            self.tap_count = 1
            self._emit("Tap once more to lock recording")
            return

        self.tap_count += 1
        if self.tap_count >= 2:
            self._clear_taps()
            self.mode = ShortcutMode.LOCKED_RECORDING
            self.start_recording(True)
            self._emit("Locked recording. Tap shortcut once to stop.")

    def _start_hold_recording(self) -> None:
        self.mode = ShortcutMode.HOLD_RECORDING
        self._clear_taps()
        self.start_recording(False)
        self._emit("Hold recording. Release shortcut to stop.")

    def _clear_taps(self) -> None:
        self.first_tap_at = None
        self.tap_count = 0
        self.press_started_at = None

    def _emit(self, status: str) -> None:
        if self.status_changed is not None:
            self.status_changed(status)
