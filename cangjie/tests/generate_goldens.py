#!/usr/bin/env python3
"""Generate the Python baseline ("goldens") the Cangjie integration test asserts on.

Run it from the repository root with the project virtualenv, after the fixtures:

    .venv/bin/python cangjie/tests/generate_fixtures.py
    .venv/bin/python cangjie/tests/generate_goldens.py

For every readable fixture ``<name>.pdf`` in ``fixtures/`` this writes into
``goldens/``:

* ``<name>.metadata.json``   - ``PdfExtractor.get_metadata()``
* ``<name>.page1.json``      - ``PdfExtractor.extract_page(1)`` (not for zero.pdf)
* ``<name>.document.json``   - ``{metadata, pageCount, pages}`` for every page
* ``<name>.fonts.json``      - ``PdfExtractor.analyze_fonts()``
* ``<name>.export.json``     - ``export.pages_to_json(..., exported_at=2026-01-01T00:00:00Z)``
* ``<name>.export.csv``      - ``export.pages_to_csv(...)``

``zero.pdf`` has no page to extract (Python raises ``ValueError`` for page 1), so
it gets no ``page1.json``; its document/export payloads simply hold zero pages.

``errors.json`` records the message fragments the three unreadable fixtures and
the tool-level argument errors produce in the Python server. Each fragment is
checked against the real Python tool while generating, so a golden can never
claim a message the baseline does not actually emit. The full messages are not
stored because they embed absolute paths (or the OS temp directory), which would
make the goldens machine-dependent.

Everything is idempotent: JSON uses ``json.dumps(..., ensure_ascii=False,
indent=2)`` with a trailing newline, and the export timestamp is pinned. If a
fixture changes, rerun both scripts - a stale golden is meant to fail the
Cangjie test, not to be silently accepted.
"""

from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[1]
FIXTURES_DIR = HERE / 'fixtures'
GOLDENS_DIR = HERE / 'goldens'

if str(REPO_ROOT / 'src') not in sys.path:
    sys.path.insert(0, str(REPO_ROOT / 'src'))

from pdf_inspector_mcp import export  # noqa: E402
from pdf_inspector_mcp.document import get_default_manager  # noqa: E402
from pdf_inspector_mcp.extractor import PdfExtractor  # noqa: E402

#: Timestamp pinned into every ``export.json`` so the files never drift.
EXPORTED_AT = datetime(2026, 1, 1, tzinfo=timezone.utc)

#: Fixtures the extractor can open. ``zero.pdf`` is included: it is readable, it
#: just has no page to extract.
READABLE = (
    'text',
    'multipage',
    'table',
    'image',
    'styled',
    'blank',
    'zero',
    'mediabox',
    'jpeg',
    'quoted-table',
    'xref-stream',
    'xref-stream-flate',
)

#: The argument-error cases the tool layer defines, with the fragment each one
#: has to carry. The fragment is a *substring* of the Python message, so the
#: Cangjie test can assert on it without depending on paths or Python reprs.
ERROR_CASES = {
    'garbage': ('pdf_get_metadata', 'not a valid PDF'),
    'encrypted': ('pdf_get_metadata', 'password required or incorrect'),
    'corrupt-stream': ('pdf_extract_page', 'Failed to read'),
    'missing-path': ('pdf_get_metadata', 'Invalid PDF path'),
    'page-out-of-range': ('pdf_extract_page', 'Invalid page number'),
    'page-range': ('pdf_export', 'Invalid page range'),
    'format': ('pdf_export', 'Invalid format'),
    'missing-page': ('pdf_export', 'Missing page'),
    'output-path': ('pdf_export', 'Invalid output_path'),
}


def dump(path: Path, document: object) -> None:
    path.write_text(
        json.dumps(document, ensure_ascii=False, indent=2) + '\n', encoding='utf-8'
    )


