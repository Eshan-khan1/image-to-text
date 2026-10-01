#!/usr/bin/env python3
"""Local baidu/Unlimited-OCR (MLX).

GET  /health
GET  /
POST /ocr   {"image": "<jpeg-base64>"}
POST /file  {"name": "scan.pdf", "data": "<file-base64>"}
"""

import base64
import json
import os
import re
import sys
import tempfile
import threading
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from io import BytesIO
from pathlib import Path
from urllib.parse import unquote

from PIL import Image

from documents import fit, to_jpegs

ROOT = Path(__file__).resolve().parent
PAGE = (ROOT / "web" / "index.html").read_text(encoding="utf-8")
PORT = int(os.environ.get("OCR_PORT", "8766"))

model = None
processor = None
config = None
ready = False
load_error = None


def default_model() -> str:
    chosen = os.environ.get("OCR_MODEL")
    if chosen:
        return chosen
    try:
        import mlx.core as mx

        if mx.metal.is_available():
            return "mlx-community/Unlimited-OCR-8bit"
    except Exception:
        pass
    return "mlx-community/Unlimited-OCR-4bit"


MODEL = default_model()
OCR_LOCK = threading.Lock()


def load_model() -> None:
    global model, processor, config, ready, load_error
    print(f"loading {MODEL} …", flush=True)
    try:
        from mlx_vlm import load

        model, processor = load(MODEL)
        config = getattr(model, "config", None)
        ready = True
        print("ready", flush=True)
    except Exception as exc:
        load_error = str(exc)
        print("load failed:", exc, flush=True)


def history_dir() -> Path:
    if sys.platform == "darwin":
        base = Path.home() / "Library/Application Support/Image to Text/History"
    else:
        base = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share"))
        base = base / "image-to-text" / "history"
    base.mkdir(parents=True, exist_ok=True)
    return base


def slug(text: str) -> str:
    line = text.splitlines()[0] if text.splitlines() else ""
    out = []
    dash = False
    for ch in line.lower():
        if ch.isalnum():
            out.append(ch)
            dash = False
        elif out and not dash:
            out.append("-")
            dash = True
        if len(out) >= 40:
            break
    return "".join(out).strip("-")


def save_history(text: str, source_name: str) -> str:
    stamp = datetime.now().strftime("%Y-%m-%d-%H%M")
    stem = slug(text) or Path(source_name).stem or "untitled"
    name = f"{stamp}_{stem}.txt"
    path = history_dir() / name
    n = 2
    while path.exists():
        path = history_dir() / f"{stamp}_{stem}-{n}.txt"
        n += 1
    path.write_text(text, encoding="utf-8")
    return path.name


def clean(raw: str) -> str:
    text = raw.replace("<PAGE>", "\n\n")
    text = re.sub(r"<\|det\|>.*?<\|/det\|>", " ", text, flags=re.DOTALL)
    text = re.sub(r"<[^>]+>", " ", text)
    text = text.replace("&#x27;", "'").replace("&amp;", "&").replace("&quot;", '"')
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return cut_repeats(text).strip()


def pages(jpeg: bytes) -> list[Image.Image]:
    im = fit(Image.open(BytesIO(jpeg)).convert("RGB"))
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
    from mlx_vlm import stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template

    fd, path = tempfile.mkstemp(suffix=".jpg")
    os.close(fd)
    try:
        im.save(path, "JPEG", quality=92)
        prompt = apply_chat_template(processor, config, "document parsing.", num_images=1)
        print("reading page…", flush=True)
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
    with OCR_LOCK:
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

    def send_bytes(self, code, raw, content_type, filename=None):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(raw)))
        if filename:
            self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/health":
            if ready:
                self.send_json(200, {"ok": True, "model": MODEL})
            else:
                self.send_json(503, {"ok": False, "error": load_error or "loading"})
            return
        if path in ("/", "/index.html"):
            raw = PAGE.encode()
            self.send_bytes(200, raw, "text/html; charset=utf-8")
            return
        if path == "/history":
            files = sorted(history_dir().glob("*.txt"), key=lambda p: p.stat().st_mtime, reverse=True)
            self.send_json(200, {"files": [{"name": p.name} for p in files]})
            return
        if path.startswith("/history/"):
            name = Path(unquote(path[len("/history/") :])).name
            target = history_dir() / name
            if not name.endswith(".txt") or not target.is_file():
                self.send_json(404, {"error": "not found"})
                return
            self.send_bytes(200, target.read_bytes(), "text/plain; charset=utf-8", name)
            return
        self.send_json(404, {"error": "not found"})

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path not in ("/ocr", "/file"):
            self.send_json(404, {"error": "not found"})
            return
        if not ready:
            self.send_json(503, {"error": load_error or "Unlimited-OCR is still loading"})
            return
        n = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(n) or b"{}")
        try:
            if path == "/ocr":
                text = ocr(base64.b64decode(body["image"]))
                self.send_json(200, {"text": text})
                return
            name = str(body.get("name") or "upload")
            data = base64.b64decode(body["data"])
            parts = [ocr(jpeg) for jpeg in to_jpegs(name, data)]
            text = "\n\n".join(p for p in parts if p)
            saved = save_history(text, name)
            self.send_json(200, {"text": text, "file": saved})
        except (BrokenPipeError, ConnectionError):
            print("client disconnected", flush=True)
        except Exception as e:
            print("ocr failed:", e, flush=True)
            try:
                self.send_json(500, {"error": str(e)})
            except (BrokenPipeError, ConnectionError):
                print("client disconnected", flush=True)


if __name__ == "__main__":
    threading.Thread(target=load_model, daemon=True).start()
    print(f"Unlimited-OCR on http://127.0.0.1:{PORT}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
