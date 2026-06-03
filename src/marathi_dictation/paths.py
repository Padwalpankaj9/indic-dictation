from __future__ import annotations

import os
from pathlib import Path


APP_NAME = "Marathi Dictation"
PACKAGE_ROOT = Path(__file__).resolve().parent
PROJECT_ROOT = PACKAGE_ROOT.parents[1]
RESOURCE_ROOT = Path(os.environ.get("RESOURCEPATH", PROJECT_ROOT))
DATA_ROOT = Path.home() / "Library" / "Application Support" / APP_NAME


def resource_path(*parts: str) -> Path:
    return RESOURCE_ROOT.joinpath(*parts)


def data_path(*parts: str) -> Path:
    path = DATA_ROOT.joinpath(*parts)
    path.parent.mkdir(parents=True, exist_ok=True)
    return path