def generate_fixture_goldens(name: str) -> None:
    path = str(FIXTURES_DIR / f'{name}.pdf')
    extractor = PdfExtractor(path)
    try:
        metadata = extractor.get_metadata()
        dump(GOLDENS_DIR / f'{name}.metadata.json', metadata)

        if name == 'zero':
            # pdfplumber raises for page 1 of a zero-page document; the document
            # itself is still a valid (empty) payload.
            pages: list[dict] = extractor.extract_pages()
        else:
            dump(GOLDENS_DIR / f'{name}.page1.json', extractor.extract_page(1))
            pages = extractor.extract_pages()

        dump(
            GOLDENS_DIR / f'{name}.document.json',
            {'metadata': metadata, 'pageCount': len(pages), 'pages': pages},
        )
        dump(GOLDENS_DIR / f'{name}.fonts.json', extractor.analyze_fonts())
        dump(
            GOLDENS_DIR / f'{name}.export.json',
            json.loads(
                export.pages_to_json(pages, metadata, None, exported_at=EXPORTED_AT)
            ),
        )
        (GOLDENS_DIR / f'{name}.export.csv').write_text(
            export.pages_to_csv(pages, None), encoding='utf-8'
        )
    finally:
        extractor.close()


def generate_error_goldens() -> None:
    """Verify each expected fragment against the Python server, then store it."""
    from pdf_inspector_mcp import server

    fixture = lambda name: str(FIXTURES_DIR / f'{name}.pdf')  # noqa: E731
    missing_path = str(FIXTURES_DIR / 'does-not-exist.pdf')
    absent_directory = '/nonexistent-pdf-inspector-dir/export.json'

    # (case, callable that must raise the documented error)
    probes = {
        'garbage': lambda: server.pdf_get_metadata(fixture('garbage')),
        'encrypted': lambda: server.pdf_get_metadata(fixture('encrypted')),
        'corrupt-stream': lambda: server.pdf_extract_page(fixture('corrupt-stream'), 1),
        'missing-path': lambda: server.pdf_get_metadata(missing_path),
        'page-out-of-range': lambda: server.pdf_extract_page(fixture('text'), 99),
        'page-range': lambda: server.pdf_export(fixture('text'), first_page=2, last_page=1),
        'format': lambda: server.pdf_export(fixture('text'), format='xml'),
        'missing-page': lambda: server.pdf_export(fixture('text'), scope='page'),
        'output-path': lambda: server.pdf_export(
            fixture('text'), output_path=absent_directory
        ),
    }

    cases: dict[str, dict[str, str]] = {}
    for case, (tool, fragment) in ERROR_CASES.items():
        try:
            probes[case]()
        except ValueError as exc:
            message = str(exc)
        except Exception as exc:  # pragma: no cover - a baseline change worth seeing
            raise SystemExit(
                f'error: {case} raised {type(exc).__name__} instead of a tool error: {exc}'
            ) from exc
        else:
            raise SystemExit(f'error: {case} did not raise at all')
        if fragment not in message:
            raise SystemExit(
                f'error: {case} message does not contain {fragment!r}: {message}'
            )
        cases[case] = {'tool': tool, 'fragment': fragment}

    get_default_manager().close_all()
    dump(GOLDENS_DIR / 'errors.json', {'cases': cases})


def main() -> int:
    GOLDENS_DIR.mkdir(parents=True, exist_ok=True)
    for stale in GOLDENS_DIR.iterdir():
        if stale.is_file():
            stale.unlink()

    for name in READABLE:
        source = FIXTURES_DIR / f'{name}.pdf'
        if not source.is_file():
            raise SystemExit(
                f'error: {source} is missing; run generate_fixtures.py first'
            )
        generate_fixture_goldens(name)
        print(f'goldens: {name}')

    generate_error_goldens()
    print('goldens: errors.json')

    written = sorted(path.name for path in GOLDENS_DIR.iterdir() if path.is_file())
    print(f'\n{len(written)} golden files in {GOLDENS_DIR}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
