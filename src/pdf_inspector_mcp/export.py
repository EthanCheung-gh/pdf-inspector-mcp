"""Export serialisation: JSON and CSV rendering of extracted PDF data.

Ported from ``pdf-inspector/src/renderer/services/export-data.ts`` (v0.2.0).

The port keeps the upstream document shapes, section order and row layouts
line-for-line wherever the two runtimes allow it. Two deliberate conventions are
documented here because they cannot match byte-for-byte:

1. **JSON numbers.** JavaScript's ``JSON.stringify`` prints an integral number as
   ``612``; Python's ``json.dumps`` renders the float its value carries, i.e.
   ``612.0``. This module keeps that Python behaviour (accepted deviation):
   coordinates and sizes coming out of pdfplumber are floats, so exported JSON
   may show a trailing ``.0`` where the TS exporter shows ``612``. Everything
   else matches: two-space indent, the same key order, ``null`` for absent
   metadata, and ``ensure_ascii=False`` because ``JSON.stringify`` never escapes
   non-ASCII characters (CJK/Latin-1 text stays readable).

2. **CSV cells.** Upstream formats every cell with JavaScript's ``String()``.
   ``str()`` would disagree, so this module emulates ``String()``: booleans
   become ``true``/``false`` (never ``True``/``False``), integral floats lose
   their ``.0`` (``12.0`` -> ``12``, ``1.0`` -> ``1``), and other floats use the
   shortest round-trip representation, rendered in the same fixed/exponential
   ranges JavaScript uses (``0.5`` -> ``0.5``, ``1e-07`` -> ``1e-7``).

3. **CSV array values.** pdfplumber hands ``stroking_color`` through untouched,
   so a colour cell can be a tuple (``(0,)``, ``(0.1, 0.2, 0.3)``) where the
   TypeScript side sees an array. ``str()`` would print ``(0,)``; JavaScript's
   ``String([0])`` is ``0``. A ``list``/``tuple`` cell is therefore rendered with
   ``Array.prototype.toString`` -- ``join(',')`` over the scalar rules above --
   so ``(0,)`` -> ``0`` and ``(0.1, 0.2, 0.3)`` -> ``0.1,0.2,0.3`` (then quoted
   by RFC 4180, since it contains commas). Conventions inside arrays follow
   ``Array.prototype.join``: an empty array and an array of nulls render as an
   empty field (``[]`` -> ``''``, ``[None]`` -> ``''``), ``None`` renders as an
   empty field just like ``null``/``undefined`` (``[None, 1]`` -> ``',1'``), and
   nested arrays join recursively (``[[0, 0], [5, 5]]`` -> ``0,0,5,5``). A
   top-level ``None`` cell still renders as ``null`` (``String(null)``). Curve
   ``points`` never take this path: they are pre-serialised as compact JSON
   (``"[[0,0],[5,5]]"``).

Beyond those three, behaviour mirrors upstream: ``None`` types means every type,
an explicit empty list means "no object data", unknown type strings are dropped,
and the CSV output is BOM-prefixed so Excel decodes UTF-8 correctly.
"""

from __future__ import annotations

import json
import math
import re
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any, Callable, Mapping, Optional, Sequence
from urllib.parse import unquote, urlsplit

from .objects import EXPORT_OBJECT_TYPES

__all__ = [
    'EXPORT_OBJECT_TYPES',
    'resolve_types',
    'pages_to_json',
    'pages_to_csv',
    'objects_to_json',
    'objects_to_csv',
    'suggest_filename',
]

#: Byte-order mark every CSV document starts with (Excel needs it for UTF-8).
BOM = '\uFEFF'

_CSV_CELL_SEPARATOR = ','
_CSV_NEEDS_QUOTES = re.compile(r'[",\n\r]')
_BBOX = ('page', 'x0', 'y0', 'x1', 'y1')

#: Per-type CSV section metadata, keyed by canonical object type.
_CSV_SECTIONS: dict[str, tuple[str, tuple[str, ...]]] = {
    'char': ('# chars', _BBOX + ('text', 'fontname', 'size', 'color')),
    'word': ('# words', _BBOX + ('text', 'fontname', 'size')),
    'rect': ('# rects', _BBOX + ('fill', 'stroke', 'color', 'width')),
    'line': ('# lines', _BBOX + ('stroke', 'color', 'width')),
    'curve': ('# curves', _BBOX + ('points', 'stroke')),
    'image': ('# images', _BBOX + ('width', 'height', 'stream_id', 'format')),
    'table': ('# tables', ('page', 'table_index', 'row', 'col', 'text')),
}


