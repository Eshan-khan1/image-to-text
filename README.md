# Image to Text

Mac app that turns PDF, PNG, and JPG into text using [baidu/Unlimited-OCR](https://huggingface.co/baidu/Unlimited-OCR) on Apple Silicon (MLX).

## Run

```bash
uv venv .venv --python 3.12
uv pip install -U "mlx-vlm>=0.6.8" jinja2 --python .venv/bin/python
open "Image to Text.app"
```

Drop files, convert, then download from History. Rebuild after editing `App.swift`:

```bash
swiftc -parse-as-library -O -target arm64-apple-macosx14.0 \
  -sdk "$(xcrun --show-sdk-path)" \
  -framework SwiftUI -framework AppKit -framework PDFKit \
  -o "Image to Text.app/Contents/MacOS/Image to Text" App.swift
codesign --force --deep -s - "Image to Text.app"
```
