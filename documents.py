"""Turn an uploaded PDF, PNG, or JPG into JPEG pages for OCR."""

from io import BytesIO
from pathlib import Path

from PIL import Image

MAX_SIDE = 1600


def to_jpegs(name: str, data: bytes) -> list[bytes]:
    ext = Path(name).suffix.lower()
    if ext == ".pdf" or data.startswith(b"%PDF"):
        return pdf_to_jpegs(data)
    return [image_to_jpeg(data)]


def image_to_jpeg(data: bytes) -> bytes:
    im = Image.open(BytesIO(data)).convert("RGB")
    im = fit(im)
    buf = BytesIO()
    im.save(buf, "JPEG", quality=90)
    return buf.getvalue()


def pdf_to_jpegs(data: bytes) -> list[bytes]:
    import pypdfium2 as pdfium

    pdf = pdfium.PdfDocument(data)
    pages: list[bytes] = []
    try:
        for i in range(len(pdf)):
            page = pdf[i]
            scale = MAX_SIDE / max(page.get_width(), 1)
            bitmap = page.render(scale=scale)
            try:
                pil = bitmap.to_pil().convert("RGB")
            finally:
                bitmap.close()
            pil = fit(pil)
            buf = BytesIO()
            pil.save(buf, "JPEG", quality=90)
            pages.append(buf.getvalue())
            page.close()
    finally:
        pdf.close()
    if not pages:
        raise ValueError("PDF has no pages")
    return pages


def fit(im: Image.Image, longest: int = MAX_SIDE) -> Image.Image:
    w, h = im.size
    side = max(w, h)
    if side <= longest:
        return im
    scale = longest / side
    return im.resize((max(1, int(w * scale)), max(1, int(h * scale))), Image.Resampling.LANCZOS)