# --- type selection --------------------------------------------------------


def resolve_types(types: Optional[Sequence[str]]) -> list[str]:
    """Canonical, de-duplicated selection.

    ``None`` means every type; an explicit empty list stays empty (it means "no
    object data", not "all"). Unknown type strings are ignored instead of being
    rejected, duplicates collapse, and the result is always in canonical
    ``EXPORT_OBJECT_TYPES`` order rather than caller order.
    """

    if types is None:
        return list(EXPORT_OBJECT_TYPES)
    requested = set(types)
    return [type_name for type_name in EXPORT_OBJECT_TYPES if type_name in requested]


# --- JSON ------------------------------------------------------------------


def _iso_timestamp(moment: Optional[datetime]) -> str:
    """ISO-8601 UTC with millisecond precision, as ``Date.toISOString()``.

    ``datetime.isoformat()`` would emit ``+00:00`` and no fixed precision, so the
    fields are formatted explicitly.
    """

    if moment is None:
        moment = datetime.now(timezone.utc)
    elif moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    else:
        moment = moment.astimezone(timezone.utc)

    return (
        f'{moment.year:04d}-{moment.month:02d}-{moment.day:02d}T'
        f'{moment.hour:02d}:{moment.minute:02d}:{moment.second:02d}.'
        f'{moment.microsecond // 1000:03d}Z'
    )


def _dumps(document: Mapping[str, Any]) -> str:
    """``JSON.stringify(document, null, 2)`` equivalent for our value shapes."""

    return json.dumps(document, indent=2, ensure_ascii=False)


def _page_export(page: Mapping[str, Any], selected: Sequence[str]) -> dict[str, Any]:
    """Spread the page, then blank out the arrays of unselected types."""

    exported = dict(page)
    exported['chars'] = page['chars'] if 'char' in selected else []
    exported['words'] = page['words'] if 'word' in selected else []
    exported['rects'] = page['rects'] if 'rect' in selected else []
    exported['lines'] = page['lines'] if 'line' in selected else []
    exported['curves'] = page['curves'] if 'curve' in selected else []
    exported['images'] = page['images'] if 'image' in selected else []
    exported['tables'] = page['tables'] if 'table' in selected else []
    return exported


def pages_to_json(
    pages: Sequence[Mapping[str, Any]],
    metadata: Optional[Mapping[str, Any]],
    types: Optional[Sequence[str]] = None,
    *,
    exported_at: Optional[datetime] = None,
) -> str:
    """Whole-document JSON: metadata, timestamp, page count, types, pages."""

    object_types = resolve_types(types)
    document = {
        'metadata': metadata,
        'exportedAt': _iso_timestamp(exported_at),
        'pageCount': len(pages),
        'objectTypes': object_types,
        'pages': [_page_export(page, object_types) for page in pages],
    }
    return _dumps(document)


def _objects_of_type(objects: Sequence[Mapping[str, Any]], type_name: str) -> list[Mapping[str, Any]]:
    return [obj for obj in objects if obj['type'] == type_name]


def objects_to_json(
    objects: Sequence[Mapping[str, Any]],
    metadata: Optional[Mapping[str, Any]],
    page: int,
    types: Optional[Sequence[str]] = None,
    *,
    exported_at: Optional[datetime] = None,
) -> str:
    """Single-page JSON: metadata, timestamp, page, counts, types, objects."""

    object_types = resolve_types(types)
    selected_objects = [obj for obj in objects if obj['type'] in object_types]
    document = {
        'metadata': metadata,
        'exportedAt': _iso_timestamp(exported_at),
        'page': page,
        'objectCount': len(selected_objects),
        'objectTypes': object_types,
        'objects': selected_objects,
    }
    return _dumps(document)


# --- CSV cell formatting ---------------------------------------------------


