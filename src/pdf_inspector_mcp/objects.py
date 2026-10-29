"""Canonical object types for PDF structural data.

This module is the single source of truth for the shapes the extractor produces
and the exporter/MCP layer consumes. It mirrors the upstream TypeScript contract
in ``src/renderer/types/pdf-objects.ts`` (pdf-inspector v0.2.0) so that both
sides of the wire agree field-for-field.

Only constants and types live here: behaviour (such as resolving a page's
objects into the selected types) belongs to ``export.py``.
"""

from __future__ import annotations

from typing import Literal, TypedDict, Union

__all__ = [
    'PdfObjectType',
    'PDF_OBJECT_TYPES',
    'EXPORT_OBJECT_TYPES',
    'PdfBaseObject',
    'PdfChar',
    'PdfWord',
    'PdfRect',
    'PdfLine',
    'PdfCurve',
    'PdfImage',
    'PdfTable',
    'PdfObject',
    'PageData',
    'PdfMetadata',
    'FontStat',
    'FontStats',
]


# --- object type names -----------------------------------------------------

PdfObjectType = Literal['char', 'word', 'rect', 'line', 'curve', 'image', 'table']

#: Canonical order of object types. Exports must preserve it.
PDF_OBJECT_TYPES: tuple[PdfObjectType, ...] = (
    'char',
    'word',
    'rect',
    'line',
    'curve',
    'image',
    'table',
)

#: Alias used by the export layer: same values, same order as PDF_OBJECT_TYPES.
EXPORT_OBJECT_TYPES: tuple[PdfObjectType, ...] = PDF_OBJECT_TYPES


# --- object shapes ---------------------------------------------------------


class PdfBaseObject(TypedDict):
    """Fields shared by every extractable object."""

    type: PdfObjectType
    x0: float
    y0: float
    x1: float
    y1: float
    page: int


class PdfChar(PdfBaseObject):
    """A single glyph."""

    type: Literal['char']
    text: str
    fontname: str
    size: float
    # pdfplumber's stroking_color may be a string ('#000000') or a numeric
    # sequence such as (0,) / [0.5, 0.5, 0.5]; the export layer formats it with
    # JavaScript Array semantics, so both shapes are part of the contract.
    color: str | list[float] | tuple[float, ...]


class PdfWord(PdfBaseObject):
    """A whitespace-delimited word."""

    type: Literal['word']
    text: str
    fontname: str
    size: float


class PdfRect(PdfBaseObject):
    """An axis-aligned rectangle."""

    type: Literal['rect']
    fill: bool
    stroke: bool
    color: str
    width: float


class PdfLine(PdfBaseObject):
    """A straight line segment."""

    type: Literal['line']
    stroke: bool
    color: str
    width: float


class PdfCurve(PdfBaseObject):
    """A curve, flattened to the points that define it."""

    type: Literal['curve']
    points: list[list[float]]
    stroke: bool


class PdfImage(PdfBaseObject):
    """An embedded image XObject; ``stream_id`` addresses its raw bytes."""

    type: Literal['image']
    width: float
    height: float
    stream_id: str
    format: str


class PdfTable(PdfBaseObject):
    """A detected table; ``cells`` holds extracted cell *text*."""

    type: Literal['table']
    rows: int
    cols: int
    cells: list[list[str]]


PdfObject = Union[PdfChar, PdfWord, PdfRect, PdfLine, PdfCurve, PdfImage, PdfTable]


class PageData(TypedDict):
    """Everything ``extract_page()`` returns for one page."""

    width: float
    height: float
    chars: list[PdfChar]
    words: list[PdfWord]
    rects: list[PdfRect]
    lines: list[PdfLine]
    curves: list[PdfCurve]
    images: list[PdfImage]
    tables: list[PdfTable]


# --- document metadata -----------------------------------------------------


class PdfMetadata(TypedDict):
    """Document-level facts, as returned by ``PdfExtractor.get_metadata()``."""

    pages: int
    version: str
    encrypted: bool
    page_w: float
    page_h: float
    title: str
    author: str
    producer: str
    fonts: list[str]


class FontStat(TypedDict):
    """Per-font usage statistics, as returned by ``PdfExtractor.analyze_fonts()``."""

    fontname: str
    pages: list[int]
    charCount: int
    sizeMin: float
    sizeMax: float
    colors: list[str]


class FontStats(TypedDict):
    """Container for ``analyze_fonts()``; fonts are sorted by charCount desc."""

    fonts: list[FontStat]
