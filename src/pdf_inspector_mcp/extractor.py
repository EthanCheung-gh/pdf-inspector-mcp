"""PDF structural extraction built on pdfplumber.

ported from pdf-inspector/sidecar/extractor.py (v0.2.0)

The behaviour is intentionally identical to the upstream sidecar extractor: same
object field names, same page-range validation messages, same font statistics
semantics, same image preview encoding. Two methods were added for this project
(the tool layer needs them and the sidecar did not have them): ``page_count()``
and ``extract_pages()``.
"""

from __future__ import annotations

import base64
import re
from io import BytesIO
from typing import Any, Optional

import pdfplumber
from pdfplumber.page import Page

# Image formats the renderer (Chromium) can display straight from a data: URL.
DIRECT_IMAGE_FORMATS = frozenset({'png', 'jpeg', 'gif', 'webp'})

# JPEG2000 codestream / JP2 container signatures.
_JPX_SIGNATURES = (b'\x00\x00\x00\x0cjP  \r\n\x87\n', b'\xff\x4f\xff\x51')
_JBIG2_SIGNATURE = b'\x97JB2\r\n\x1a\n'

#: ``stream_id`` format used for embedded images: ``p<page>_img_<index>``.
_STREAM_ID_RE = re.compile(r'p(\d+)_img_(\d+)')

#: ``%PDF-<major>.<minor>`` header marker. The specification allows a little
#: junk before it, hence the byte window below.
_PDF_VERSION_RE = re.compile(rb'%PDF-(\d+\.\d+)')

#: Number of leading bytes scanned for the header marker.
_PDF_VERSION_WINDOW = 1024