def _format_float(value: float) -> str:
    """Render a float the way JavaScript's ``String()`` would."""

    if math.isnan(value):
        return 'NaN'
    if math.isinf(value):
        return 'Infinity' if value > 0 else '-Infinity'

    magnitude = abs(value)
    if value.is_integer() and magnitude < 1e21:
        # 12.0 -> '12', -0.0 -> '0' (String(-0) === '0').
        return str(int(value))

    text = repr(value)
    if 'e' not in text:
        return text
    if 1e-6 <= magnitude < 1e21:
        # JavaScript prints this range in fixed notation; Python repr may not.
        return format(Decimal(text), 'f')

    mantissa, _, exponent = text.partition('e')
    sign = '-' if exponent.startswith('-') else '+'
    digits = exponent.lstrip('+-').lstrip('0') or '0'
    return f'{mantissa}e{sign}{digits}'


def _array_element(value: Any) -> str:
    """``Array.prototype.join`` element rule: null/undefined become empty."""

    if value is None:
        return ''
    if isinstance(value, (list, tuple)):
        return _array_to_string(value)
    return _csv_cell(value)


def _array_to_string(values: Sequence[Any]) -> str:
    """``Array.prototype.toString``: ``join(',')`` over the scalar rules."""

    return ','.join(_array_element(value) for value in values)


def _csv_cell(value: Any) -> str:
    """``String(value)`` for the value kinds our rows carry.

    Lists/tuples follow ``Array.prototype.toString``, which is what the
    TypeScript exporter sees for pdfplumber's tuple-valued ``stroking_color``:
    ``(0,)`` -> ``0`` rather than Python's ``(0,)`` repr.
    """

    if value is True:
        return 'true'
    if value is False:
        return 'false'
    if value is None:
        return 'null'
    if isinstance(value, str):
        return value
    if isinstance(value, (list, tuple)):
        return _array_to_string(value)
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return _format_float(value)
    return str(value)


def _csv_escape(value: str) -> str:
    """RFC 4180 quoting: only comma, double quote, CR or LF force quotes."""

    if _CSV_NEEDS_QUOTES.search(value):
        return '"' + value.replace('"', '""') + '"'
    return value


def _csv_row(values: Sequence[Any]) -> str:
    return _CSV_CELL_SEPARATOR.join(_csv_escape(_csv_cell(value)) for value in values)


def _compact_json(value: Any) -> str:
    """``JSON.stringify(value)`` without indentation (curve points)."""

    return json.dumps(value, separators=(',', ':'))


# --- CSV rows --------------------------------------------------------------


def _char_row(char: Mapping[str, Any]) -> list[Any]:
    return [char['page'], char['x0'], char['y0'], char['x1'], char['y1'],
            char['text'], char['fontname'], char['size'], char['color']]


def _word_row(word: Mapping[str, Any]) -> list[Any]:
    return [word['page'], word['x0'], word['y0'], word['x1'], word['y1'],
            word['text'], word['fontname'], word['size']]


def _rect_row(rect: Mapping[str, Any]) -> list[Any]:
    return [rect['page'], rect['x0'], rect['y0'], rect['x1'], rect['y1'],
            rect['fill'], rect['stroke'], rect['color'], rect['width']]


def _line_row(line: Mapping[str, Any]) -> list[Any]:
    return [line['page'], line['x0'], line['y0'], line['x1'], line['y1'],
            line['stroke'], line['color'], line['width']]


def _curve_row(curve: Mapping[str, Any]) -> list[Any]:
    return [curve['page'], curve['x0'], curve['y0'], curve['x1'], curve['y1'],
            _compact_json(curve['points']), curve['stroke']]


def _image_row(image: Mapping[str, Any]) -> list[Any]:
    return [image['page'], image['x0'], image['y0'], image['x1'], image['y1'],
            image['width'], image['height'], image['stream_id'], image['format']]


def _table_rows(table: Mapping[str, Any], table_index: int) -> list[list[Any]]:
    """One row per cell, keeping the table's position inside the current section."""

    return [
        [table['page'], table_index, row_index, col_index, text]
        for row_index, row in enumerate(table['cells'])
        for col_index, text in enumerate(row)
    ]


def _page_chars(pages: Sequence[Mapping[str, Any]]) -> list[list[Any]]:
    return [_char_row(char) for page in pages for char in page['chars']]


