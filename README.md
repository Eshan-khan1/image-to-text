# Image to Text

Mac app that turns PDF, PNG, and JPG into text using [baidu/Unlimited-OCR](https://huggingface.co/baidu/Unlimited-OCR) on Apple Silicon (MLX).

## Run

On a Mac, install and open the app window:

```bash
bash scripts/install.sh
swiftc -O -target arm64-apple-macosx14.0 \
  -sdk "$(xcrun --show-sdk-path)" \
  -framework AppKit -framework WebKit \
  -o "Image to Text.app/Contents/MacOS/Image to Text" App.swift
codesign --force --deep -s - "Image to Text.app"
open "Image to Text.app"
```

The app starts Unlimited-OCR and opens a Mac window. Drop a PDF, PNG, or JPG, then convert. History stays on this computer.

The same window is available in a browser while you work on the page:

```bash
.venv/bin/python app.py
```

Open http://127.0.0.1:8766. Convert from the terminal with `.venv/bin/python app.py photo.png notes.pdf`.

Apple Silicon uses the 8-bit model. Other computers use the 4-bit model so it fits in memory. Set `OCR_MODEL` to override. A page can take several minutes on CPU.
