#!/usr/bin/env python3
"""Regenerate the committed PDF fixtures used by pdf4cj's tests.

Run it from the ``pdf4cj/`` directory with any Python that has reportlab and
Pillow installed (see ``tests/requirements.txt``):

    python3 tests/generate_fixtures.py

Everything is written to ``pdf4cj/tests/fixtures/``, right next to this script;
nothing outside this library is read or written. The script locates its own
directory, so it works from any working directory and from a standalone
``pdf4cj`` checkout.

The output is deterministic: reportlab runs with ``rl_config.invariant = 1``
(fixed document id, fixed dates), Pillow's PNG/JPEG encoders never add
timestamps, and the hand-written PDFs use fixed object numbers and no ``/ID``.
Regenerating on a clean tree therefore produces byte-identical files, which is
what makes the fixtures safe to commit.

Known environment dependency: ``image.pdf`` is the one exception. reportlab
names the image Form XObject ``FormXob.<md5>`` where the digest covers the
*path string* handed to ``Canvas.drawImage`` (``pdf_fixtures.make_image_pdf``
passes the ``image-embed.png`` sidecar path). The committed blob therefore
encodes the absolute path it was first generated at; regenerating from a
different directory changes only that resource name - the decoded pixels and
the rest of the PDF stay identical - and the file's sha256 changes. The
regenerated name is still stable run to run, so this is a cosmetic diff: the
content stream re-compresses to a length that differs by two bytes, which shifts
``/Length`` and every xref offset by the same amount. If you need bytes that
match the committed file exactly, keep the committed ``image.pdf`` instead of
regenerating it; the other fourteen files are byte-stable from any directory.

Two groups of fixtures exist:

* the ones built through ``tests/pdf_fixtures.py`` (the helper module shipped
  beside this script, so the corpus can be rebuilt without any other checkout);
* the "special" ones built here because those helpers do not cover them:
  ``jpeg.pdf`` (a real DCTDecode payload), ``quoted-table.pdf`` (a cell holding
  a quote and a newline), ``garbage.pdf``, ``encrypted.pdf``,
  ``corrupt-stream.pdf`` and the hand-assembled xref-stream/ObjStm documents.

``src/test/fixtures_test.cj`` asserts one observable fact per file here, so a
changed fixture fails a test instead of silently changing behaviour. Regenerate
deliberately, and commit the regenerated fixtures together with any test
expectation the change invalidates.
"""

from __future__ import annotations

import hashlib
import re
import struct
import sys
import zlib
from io import BytesIO
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
FIXTURES_DIR = TESTS_DIR / 'fixtures'

# Make reportlab deterministic *before* any canvas is created: fixed /ID and a
# fixed 1980-01-01 creation date instead of the current time.
import reportlab.rl_config

reportlab.rl_config.invariant = 1

if str(TESTS_DIR) not in sys.path:
    sys.path.insert(0, str(TESTS_DIR))

import pdf_fixtures  # noqa: E402  (needs the sys.path entry above)

from PIL import Image  # noqa: E402  (only for the image payloads)
from reportlab.lib import pdfencrypt  # noqa: E402
from reportlab.lib.pagesizes import letter  # noqa: E402
from reportlab.pdfgen import canvas as rl_canvas  # noqa: E402

#: Fixtures whose bytes must be reproducible run to run.
FIXTURE_NAMES = (
    'text.pdf',
    'multipage.pdf',
    'table.pdf',
    'image.pdf',
    'styled.pdf',
    'blank.pdf',
    'zero.pdf',
    'mediabox.pdf',
    'jpeg.pdf',
    'quoted-table.pdf',
    'garbage.pdf',
    'encrypted.pdf',
    'corrupt-stream.pdf',
    'xref-stream.pdf',
    'xref-stream-flate.pdf',
)


# --- fixtures built through tests/pdf_fixtures.py ---------------------------


def build_fixture_library() -> None:
    """The fixtures that ``tests/pdf_fixtures.py`` can produce."""

    pdf_fixtures.make_text_pdf(FIXTURES_DIR / 'text.pdf')
    pdf_fixtures.make_multipage_pdf(FIXTURES_DIR / 'multipage.pdf')
    pdf_fixtures.make_table_pdf(FIXTURES_DIR / 'table.pdf')
    pdf_fixtures.make_image_pdf(FIXTURES_DIR / 'image.pdf')
    pdf_fixtures.make_styled_multipage_pdf(FIXTURES_DIR / 'styled.pdf')
    pdf_fixtures.make_blank_pdf(FIXTURES_DIR / 'blank.pdf')
    pdf_fixtures.make_zero_page_pdf(FIXTURES_DIR / 'zero.pdf')
    # A MediaBox with a non-zero origin: pdfplumber's word coordinates have to
    # add the vertical origin back, which is the one place the two engines can
    # disagree without either being obviously wrong. Baseline 620 puts the text
    # at the same visual spot as text.pdf (700 - 100 ... 620 + 100).
    pdf_fixtures.make_mediabox_text_pdf(
        FIXTURES_DIR / 'mediabox.pdf',
        mediabox=b'[0 100 612 892]',
        baseline=620,
    )


