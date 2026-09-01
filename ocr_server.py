#!/usr/bin/env python3
"""Local baidu/Unlimited-OCR (MLX). GET /health  POST /ocr  {"image": "<jpeg-base64>"}"""

import base64
import json
import os
import re
import tempfile
from http.server import BaseHTTPRequestHandler, HTTPServer
from io import BytesIO

from PIL import Image

MODEL = os.environ.get("OCR_MODEL", "mlx-community/Unlimited-OCR-8bit")
PORT = int(os.environ.get("OCR_PORT", "8766"))
DET_RE = re.compile(r"<\|det\|>([^<\s]+)(?:\s*\[[^\]]*\])?\s*<\|/det\|>(.*)", re.DOTALL)

print("loading baidu/Unlimited-OCR …", flush=True)
from mlx_vlm import load, stream_generate
from mlx_vlm.prompt_utils import apply_chat_template

model, processor = load(MODEL)
config = getattr(model, "config", None)
print("ready", flush=True)


def clean(raw: str) -> str:
    text = raw.replace("<PAGE>", "\n\n")
    text = re.sub(r"<\|det\|>.*?<\|/det\|>", " ", text, flags=re.DOTALL)
    text = re.sub(r"<[^>]+>", " ", text)
    text = text.replace("&#x27;", "'").replace("&amp;", "&").replace("&quot;", '"')
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return cut_repeats(text).strip()


def pages(jpeg: bytes) -> list[Image.Image]:
    im = Image.open(BytesIO(jpeg)).convert("RGB")
    w, h = im.size
    if w > h * 1.35:
        mid = w // 2
        return [im.crop((0, 0, mid, h)), im.crop((mid, 0, w, h))]
    return [im]


def cut_repeats(text: str) -> str:
    words = text.split()
    out, i = [], 0
    while i < len(words):
        hit = False
        for n in range(min(40, (len(words) - i) // 3), 0, -1):
            unit = words[i : i + n]
            j, reps = i + n, 1
            while j + n <= len(words) and words[j : j + n] == unit:
                reps += 1
                j += n
            if reps >= 3:
                out.extend(unit)
                i = j
                hit = True
                break
        if not hit:
            out.append(words[i])
            i += 1
    return " ".join(out)


def looping_tokens(toks, n=12):
    if len(toks) < n * 3:
        return False
    unit = toks[-n:]
    return toks[-2 * n : -n] == unit and toks[-3 * n : -2 * n] == unit


def ocr_page(im: Image.Image) -> str:
    fd, path = tempfile.mkstemp(suffix=".jpg")
    os.close(fd)
    try:
        im.save(path, "JPEG", quality=92)
        prompt = apply_chat_template(processor, config, "document parsing.", num_images=1)
        acc, toks = "", []
        for chunk in stream_generate(
            model,
            processor,
            prompt,
            image=[path],
            max_tokens=3072,
            temperature=0,
            repetition_penalty=1.25,
            repetition_context_size=256,
        ):
            acc += chunk.text or ""
            if chunk.token is not None:
                toks.append(chunk.token)
            if looping_tokens(toks):
                break
        return clean(acc)
    finally:
        os.unlink(path)


def ocr(jpeg: bytes) -> str:
    parts = [ocr_page(im) for im in pages(jpeg)]
    return "\n\n".join(p for p in parts if p)


class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(fmt % args, flush=True)

    def send_json(self, code, obj):
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path == "/health":
            self.send_json(200, {"ok": True, "model": "baidu/Unlimited-OCR"})
            return
        self.send_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/ocr":
            self.send_json(404, {"error": "not found"})
            return
        n = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(n))
        try:
            text = ocr(base64.b64decode(body["image"]))
            self.send_json(200, {"text": text})
        except Exception as e:
            print("ocr failed:", e, flush=True)
            self.send_json(500, {"error": str(e)})


if __name__ == "__main__":
    print(f"Unlimited-OCR on http://127.0.0.1:{PORT}", flush=True)
    HTTPServer(("127.0.0.1", PORT), H).serve_forever()
