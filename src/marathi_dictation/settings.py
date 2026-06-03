from __future__ import annotations

import json
from pathlib import Path


RIGHT_COMMAND_KEY_CODE = 54
RIGHT_OPTION_KEY_CODE = 61
LEFT_COMMAND_KEY_CODE = 55
LEFT_OPTION_KEY_CODE = 58
RIGHT_SHIFT_KEY_CODE = 60
LEFT_SHIFT_KEY_CODE = 56
RIGHT_CONTROL_KEY_CODE = 62
LEFT_CONTROL_KEY_CODE = 59

MODIFIER_KEY_CODES = {
    "Command": (RIGHT_COMMAND_KEY_CODE, LEFT_COMMAND_KEY_CODE),
    "Option": (RIGHT_OPTION_KEY_CODE, LEFT_OPTION_KEY_CODE),
    "Shift": (RIGHT_SHIFT_KEY_CODE, LEFT_SHIFT_KEY_CODE),
    "Control": (RIGHT_CONTROL_KEY_CODE, LEFT_CONTROL_KEY_CODE),
}
SHORTCUT_PRESETS = {
    "Command + Option": ("Command", "Option"),
    "Command + Shift": ("Command", "Shift"),
    "Option + Shift": ("Option", "Shift"),
    "Command + Control": ("Command", "Control"),
    "Control + Option": ("Control", "Option"),
}
DEFAULT_SHORTCUT = "Command + Option"
SETTINGS_PATH = Path.home() / ".config" / "indic-dictation" / "settings.json"


def load_shortcut() -> str:
    try:
        data = json.loads(SETTINGS_PATH.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return DEFAULT_SHORTCUT
    shortcut = data.get("shortcut", DEFAULT_SHORTCUT)
    return shortcut if shortcut in SHORTCUT_PRESETS else DEFAULT_SHORTCUT


def save_shortcut(shortcut: str) -> None:
    SETTINGS_PATH.parent.mkdir(parents=True, exist_ok=True)
    SETTINGS_PATH.write_text(
        json.dumps({"shortcut": shortcut}, indent=2) + "\n",
        encoding="utf-8",
    )
