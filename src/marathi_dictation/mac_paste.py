from __future__ import annotations

import subprocess
import time
from dataclasses import dataclass

import pyperclip


@dataclass
class TargetApp:
    name: str
    bundle_id: str


class PasteError(RuntimeError):
    pass


def capture_frontmost_app() -> TargetApp:
    script = """
    tell application "System Events"
        set frontProc to first application process whose frontmost is true
        set appName to name of frontProc
        set appBundle to bundle identifier of frontProc
    end tell
    return appName & linefeed & appBundle
    """
    result = _run_osascript(script)
    lines = [line.strip() for line in result.splitlines() if line.strip()]
    if len(lines) < 2:
        raise PasteError(f"Could not identify frontmost app: {result!r}")
    return TargetApp(name=lines[0], bundle_id=lines[1])


def paste_text_to_app(text: str, target: TargetApp, restore_clipboard: bool = True) -> None:
    if not text.strip():
        raise PasteError("No English text is available to paste.")

    previous_clipboard = pyperclip.paste() if restore_clipboard else ""
    pyperclip.copy(text)

    script = f"""
    tell application id "{_escape_applescript(target.bundle_id)}" to activate
    delay 0.2
    tell application "System Events"
        keystroke "v" using command down
    end tell
    """
    try:
        _run_osascript(script)
        time.sleep(0.3)
    finally:
        if restore_clipboard:
            pyperclip.copy(previous_clipboard)


def _run_osascript(script: str) -> str:
    result = subprocess.run(
        ["osascript", "-e", script],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        error = result.stderr.strip() or result.stdout.strip()
        raise PasteError(error or "AppleScript command failed.")
    return result.stdout.strip()


def _escape_applescript(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')