# --- fixtures that need their own builders ---------------------------------


def jpeg_bytes() -> bytes:
    """A small, deterministic real JPEG (no EXIF, no thumbnail)."""
    buffer = BytesIO()
    Image.new('RGB', (4, 4), (200, 30, 30)).save(buffer, format='JPEG')
    return buffer.getvalue()


def build_jpeg() -> None:
    """One page whose only XObject is a verbatim JPEG under /DCTDecode."""
    pdf_fixtures.make_single_image_pdf(
        FIXTURES_DIR / 'jpeg.pdf', jpeg_bytes(), 'DCTDecode'
    )


def build_quoted_table() -> None:
    """A 2x2 ruled grid whose top-left cell is ``a,"b`` + LF + ``c``.

    Mirrors the fixture of the same purpose on the Python side: pdfplumber joins a
    cell's lines with ``\\n``, so the cell value carries both a quote and a
    newline, which is the worst case for CSV quoting.
    """
    path = FIXTURES_DIR / 'quoted-table.pdf'
    canvas = rl_canvas.Canvas(str(path), pagesize=letter)
    canvas.rect(50, 650, 300, 80)
    canvas.line(200, 650, 200, 730)
    canvas.line(50, 690, 350, 690)
    canvas.setFont('Helvetica', 10)
    canvas.drawString(60, 710, 'a,"b')
    canvas.drawString(60, 698, 'c')
    canvas.drawString(210, 700, 'plain')
    canvas.showPage()
    canvas.save()


def build_garbage() -> None:
    """A readable file that is not a PDF at all."""
    (FIXTURES_DIR / 'garbage.pdf').write_bytes(b'this file is not a PDF\n' * 8)


def build_encrypted() -> None:
    """One page encrypted with the user password ``userpw``.

    ``/ID`` and the encryption key come from reportlab's invariant mode, so the
    bytes are stable; the OpenSSL-derived key is a pure function of them.
    """
    path = FIXTURES_DIR / 'encrypted.pdf'
    encryption = pdfencrypt.StandardEncryption(
        'userpw', ownerPassword='ownerpw', canPrint=1
    )
    canvas = rl_canvas.Canvas(str(path), encrypt=encryption)
    canvas.setFont('Helvetica', 12)
    canvas.drawString(72, 700, 'encrypted content')
    canvas.showPage()
    canvas.save()


_STREAM_RE = re.compile(rb'stream\n(.*?)endstream', re.S)


def build_corrupt_stream() -> None:
    """A PDF whose structure reads but whose page content stream is garbage.

    Mirrors the fixture of the same purpose on the Python side: reportlab writes
    a normal compressed one-page document, then the content stream's payload is
    replaced byte for byte with ``0xFF`` (same length, so every xref offset and
    ``/Length`` stays valid). The document opens; interpreting page 1 fails.
    """
    path = FIXTURES_DIR / 'corrupt-stream.pdf'
    canvas = rl_canvas.Canvas(str(path), pagesize=letter, pageCompression=1)
    canvas.setFont('Helvetica', 12)
    canvas.drawString(72, 700, 'page 1 text')
    canvas.showPage()
    canvas.save()

    data = path.read_bytes()
    match = _STREAM_RE.search(data)
    if match is None:
        raise RuntimeError('the generated PDF has no content stream to corrupt')
    payload = match.group(1)
    path.write_bytes(data[: match.start(1)] + b'\xff' * len(payload) + data[match.end(1):])


def build_xref_stream() -> None:
    """A minimal PDF that uses an xref stream plus an object stream.

    Written by hand because reportlab only emits classic xref tables. The two
    variants cover the two shapes a producer may choose:

    * ``xref-stream.pdf`` - uncompressed ObjStm, uncompressed xref stream;
    * ``xref-stream-flate.pdf`` - FlateDecode ObjStm and a FlateDecode xref
      stream filtered with PNG "Up" predictor 12 (what most real producers emit).

    Objects: 4 (content stream) lives at a normal offset, 5 is the ObjStm that
    holds 1 (catalog), 2 (page tree), 3 (page) and 7 (font), 6 is the xref
    stream itself. No ``/ID`` and no dates, so the bytes never change.
    """
    content = b'BT /F1 12 Tf 10 20 Td (objstmword) Tj ET'

    inner = {
        1: b'<< /Type /Catalog /Pages 2 0 R >>',
        2: b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        3: b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] '
           b'/Resources << /Font << /F1 7 0 R >> >> /Contents 4 0 R >>',
        7: b'<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>',
    }
    order = [1, 2, 3, 7]
    bodies = b''
    header_parts = []
    for number in order:
        header_parts.append(b'%d %d' % (number, len(bodies)))
        bodies += inner[number] + b'\n'
    header = b' '.join(header_parts) + b' '
    objstm_data = header + bodies
    first = len(header)

    for name, compressed in (('xref-stream.pdf', False), ('xref-stream-flate.pdf', True)):
        _write_xref_stream_pdf(
            FIXTURES_DIR / name, content, objstm_data, order, first, compressed
        )


