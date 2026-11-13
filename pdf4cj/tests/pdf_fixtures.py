"""Reusable generators for small, purpose-built test PDFs.

Every ``make_*`` helper writes a PDF to the given path and returns that path as
a ``str`` (``PdfExtractor`` takes a path string). Nothing here depends on pytest,
so the helpers are importable from tests, scratch scripts or later workers.

This is the copy that ships with the ``pdf4cj`` library: ``generate_fixtures.py``
in this same directory imports it, so the committed corpus can be rebuilt with
nothing but ``tests/requirements.txt`` installed.

The fixtures are deliberately tiny and hand-written where reportlab would add
noise (no-font documents, non-zero MediaBox origins, raw image streams): each
one pins exactly one behaviour of the extractor.
"""

from __future__ import annotations

from io import BytesIO
from pathlib import Path
from typing import Optional, Union

from PIL import Image
from reportlab.lib.pagesizes import letter
from reportlab.pdfgen import canvas as rl_canvas

PathLike = Union[str, Path]

__all__ = [
    'make_text_pdf',
    'make_multipage_pdf',
    'make_table_pdf',
    'make_image_pdf',
    'make_styled_multipage_pdf',
    'make_blank_pdf',
    'make_zero_page_pdf',
    'make_mediabox_text_pdf',
    'make_single_image_pdf',
    'image_bytes',
]


def _write_pdf(path: PathLike, objects: list[bytes]) -> str:
    """Assemble a minimal PDF from numbered object bodies (1-based) and write it."""
    path = Path(path)
    out = bytearray(b'%PDF-1.4\n')
    offsets: list[int] = []
    for number, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += f'{number} 0 obj\n'.encode('ascii') + body + b'\nendobj\n'
    xref_position = len(out)
    out += f'xref\n0 {len(objects) + 1}\n'.encode('ascii')
    out += b'0000000000 65535 f \n'
    for offset in offsets:
        out += f'{offset:010d} 00000 n \n'.encode('ascii')
    out += (
        f'trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\n'
        f'startxref\n{xref_position}\n%%EOF\n'
    ).encode('ascii')
    path.write_bytes(bytes(out))
    return str(path)


# --- reportlab-generated documents -----------------------------------------


def make_text_pdf(path: PathLike, text: str = 'alphaword') -> str:
    """One US-Letter page containing ``text`` in Helvetica 12 at (72, 700)."""
    path = Path(path)
    c = rl_canvas.Canvas(str(path), pagesize=letter)
    c.setFont('Helvetica', 12)
    c.drawString(72, 700, text)
    c.showPage()
    c.save()
    return str(path)


def make_multipage_pdf(path: PathLike, page_count: int = 3) -> str:
    """``page_count`` pages, each with distinct text and a distinct font size."""
    path = Path(path)
    c = rl_canvas.Canvas(str(path), pagesize=letter)
    for page_num in range(1, page_count + 1):
        c.setFont('Helvetica', 10 + page_num)
        c.drawString(72, 700, f'page {page_num} content')
        c.showPage()
    c.save()
    return str(path)


def make_table_pdf(path: PathLike) -> str:
    """One page with a 2x2 ruled grid; the bottom-left cell is left empty.

    The empty cell is the point: pdfplumber reports it as ``None`` in
    ``table.extract()`` and the extractor must turn that into ``''``.
    """
    path = Path(path)
    c = rl_canvas.Canvas(str(path), pagesize=letter)
    c.rect(50, 650, 300, 80)
    c.line(200, 650, 200, 730)
    c.line(50, 690, 350, 690)
    c.setFont('Helvetica', 10)
    c.drawString(60, 700, 'Header A')
    c.drawString(210, 700, 'Header B')
    c.drawString(210, 660, 'Row B1')
    c.showPage()
    c.save()
    return str(path)


def make_image_pdf(path: PathLike) -> str:
    """One page with a single embedded PNG XObject drawn at (50, 50)."""
    path = Path(path)
    png_path = path.with_name(f'{path.stem}-embed.png')
    png_path.write_bytes(image_bytes('PNG'))

    c = rl_canvas.Canvas(str(path), pagesize=letter)
    c.drawImage(str(png_path), 50, 50, width=100, height=100, mask=None)
    c.showPage()
    c.save()
    return str(path)


