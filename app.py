#!/usr/bin/env python3
"""Image to Text.

Open the local app:
    python3 app.py

Convert files in the terminal:
    python3 app.py photo.png notes.pdf
"""

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent
OCR = "http://127.0.0.1:8766"
ALLOWED = {".pdf", ".png", ".jpg", ".jpeg"}


def healthy() -> bool:
    try:
        with urllib.request.urlopen(OCR + "/health", timeout=2) as res:
            return res.status == 200
    except Exception:
        return False


def python_bin() -> str:
    venv = ROOT / ".venv" / ("Scripts/python.exe" if sys.platform == "win32" else "bin/python")
    if venv.is_file():
        return str(venv)
    return sys.executable


def ensure_server() -> None:
    if healthy():
        return
    subprocess.Popen(
        [python_bin(), str(ROOT / "ocr_server.py")],
        cwd=ROOT,
        stdout=sys.stdout,
        stderr=sys.stderr,
    )
    for _ in range(600):
        if healthy():
            return
        time.sleep(1)
    raise SystemExit("Could not start Unlimited-OCR. Check the log above.")


def convert(path: Path) -> str:
    import base64

    req = urllib.request.Request(
        OCR + "/file",
        data=json.dumps({"name": path.name, "data": base64.b64encode(path.read_bytes()).decode()}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=600) as res:
            return json.load(res)["text"]
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        raise SystemExit(f"{path.name}: {detail}") from exc


def main() -> None:
    args = sys.argv[1:]
    if not args:
        print(f"Open {OCR}", flush=True)
        os_exec = python_bin()
        os.execv(os_exec, [os_exec, str(ROOT / "ocr_server.py")])
    bad = [p for p in args if Path(p).suffix.lower() not in ALLOWED]
    if bad:
        raise SystemExit("Use PDF, PNG, or JPG. Rejected: " + ", ".join(bad))
    ensure_server()
    for raw in args:
        path = Path(raw)
        if not path.is_file():
            raise SystemExit(f"No such file: {path}")
        print(f"=== {path.name} ===")
        print(convert(path))
        print()


if __name__ == "__main__":
    main()
