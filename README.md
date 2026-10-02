# U Converter

Mac app that converts files on your computer: PDF, Word, images, video, and audio, plus QR codes. Its Image to Text tool turns a PDF, PNG, or JPG into text with [baidu/Unlimited-OCR](https://huggingface.co/baidu/Unlimited-OCR). Files are not uploaded anywhere.

**Download:** [U Converter (zip)](https://github.com/Eshan-khan1/image-to-text/archive/refs/heads/main.zip)

Unzip that file, then follow [Open it on a Mac](#open-it-on-a-mac) below.

![U Converter window](docs/mac-window.png)

## What it does

- Reads PDF, PNG, and JPG files, including more than one file at a time.
- Shows the text in the window. You can download it as a `.txt` file.
- Keeps past conversions in History. Click a row to open it again.
- Runs the reader on this Mac. Apple Silicon uses a local MLX model. The text stays in History on this computer.

## Converter tools

The app opens on a home screen with one icon per conversion (PDF to Word, JPG to PNG, Video to MP3, and more). Click an icon, then drop files anywhere in the window or click to choose them. Each file converts right away and shows up as a card with **Open** and **Download** buttons; **Download all** saves several results as one zip. **‹ All Tools** goes back to the home screen. **Any Format** lets you pick a format per file.

| Group | Tools |
| --- | --- |
| PDF | PDF to Word, JPG, PNG, or Text · Merge · Split · Compress · Rotate · Protect with a password · Unlock |
| Documents | Word to PDF, CSV, or Text · DOC to DOCX · Text, Markdown, or HTML to PDF · Text to Word |
| Spreadsheets | Excel to CSV or JSON · CSV to Excel or JSON · JSON to CSV |
| Images | JPG, PNG, HEIC, WEBP, SVG between formats · Image to PDF (one or many) · Compress · Resize · Make Icon (.ico) · Remove Photo Info (location, camera) · Read QR Code |
| Video and audio | Video to MP3, M4A, MP4, or GIF · Audio to WAV · Compress Video · Mute Video |
| Everyday | Image to Text · QR Code maker · Unit Converter · Time Zones · Any Format |

A PDF with more than one page becomes a `.zip` of images. Video to GIF uses the first 20 seconds. Excel tools read the first sheet. Audio and video use [ffmpeg](https://ffmpeg.org) (`brew install ffmpeg`). Word, Excel, PowerPoint, HTML, and Markdown to PDF use [LibreOffice](https://www.libreoffice.org) (`brew install --cask libreoffice`) so headings, lists, tables, and pictures keep their layout; `scripts/install.sh` installs both.

## The window

The left side is the file list and History. The toolbar is Choose, Convert, Download, and Clear. The text appears on the right. The status line at the bottom tells you when the reader is ready, working, or finished.

Drop a file on the Files area, or click Choose. Then click Convert.

## What you need

| | |
| --- | --- |
| Computer | Apple Silicon Mac (M1 or newer) |
| System | macOS 14 or newer |
| First run | Python 3.12, an internet connection once to download the reader |

The first conversion can take several minutes while the model loads. Later pages are the same reader, already on the machine.

## Privacy

The window talks only to a server on this Mac at `127.0.0.1:8766`. History is saved under `~/Library/Application Support/Image to Text/History` on a Mac. There is no account and no project telemetry.

## Open it on a Mac

1. Download and unzip [U Converter (zip)](https://github.com/Eshan-khan1/image-to-text/archive/refs/heads/main.zip).
2. Open Terminal, go into the unzipped folder, and run:

```bash
bash scripts/install.sh
swiftc -O -target arm64-apple-macosx14.0 \
  -sdk "$(xcrun --show-sdk-path)" \
  -framework AppKit -framework WebKit \
  -o "U Converter.app/Contents/MacOS/U Converter" App.swift
codesign --force --deep -s - "U Converter.app"
open "U Converter.app"
```

The app starts the reader and opens the window. Xcode Command Line Tools must be installed so `swiftc` can build the window (`xcode-select --install`).

## Project page

Repository: https://github.com/Eshan-khan1/image-to-text

The same window is available in a browser from the project folder:

```bash
.venv/bin/python app.py
```

Then open http://127.0.0.1:8766.

From the terminal:

```bash
.venv/bin/python app.py photo.png notes.pdf
```

Apple Silicon uses the 8-bit model (`mlx-community/Unlimited-OCR-8bit`). Other computers use the 4-bit model so it fits in memory. Set `OCR_MODEL` to pick a different model. A page can take several minutes on a CPU.