def _write_xref_stream_pdf(
    path: Path,
    content: bytes,
    objstm_data: bytes,
    order: list[int],
    first: int,
    compressed: bool,
) -> None:
    out = bytearray(b'%PDF-1.5\n')
    offsets: dict[int, int] = {}

    def write_object(number: int, body: bytes) -> None:
        offsets[number] = len(out)
        out.extend(b'%d 0 obj\n' % number)
        out.extend(body)
        out.extend(b'\nendobj\n')

    # 4: the page's content stream (a direct object, not in the ObjStm).
    write_object(4, b'<< /Length %d >>\nstream\n' % len(content) + content + b'\nendstream')

    # 5: the object stream holding the catalog, page tree, page and font.
    if compressed:
        payload = zlib.compress(objstm_data)
        write_object(
            5,
            b'<< /Type /ObjStm /N %d /First %d /Filter /FlateDecode /Length %d >>\nstream\n'
            % (len(order), first, len(payload)) + payload + b'\nendstream',
        )
    else:
        write_object(
            5,
            b'<< /Type /ObjStm /N %d /First %d /Length %d >>\nstream\n'
            % (len(order), first, len(objstm_data)) + objstm_data + b'\nendstream',
        )

    # 6: the xref stream. Its own offset is only known now, so it is recorded
    # before the row table is built.
    xref_offset = len(out)
    offsets[6] = xref_offset

    rows: dict[int, bytes] = {}
    rows[0] = bytes([0]) + struct.pack('>I', 0) + struct.pack('>H', 0xFFFF)
    for index, number in enumerate(order):
        # Type 2: object lives at index `index` inside object stream 5.
        rows[number] = bytes([2]) + struct.pack('>I', 5) + struct.pack('>H', index)
    for number in (4, 5, 6):
        rows[number] = bytes([1]) + struct.pack('>I', offsets[number]) + struct.pack('>H', 0)
    table = b''.join(rows[number] for number in range(8))

    if compressed:
        # PNG "Up" predictor (12): every row stores its byte-wise difference
        # from the previous decoded row, prefixed with the filter byte 2.
        filtered = bytearray()
        previous = bytes(7)
        for start in range(0, len(table), 7):
            row = table[start:start + 7]
            filtered.append(2)
            filtered.extend(bytes((row[i] - previous[i]) & 0xFF for i in range(7)))
            previous = row
        stream_bytes = zlib.compress(bytes(filtered))
        extra = b' /Filter /FlateDecode /DecodeParms << /Predictor 12 /Columns 7 >>'
    else:
        stream_bytes = table
        extra = b''

    write_object(
        6,
        b'<< /Type /XRef /Size 8 /W [1 4 2] /Index [0 8] /Root 1 0 R'
        + extra
        + b' /Length %d >>\nstream\n' % len(stream_bytes)
        + stream_bytes
        + b'\nendstream',
    )

    out.extend(b'startxref\n%d\n%%%%EOF\n' % xref_offset)
    path.write_bytes(bytes(out))


# --- driver ----------------------------------------------------------------


def remove_sidecars() -> None:
    """Drop the PNG that ``make_image_pdf`` leaves next to the PDF.

    Its bytes are embedded in ``image.pdf``; keeping the file would only add a
    second artifact to diff on regeneration.
    """
    for sidecar in FIXTURES_DIR.glob('*-embed.png'):
        sidecar.unlink()


def main() -> int:
    FIXTURES_DIR.mkdir(parents=True, exist_ok=True)
    for stale in FIXTURES_DIR.glob('*.pdf'):
        stale.unlink()

    build_fixture_library()
    build_jpeg()
    build_quoted_table()
    build_garbage()
    build_encrypted()
    build_corrupt_stream()
    build_xref_stream()
    remove_sidecars()

    missing = [name for name in FIXTURE_NAMES if not (FIXTURES_DIR / name).is_file()]
    if missing:
        print('error: missing fixtures: ' + ', '.join(missing), file=sys.stderr)
        return 1

    for name in FIXTURE_NAMES:
        data = (FIXTURES_DIR / name).read_bytes()
        digest = hashlib.sha256(data).hexdigest()[:16]
        print(f'{name:<24} {len(data):>7} bytes  sha256:{digest}')
    print(f'\n{len(FIXTURE_NAMES)} fixtures in {FIXTURES_DIR}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