def make_styled_multipage_pdf(path: PathLike) -> str:
    """Three pages with a different font/size/color mix per page.

    page 1: Helvetica 10 red "alpha" (5 chars), Helvetica 14 blue "beta" (4)
    page 2: Helvetica 10 blue "gamma" (5)
    page 3: Courier 12 green "delta" (5)

    Text is *stroked* so pdfplumber reports a per-call ``stroking_color``;
    filled text always reports the same color and would make ``colors``
    assertions meaningless.
    """
    path = Path(path)
    c = rl_canvas.Canvas(str(path), pagesize=letter)
    _draw_outlined(c, 50, 700, 'alpha', 'Helvetica', 10, (1, 0, 0))
    _draw_outlined(c, 50, 650, 'beta', 'Helvetica', 14, (0, 0, 1))
    c.showPage()
    _draw_outlined(c, 50, 700, 'gamma', 'Helvetica', 10, (0, 0, 1))
    c.showPage()
    _draw_outlined(c, 50, 700, 'delta', 'Courier', 12, (0, 0.5, 0))
    c.showPage()
    c.save()
    return str(path)


def _draw_outlined(c, x, y, text, font, size, rgb) -> None:
    """Draw stroke-only text so its ``stroking_color`` is observable."""
    c.setStrokeColorRGB(*rgb)
    text_obj = c.beginText(x, y)
    text_obj.setTextRenderMode(1)  # stroke-only text -> stroke color applies
    text_obj.setFont(font, size)
    text_obj.textLine(text)
    c.drawText(text_obj)


# --- hand-written documents -------------------------------------------------


def make_blank_pdf(path: PathLike) -> str:
    """A one-page PDF with no /Font resources at all (reportlab always adds one)."""
    return _write_pdf(path, [
        b'<< /Type /Catalog /Pages 2 0 R >>',
        b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>',
        b'<< /Length 0 >>\nstream\n\nendstream',
    ])


def make_zero_page_pdf(path: PathLike) -> str:
    """A PDF with a genuinely empty page tree (reportlab cannot produce one)."""
    return _write_pdf(path, [
        b'<< /Type /Catalog /Pages 2 0 R >>',
        b'<< /Type /Pages /Kids [] /Count 0 >>',
    ])


def make_mediabox_text_pdf(
    path: PathLike,
    mediabox: bytes = b'[0 0 612 792]',
    text: str = 'mediaboxword',
    baseline: int = 520,
) -> str:
    """One page with the given MediaBox and a single Helvetica text run.

    ``baseline`` is interpreted in the MediaBox' own coordinate system, so a page
    whose origin is not (0, 0) needs a shifted baseline to place the glyph at the
    same visual spot.
    """
    content = b'BT /F1 12 Tf 72 %d Td (%s) Tj ET' % (baseline, text.encode('ascii'))
    return _write_pdf(path, [
        b'<< /Type /Catalog /Pages 2 0 R >>',
        b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        b'<< /Type /Page /Parent 2 0 R /MediaBox ' + mediabox
        + b' /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
        b'<< /Length %d >>\nstream\n' % len(content) + content + b'\nendstream',
        b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    ])


def make_single_image_pdf(
    path: PathLike,
    data: bytes,
    pdf_filter: str = 'DCTDecode',
    size: int = 4,
) -> str:
    """One page whose only XObject is ``data``, stored under ``pdf_filter``.

    The bytes are written verbatim, so the extractor sees exactly what an encoder
    produced (e.g. a JPEG for DCTDecode, a JPEG2000 codestream for JPXDecode).
    """
    content = b'q 100 0 0 100 50 50 cm /Im0 Do Q'
    return _write_pdf(path, [
        b'<< /Type /Catalog /Pages 2 0 R >>',
        b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] '
        b'/Resources << /XObject << /Im0 5 0 R >> >> /Contents 4 0 R >>',
        b'<< /Length %d >>\nstream\n' % len(content) + content + b'\nendstream',
        b'<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceRGB '
        % (size, size)
        + b'/BitsPerComponent 8 /Filter /' + pdf_filter.encode('ascii')
        + b' /Length %d >>\nstream\n' % len(data) + data + b'\nendstream',
    ])


# --- raw image encodings ---------------------------------------------------


def image_bytes(fmt: str = 'PNG', size: tuple[int, int] = (4, 4)) -> bytes:
    """Encode a small solid image with Pillow in ``fmt`` (PNG/JPEG/BMP/...)."""
    buffer = BytesIO()
    Image.new('RGB', size, (200, 30, 30)).save(buffer, format=fmt)
    return buffer.getvalue()


def image_bytes_or_none(fmt: str) -> Optional[bytes]:
    """``image_bytes`` but ``None`` when this Pillow build lacks the codec."""
    try:
        return image_bytes(fmt)
    except OSError:
        return None