def _page_words(pages: Sequence[Mapping[str, Any]]) -> list[list[Any]]:
    return [_word_row(word) for page in pages for word in page['words']]


def _page_rects(pages: Sequence[Mapping[str, Any]]) -> list[list[Any]]:
    return [_rect_row(rect) for page in pages for rect in page['rects']]


def _page_lines(pages: Sequence[Mapping[str, Any]]) -> list[list[Any]]:
    return [_line_row(line) for page in pages for line in page['lines']]


def _page_curves(pages: Sequence[Mapping[str, Any]]) -> list[list[Any]]:
    return [_curve_row(curve) for page in pages for curve in page['curves']]


def _page_images(pages: Sequence[Mapping[str, Any]]) -> list[list[Any]]:
    return [_image_row(image) for page in pages for image in page['images']]


def _page_tables(pages: Sequence[Mapping[str, Any]]) -> list[list[Any]]:
    """Table indexes restart per page."""

    return [
        row
        for page in pages
        for table_index, table in enumerate(page['tables'])
        for row in _table_rows(table, table_index)
    ]


def _object_chars(objects: Sequence[Mapping[str, Any]]) -> list[list[Any]]:
    return [_char_row(char) for char in _objects_of_type(objects, 'char')]


def _object_words(objects: Sequence[Mapping[str, Any]]) -> list[list[Any]]:
    return [_word_row(word) for word in _objects_of_type(objects, 'word')]


def _object_rects(objects: Sequence[Mapping[str, Any]]) -> list[list[Any]]:
    return [_rect_row(rect) for rect in _objects_of_type(objects, 'rect')]


def _object_lines(objects: Sequence[Mapping[str, Any]]) -> list[list[Any]]:
    return [_line_row(line) for line in _objects_of_type(objects, 'line')]


def _object_curves(objects: Sequence[Mapping[str, Any]]) -> list[list[Any]]:
    return [_curve_row(curve) for curve in _objects_of_type(objects, 'curve')]


def _object_images(objects: Sequence[Mapping[str, Any]]) -> list[list[Any]]:
    return [_image_row(image) for image in _objects_of_type(objects, 'image')]


def _object_tables(objects: Sequence[Mapping[str, Any]]) -> list[list[Any]]:
    """Table indexes follow the filtered order."""

    return [
        row
        for table_index, table in enumerate(_objects_of_type(objects, 'table'))
        for row in _table_rows(table, table_index)
    ]


#: Row builders over full pages.
_PAGE_CSV_ROWS: dict[str, Callable[[Sequence[Mapping[str, Any]]], list[list[Any]]]] = {
    'char': _page_chars,
    'word': _page_words,
    'rect': _page_rects,
    'line': _page_lines,
    'curve': _page_curves,
    'image': _page_images,
    'table': _page_tables,
}

#: Row builders over a flat object list.
_OBJECT_CSV_ROWS: dict[str, Callable[[Sequence[Mapping[str, Any]]], list[list[Any]]]] = {
    'char': _object_chars,
    'word': _object_words,
    'rect': _object_rects,
    'line': _object_lines,
    'curve': _object_curves,
    'image': _object_images,
    'table': _object_tables,
}


def _serialize_csv_sections(
    selected: Sequence[str],
    rows_for: Callable[[str], list[list[Any]]],
) -> str:
    """Single CSV document, one ``# <type>`` section per selected type.

    An empty selection produces just the BOM.
    """

    if not selected:
        return BOM

    out: list[str] = []
    for type_name in selected:
        title, header = _CSV_SECTIONS[type_name]
        out.append(title)
        out.append(_csv_row(header))
        for row in rows_for(type_name):
            out.append(_csv_row(row))

    return BOM + '\n'.join(out) + '\n'


def pages_to_csv(
    pages: Sequence[Mapping[str, Any]],
    types: Optional[Sequence[str]] = None,
) -> str:
    """CSV of every selected type across all pages."""

    selected = resolve_types(types)
    return _serialize_csv_sections(selected, lambda type_name: _PAGE_CSV_ROWS[type_name](pages))


