# Image to Text

Mac app that turns PDF, PNG, and JPG into text using [baidu/Unlimited-OCR](https://huggingface.co/baidu/Unlimited-OCR) on Apple Silicon (MLX).

## Run

```bash
bash scripts/install.sh
.venv/bin/python app.py
```

Open http://127.0.0.1:8766, drop a PDF, PNG, or JPG, then convert. History downloads stay on this computer.

Convert from the terminal:

```bash
.venv/bin/python app.py photo.png notes.pdf
```

On a Mac you can also open the menu-bar app after install:

```bash
open "Image to Text.app"
```

Apple Silicon uses the 8-bit model. Other computers use the 4-bit model so it fits in memory. Set `OCR_MODEL` to override. A page can take several minutes on CPU.

Drop files, convert, then download from History. Rebuild after editing `App.swift`:

```bash
swiftc -parse-as-library -O -target arm64-apple-macosx14.0 \
  -sdk "$(xcrun --show-sdk-path)" \
  -framework SwiftUI -framework AppKit -framework PDFKit \
  -o "Image to Text.app/Contents/MacOS/Image to Text" App.swift
codesign --force --deep -s - "Image to Text.app"
```
