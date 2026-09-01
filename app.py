#!/usr/bin/env python3
"""CLI for baidu/Unlimited-OCR. python3 app.py photo.png  (server must be running, or the app starts it)."""

import base64
import json
import sys
import urllib.request
from pathlib import Path

OCR = "http://127.0.0.1:8766"


def convert(path):
    img = base64.b64encode(Path(path).read_bytes()).decode()
    req = urllib.request.Request(
        OCR + "/ocr",
        data=json.dumps({"image": img}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=600) as res:
        return json.load(res)["text"]


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: python3 app.py photo.png")
    print(convert(sys.argv[1]))
