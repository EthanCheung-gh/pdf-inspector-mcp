"""Shared pytest fixtures for the pdf-inspector-mcp test suite.

``tests/`` is put on ``sys.path`` so the plain ``pdf_fixtures`` helper module is
importable regardless of how pytest was invoked. Fixtures build PDFs inside
``tmp_path`` and hand back paths; ``extractor_for`` closes documents for the
test so no file handle leaks between tests.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Callable, Iterator

import pytest

TESTS_DIR = Path(__file__).resolve().parent
if str(TESTS_DIR) not in sys.path:
    sys.path.insert(0, str(TESTS_DIR))

import pdf_fixtures  # noqa: E402  (needs the sys.path entry above)

from pdf_inspector_mcp.extractor import PdfExtractor  # noqa: E402


@pytest.fixture()
def text_pdf(tmp_path: Path) -> str:
    """Single page containing the word ``alphaword``."""
    return pdf_fixtures.make_text_pdf(tmp_path / 'text.pdf')


@pytest.fixture()
def multipage_pdf(tmp_path: Path) -> str:
    """Three pages, each with different text."""
    return pdf_fixtures.make_multipage_pdf(tmp_path / 'multipage.pdf')


@pytest.fixture()
def table_pdf(tmp_path: Path) -> str:
    """One page with a 2x2 ruled grid and one empty cell."""
    return pdf_fixtures.make_table_pdf(tmp_path / 'table.pdf')


@pytest.fixture()
def image_pdf(tmp_path: Path) -> str:
    """One page with a single embedded PNG image."""
    return pdf_fixtures.make_image_pdf(tmp_path / 'image.pdf')


@pytest.fixture()
def styled_multipage_pdf(tmp_path: Path) -> str:
    """Three pages with a distinct font/size/color mix per page."""
    return pdf_fixtures.make_styled_multipage_pdf(tmp_path / 'styled.pdf')


@pytest.fixture()
def extractor_for() -> Iterator[Callable[..., PdfExtractor]]:
    """Factory opening a ``PdfExtractor`` and closing it after the test."""

    opened: list[PdfExtractor] = []

    def factory(path: str, password: str | None = None) -> PdfExtractor:
        extractor = PdfExtractor(path, password)
        opened.append(extractor)
        return extractor

    yield factory

    for extractor in opened:
        try:
            extractor.close()
        except Exception:  # pragma: no cover - closing must never mask a failure
            pass