class PdfExtractor:
    """Wraps pdfplumber to extract page-level structured data."""

    @staticmethod
    def _detect_image_format(data: bytes) -> Optional[str]:
        """Identify an image format from its byte signature.

        Returns a browser-renderable name for PNG/JPEG/GIF/WebP, 'jpx' or
        'jbig2' for JPEG2000/JBIG2 payloads (both PDF-native and not directly
        renderable), and None when the signature is unknown.
        """
        if data.startswith(b'\x89PNG\r\n\x1a\n'):
            return 'png'
        if data.startswith(b'\xff\xd8\xff'):
            return 'jpeg'
        if data.startswith((b'GIF87a', b'GIF89a')):
            return 'gif'
        if data[:4] == b'RIFF' and data[8:12] == b'WEBP':
            return 'webp'
        if data.startswith(_JPX_SIGNATURES):
            return 'jpx'
        if data.startswith(_JBIG2_SIGNATURE):
            return 'jbig2'
        return None

    @staticmethod
    def _transcode_to_png(data: bytes) -> Optional[bytes]:
        """Re-encode anything Pillow can decode as PNG; None if that is impossible."""
        try:
            from PIL import Image
        except Exception:
            return None
        try:
            with Image.open(BytesIO(data)) as image:
                if image.mode not in ('1', 'L', 'LA', 'P', 'RGB', 'RGBA'):
                    # CMYK, I;16, F, ... have no direct PNG equivalent.
                    image = image.convert('RGBA' if 'A' in image.mode else 'RGB')
                out = BytesIO()
                image.save(out, format='PNG')
                return out.getvalue()
        except Exception:
            return None

    @staticmethod
    def _word_y_range(
        word: dict[str, Any],
        page_height: float,
        mediabox_top: float,
    ) -> tuple[float, float]:
        """Return a word's (y0, y1) in the same PDF-space coords as page.chars.

        pdfplumber's WordExtractor only reports top/bottom, derived from the char
        boxes as ``top = page.height - y1 + mediabox_top`` and
        ``bottom = page.height - y0 + mediabox_top`` (Page.process_object). The
        inverse therefore has to add the MediaBox vertical origin back, otherwise
        words are displaced by |mediabox_top| relative to chars/rects/lines on
        pages whose MediaBox does not start at y = 0.
        """
        y0 = word.get('y0')
        y1 = word.get('y1')
        if y0 is None:
            y0 = page_height + mediabox_top - float(word['bottom'])
        if y1 is None:
            y1 = page_height + mediabox_top - float(word['top'])
        return float(y0), float(y1)

    @classmethod
    def _encode_for_preview(cls, data: bytes) -> dict[str, Any]:
        """Build the {'base64', 'format'} payload the renderer can display.

        Directly renderable formats pass through untouched; every other format
        is transcoded to PNG; payloads that cannot be decoded yield {'error'}.
        """
        fmt = cls._detect_image_format(data)
        if fmt in DIRECT_IMAGE_FORMATS:
            return {'base64': base64.b64encode(data).decode('ascii'), 'format': fmt}

        png = cls._transcode_to_png(data)
        if png is not None:
            return {'base64': base64.b64encode(png).decode('ascii'), 'format': 'png'}

        return {'error': f'Unsupported image format: {fmt or "unknown"}'}

    @staticmethod
    def _resolve_pdf_value(value: Any) -> Any:
        """Follow a pdfminer PDFObjRef (or any ``.resolve()`` wrapper) to its target.

        Returns None when resolution fails so callers can skip a broken object
        instead of failing the whole request.
        """
        resolve = getattr(value, 'resolve', None)
        if callable(resolve):
            try:
                return resolve()
            except Exception:
                return None
        return value

    @classmethod
    def _base_font_name(cls, font_obj: Any) -> Optional[str]:
        """Return a font dictionary's BaseFont as a plain string, or None.

        pdfminer represents BaseFont as a PSLiteral, so ``.name`` is the reliable
        accessor; ``str(PSLiteral('Helvetica'))`` is ``"/'Helvetica'"`` and is only
        used as a last-resort fallback.
        """
        getter = getattr(font_obj, 'get', None)
        if not callable(getter):
            return None
        try:
            base_font = cls._resolve_pdf_value(getter('BaseFont'))
        except Exception:
            return None
        if base_font is None:
            return None

        name = getattr(base_font, 'name', None)
        if isinstance(name, bytes):
            name = name.decode('latin-1', 'replace')
        if isinstance(name, str) and name:
            return name
        if isinstance(base_font, bytes):
            text = base_font.decode('latin-1', 'replace').strip()
            return text or None
        if isinstance(base_font, str):
            return base_font or None

        try:
            text = str(base_font).strip()
        except Exception:
            return None
        # PSLiteral fallback form: "/'Helvetica'" -> "Helvetica".
        if text.startswith('/'):
            text = text[1:]
        text = text.strip().strip("'").strip()
        return text or None

    def _collect_font_names(self) -> list[str]:
        """Collect BaseFont names from page font resources, without page layout.

        Walking ``page.chars`` requires full text layout for every page, which
        times out on large PDFs. The resource dictionaries already list every
        font referenced by a page, so reading them is enough for metadata.
        Any per-page or per-font failure is skipped: metadata must never fail
        because of one malformed font resource.
        """
        names: set[str] = set()
        for page in self._pdf.pages:
            try:
                page_obj = getattr(page, 'page_obj', None)
                resources = self._resolve_pdf_value(getattr(page_obj, 'resources', None))
                if not isinstance(resources, dict):
                    continue
                font_resources = self._resolve_pdf_value(resources.get('Font'))
                if not isinstance(font_resources, dict):
                    continue
                for font_ref in list(font_resources.values()):
                    try:
                        font_obj = self._resolve_pdf_value(font_ref)
                        if not isinstance(font_obj, dict):
                            continue
                        name = self._base_font_name(font_obj)
                    except Exception:
                        continue
                    if name:
                        names.add(name)
            except Exception:
                # A malformed page (or resources accessor) must not break metadata.
                continue
        return sorted(names)

    def __init__(self, path: str, password: Optional[str] = None):
        self._path = path
        self._password = password
        self._pdf = pdfplumber.open(path, password=password)
        # analyze_fonts() needs a full char walk; memoize it for the document.
        self._font_stats_cache: Optional[dict[str, Any]] = None

    def _detect_pdf_version(self) -> str:
        """Return the document's PDF version as ``'<major>.<minor>'``, or 'unknown'.

        pdfminer.six used to expose the header version as ``PDFDocument.pdf_version``
        and pdfplumber forwarded it as ``PDF.pdf_version``; newer releases (as of
        pdfplumber 0.11.10 / pdfminer.six 20260107) dropped that attribute, so the
        old ``hasattr`` probe silently reported 'unknown' for every document.

        The fallbacks, in order:

        1. ``pdf.pdf_version`` when a pdfplumber/pdfminer version still provides it.
        2. The ``%PDF-<major>.<minor>`` header marker read from the file itself.
           The PDF specification tolerates junk before the header, so the first
           1024 bytes are searched rather than only the very first bytes.
        3. ``'unknown'``.

        Metadata must never fail because of an unreadable file or a malformed
        header, so every failure here degrades to ``'unknown'``.
        """
        version = self._resolve_pdf_value(getattr(self._pdf, 'pdf_version', None))
        if isinstance(version, bytes):
            version = version.decode('latin-1', 'replace')
        if isinstance(version, str) and version.strip():
            return version.strip()

        try:
            with open(self._path, 'rb') as handle:
                header = handle.read(_PDF_VERSION_WINDOW)
        except Exception:
            # Missing, unreadable or closed file: report the neutral value.
            return 'unknown'

        match = _PDF_VERSION_RE.search(header)
        if match is None:
            return 'unknown'
        try:
            return match.group(1).decode('ascii')
        except Exception:  # pragma: no cover - non-ASCII digits cannot match
            return 'unknown'

    def get_metadata(self) -> dict[str, Any]:
        """Document-level metadata; never lays out page content."""
        doc = self._pdf.metadata
        return {
            'pages': len(self._pdf.pages),
            'version': self._detect_pdf_version(),
            'encrypted': self._pdf.is_encrypted if hasattr(self._pdf, 'is_encrypted') else False,
            'page_w': float(self._pdf.pages[0].width) if self._pdf.pages else 0,
            'page_h': float(self._pdf.pages[0].height) if self._pdf.pages else 0,
            'title': doc.get('Title', ''),
            'author': doc.get('Author', ''),
            'producer': doc.get('Producer', ''),
            'fonts': self._collect_font_names(),
        }

    def page_count(self) -> int:
        """Number of pages in the open document."""
        return len(self._pdf.pages)

    def analyze_fonts(
        self,
        start_page: Optional[int] = None,
        end_page: Optional[int] = None,
    ) -> dict[str, Any]:
        """Character-level font statistics for the whole document or a page range.

        With no page arguments this keeps the original behaviour: one full-document
        walk, memoized in ``_font_stats_cache``. A page range (1-based, inclusive)
        is computed on demand and never reads or populates that cache, so the
        renderer can request small batches without forcing a full-document walk
        (and without blocking the next sidecar request on one).
        """
        if start_page is None and end_page is None:
            if self._font_stats_cache is None:
                self._font_stats_cache = self._compute_font_stats()
            return self._font_stats_cache
        return self._compute_font_stats(start_page, end_page)

    def _validate_page_range(
        self,
        start_page: Optional[int],
        end_page: Optional[int],
    ) -> tuple[int, int]:
        """Resolve a partially specified 1-based, inclusive page range.

        ``None`` on either side falls back to the document bounds, so one-sided
        ranges are allowed. Raises ValueError for non-integer bounds (bool is not
        accepted as an int) and for ranges outside ``1..len(pages)``.
        """
        total = len(self._pdf.pages)
        for value in (start_page, end_page):
            if value is not None and (isinstance(value, bool) or not isinstance(value, int)):
                raise ValueError(
                    f'Invalid page range: {start_page!r}-{end_page!r} '
                    f'(page numbers must be integers, document has {total} pages)'
                )
        start = 1 if start_page is None else start_page
        end = total if end_page is None else end_page
        if not (1 <= start <= end <= total):
            raise ValueError(
                f'Invalid page range: {start}-{end} (document has {total} pages)'
            )
        return start, end

    @staticmethod
    def _accumulate_font_stats(fonts: dict[str, dict], page, page_num: int) -> None:
        """Fold one page's chars into ``fonts``; the single per-char implementation.

        Both the full-document and the page-range analyses go through here, so a
        batch's numbers are defined exactly like the full walk's: charCount summed,
        sizeMin/sizeMax extended, colors kept in first-seen order (deduplicated),
        pages kept in first-seen ascending order.
        """
        for c in page.chars:
            name = c.get('fontname', '')
            if not name:
                continue
            entry = fonts.setdefault(name, {
                'fontname': name, 'pages': [], 'charCount': 0,
                'sizeMin': float(c.get('size', 0)), 'sizeMax': float(c.get('size', 0)),
                'colors': [],
            })
            entry['charCount'] += 1
            entry['sizeMin'] = min(entry['sizeMin'], float(c.get('size', 0)))
            entry['sizeMax'] = max(entry['sizeMax'], float(c.get('size', 0)))
            color = str(c.get('stroking_color', '#000000')) or '#000000'
            if color not in entry['colors']:
                entry['colors'].append(color)
            if page_num not in entry['pages']:
                entry['pages'].append(page_num)

    def _compute_font_stats(
        self,
        start_page: Optional[int] = None,
        end_page: Optional[int] = None,
    ) -> dict[str, Any]:
        """Font statistics for pages ``start_page..end_page`` inclusive.

        Both bounds ``None`` means the whole document (the cached full walk); an
        empty document therefore yields ``{'fonts': []}``.
        """
        pages = self._pdf.pages
        if start_page is None and end_page is None:
            first, last = 1, len(pages)
        else:
            first, last = self._validate_page_range(start_page, end_page)

        fonts: dict[str, dict] = {}
        for page_num in range(first, last + 1):
            self._accumulate_font_stats(fonts, pages[page_num - 1], page_num)
        return {'fonts': sorted(fonts.values(), key=lambda f: f['charCount'], reverse=True)}

    def _require_page(self, page_num: int) -> Page:
        """Return the 1-based page ``page_num``, raising ValueError when out of range."""
        total = len(self._pdf.pages)
        if isinstance(page_num, bool) or not isinstance(page_num, int):
            raise ValueError(
                f'Invalid page number: {page_num!r} '
                f'(page numbers must be integers, document has {total} pages)'
            )
        if not 1 <= page_num <= total:
            raise ValueError(
                f'Invalid page number: {page_num} (document has {total} pages)'
            )
        return self._pdf.pages[page_num - 1]

    def extract_page(self, page_num: int) -> dict[str, Any]:
        """Extract every object of one 1-based page.

        Out-of-range page numbers raise ValueError (never IndexError) so callers
        can report them without a traceback.
        """
        page: Page = self._require_page(page_num)

        chars = []
        for c in page.chars:
            chars.append({
                'type': 'char',
                'x0': float(c['x0']), 'y0': float(c['y0']),
                'x1': float(c['x1']), 'y1': float(c['y1']),
                'text': c.get('text', ''),
                'fontname': c.get('fontname', ''),
                'size': float(c.get('size', 0)),
                'color': c.get('stroking_color', '#000000') or '#000000',
                'page': page_num,
            })

        page_height = float(page.height)
        mediabox = getattr(page, 'mediabox', None)
        mediabox_top = float(mediabox[1]) if mediabox is not None else 0.0

        words = []
        # pdfplumber's word dicts do not include font attributes by default;
        # extra_attrs makes the extractor aggregate them from the word's chars,
        # so word objects can show/filter by font like chars do.
        for w in page.extract_words(extra_attrs=['fontname', 'size']):
            y0, y1 = self._word_y_range(w, page_height, mediabox_top)
            words.append({
                'type': 'word',
                'x0': float(w['x0']), 'y0': y0,
                'x1': float(w['x1']), 'y1': y1,
                'text': w.get('text', ''),
                'fontname': w.get('fontname', ''),
                'size': float(w.get('size', 0)),
                'page': page_num,
            })

        rects = []
        for r in page.rects:
            rects.append({
                'type': 'rect',
                'x0': float(r['x0']), 'y0': float(r['y0']),
                'x1': float(r['x1']), 'y1': float(r['y1']),
                'fill': r.get('non_stroking_color') is not None,
                'stroke': r.get('stroking_color') is not None,
                'color': str(r.get('stroking_color', '#000000')),
                'width': float(r.get('stroke_width', 1)),
                'page': page_num,
            })

        lines = []
        for ln in page.lines:
            lines.append({
                'type': 'line',
                'x0': float(ln['x0']), 'y0': float(ln['y0']),
                'x1': float(ln['x1']), 'y1': float(ln['y1']),
                'stroke': ln.get('stroking_color') is not None,
                'color': str(ln.get('stroking_color', '#000000')),
                'width': float(ln.get('stroke_width', 1)),
                'page': page_num,
            })

        curves = []
        for cv in page.curves:
            curves.append({
                'type': 'curve',
                'x0': float(cv['x0']), 'y0': float(cv['y0']),
                'x1': float(cv['x1']), 'y1': float(cv['y1']),
                'points': [[float(p[0]), float(p[1])] for p in cv.get('points', [])],
                'stroke': cv.get('stroking_color') is not None,
                'page': page_num,
            })

        images = []
        for idx, img in enumerate(page.images):
            stream = img.get('stream')
            images.append({
                'type': 'image',
                'x0': float(img['x0']), 'y0': float(img['y0']),
                'x1': float(img['x1']), 'y1': float(img['y1']),
                'width': float(img.get('width', 0)),
                'height': float(img.get('height', 0)),
                'stream_id': f'p{page_num}_img_{idx}',
                'format': 'unknown',
                'page': page_num,
                '_stream_data': stream,
            })

        tables = []
        for tbl in page.find_tables():
            bbox = tbl.bbox
            # tbl.cells holds bbox tuples; tbl.extract() holds the actual text.
            extracted = tbl.extract() or []
            cells = [
                ['' if cell is None else str(cell) for cell in (row or [])]
                for row in extracted
            ]
            tables.append({
                'type': 'table',
                'x0': float(bbox[0]), 'y0': float(bbox[1]),
                'x1': float(bbox[2]), 'y1': float(bbox[3]),
                'rows': len(extracted),
                'cols': max((len(row) for row in extracted), default=0),
                'cells': cells,
                'page': page_num,
            })

        # Strip internal _stream_data from returned images
        clean_images = []
        for img in images:
            clean = {k: v for k, v in img.items() if k != '_stream_data'}
            clean_images.append(clean)

        return {
            'width': float(page.width),
            'height': float(page.height),
            'chars': chars,
            'words': words,
            'rects': rects,
            'lines': lines,
            'curves': curves,
            'images': clean_images,
            'tables': tables,
        }

    def extract_pages(
        self,
        first_page: Optional[int] = None,
        last_page: Optional[int] = None,
    ) -> list[dict[str, Any]]:
        """Extract a 1-based, inclusive page range as a list of page dicts.

        Missing bounds fall back to the document bounds, so ``extract_pages()``
        walks the whole document. The range is validated once up front, which
        keeps the error identical to ``analyze_fonts()``'s, and an empty range
        (a zero-page document) yields an empty list.
        """
        if first_page is None and last_page is None and not self._pdf.pages:
            return []
        first, last = self._validate_page_range(first_page, last_page)
        return [self.extract_page(page_num) for page_num in range(first, last + 1)]

    def get_image_data(self, stream_id: str) -> dict[str, Any]:
        """Extract image bytes by stream_id."""
        match = _STREAM_ID_RE.match(stream_id)
        if not match:
            return {'error': f'Invalid stream_id: {stream_id}'}
        page_num = int(match.group(1))
        img_idx = int(match.group(2))

        total = len(self._pdf.pages)
        if not 1 <= page_num <= total:
            return {'error': f'Invalid stream_id: {stream_id}'}

        page: Page = self._pdf.pages[page_num - 1]
        images = page.images
        if img_idx >= len(images):
            return {'error': f'Image index {img_idx} out of range'}

        img = images[img_idx]
        stream = img.get('stream')
        if stream is None:
            return {'error': 'No stream data available'}

        try:
            data = stream.get('data') if hasattr(stream, 'get') else None
            if not isinstance(data, (bytes, bytearray, memoryview)):
                # pdfminer's PDFStream exposes the decoded payload via get_data().
                data = stream.get_data()
            if isinstance(data, (bytearray, memoryview)):
                data = bytes(data)
            if not isinstance(data, bytes):
                data = b''
            return self._encode_for_preview(data)
        except Exception as e:
            return {'error': str(e)}

    def close(self) -> None:
        """Close the underlying document."""
        self._pdf.close()

    def __enter__(self) -> 'PdfExtractor':
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()