def objects_to_csv(
    objects: Sequence[Mapping[str, Any]],
    page: int,
    types: Optional[Sequence[str]] = None,
) -> str:
    """CSV of every selected type for one flat object list.

    ``page`` is accepted for signature parity with ``objects_to_json``; each
    object carries its own page number, so it is not used to build rows.
    """

    selected = resolve_types(types)
    return _serialize_csv_sections(selected, lambda type_name: _OBJECT_CSV_ROWS[type_name](objects))


# --- file names ------------------------------------------------------------

_PATH_SEGMENT_SPLIT = re.compile(r'[\\/]')
_PDF_SUFFIX = re.compile(r'\.pdf$', re.IGNORECASE)
#: A '%' not followed by two hex digits: ``decodeURIComponent`` throws on these.
_INVALID_PERCENT_ESCAPE = re.compile(r'%(?![0-9A-Fa-f]{2})')


def _local_stem(pdf_path: Optional[str]) -> str:
    """Last path segment without a ``.pdf`` suffix (``document`` when missing)."""

    if pdf_path is None:
        return 'document'
    # ``re.split`` always yields at least one element, mirroring ``split().pop()``.
    return _PDF_SUFFIX.sub('', _PATH_SEGMENT_SPLIT.split(pdf_path)[-1])


def _normalize_pathname(pathname: str) -> str:
    """Resolve ``.``/``..`` segments the way the WHATWG URL parser does.

    ``new URL('https://example.com/..').pathname`` is ``'/'`` and
    ``/a/../b.pdf`` collapses to ``/b.pdf``; without this, the segment picked
    below would be a literal ``'..'``. Empty segments are dropped, which cannot
    change which segment is last.
    """

    if not pathname.startswith('/'):
        return pathname

    stack: list[str] = []
    trailing_slash = False
    for segment in pathname.split('/')[1:]:
        if segment == '.':
            trailing_slash = True
        elif segment == '..':
            if stack:
                stack.pop()
            trailing_slash = True
        elif not segment:
            trailing_slash = True
        else:
            stack.append(segment)
            trailing_slash = False

    if not stack:
        return '/'
    return '/' + '/'.join(stack) + ('/' if trailing_slash else '')


def _url_stem(source_url: Optional[str]) -> Optional[str]:
    """Filename stem from a source URL's last path segment, or ``None``.

    Query and hash are not part of ``pathname``, so they never end up in the
    name. ``None`` means "unusable" (unparseable, no file segment, broken
    escaping) so callers can fall back to the local path.
    """

    if not source_url:
        return None

    try:
        parts = urlsplit(source_url)
    except ValueError:
        return None
    # ``new URL()`` requires an absolute URL; relative input throws upstream too.
    if not parts.scheme:
        return None

    pathname = _normalize_pathname(parts.path)
    segments = [segment for segment in pathname.split('/') if segment]
    # A trailing slash means the last segment is a directory, not a file name.
    if not segments or pathname.endswith('/'):
        return None

    segment = segments[-1]
    # ``decodeURIComponent`` throws URIError on a malformed escape ('%zz', '%E0%A4%A',
    # a trailing '%'); ``unquote`` alone would keep '%zz' and only fail on the
    # invalid-UTF-8 case, so validate the escaping first.
    if _INVALID_PERCENT_ESCAPE.search(segment):
        return None
    try:
        decoded = unquote(segment, errors='strict')
    except (UnicodeDecodeError, ValueError):
        return None
    # WHATWG also treats percent-encoded dots ('%2E%2E') as dot segments, which a
    # literal-path normalisation leaves in place; decoding them yields '.'/'..',
    # never a file name.
    if decoded in ('.', '..'):
        return None

    stem = _PDF_SUFFIX.sub('', re.sub(r'[\\/]', '_', decoded)).strip()
    return stem or None


def suggest_filename(
    pdf_path: Optional[str],
    scope: str,
    page: int,
    ext: str,
    source_url: Optional[str] = None,
) -> str:
    """Suggested download name: ``<base>-p<page>.<ext>`` or ``<base>-all.<ext>``.

    URL documents are downloaded to a temp file with a hash in its name, so the
    URL stem is preferred over the local path when it is usable. As upstream, an
    unknown ``scope`` falls through to the document form.
    """

    base = _url_stem(source_url) or _local_stem(pdf_path)
    if scope == 'page':
        return f'{base}-p{page}.{ext}'
    return f'{base}-all.{ext}'
