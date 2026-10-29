"""Behavioural tests for ``pdf_inspector_mcp.extractor.PdfExtractor``.

Ported from the upstream sidecar suite (pdf-inspector v0.2.0), which is the
source of truth for every assertion below:

* ``sidecar/__tests__/test_word_geometry.py``  -> word/char geometry
* ``sidecar/__tests__/test_tables.py``         -> table cells are text
* ``sidecar/__tests__/test_metadata_fonts.py`` -> resource-based font scan
* ``sidecar/__tests__/test_analyze_fonts.py``  -> full-document font stats
* ``sidecar/__tests__/test_font_batches.py``   -> page-range font stats
* ``sidecar/__tests__/test_image_preview.py``  -> image preview encoding

The ``SidecarSession`` tests of the upstream suite are not ported (there is no
sidecar in this project); this file adds coverage for the two methods this
project introduced, ``page_count()`` and ``extract_pages()``.
"""

from __future__ import annotations

import base64
import json
import re
from io import BytesIO
from pathlib import Path
from typing import get_args, get_origin, get_type_hints

import pytest
import reportlab
from PIL import Image
from pdfminer.psparser import LIT
from pdfplumber.page import Page as PdfPlumberPage
from reportlab.lib.pagesizes import letter
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen import canvas as rl_canvas

import pdf_fixtures

from pdf_inspector_mcp import objects as pdf_objects
from pdf_inspector_mcp.extractor import PdfExtractor

PNG_SIGNATURE = b'\x89PNG\r\n\x1a\n'
JPX_SIGNATURES = (b'\x00\x00\x00\x0cjP  \r\n\x87\n', b'\xff\x4f\xff\x51')
JBIG2_SIGNATURE = b'\x97JB2\r\n\x1a\n'
BBOX_LIKE = re.compile(r'^\(?-?\d+(\.\d+)?,\s*-?\d+')


# ===========================================================================
# word geometry: word boxes must land on char coordinates for any MediaBox
# ===========================================================================


def _pdfplumber_word_box(y0, y1, page_height, mediabox_top):
    """Mirror pdfplumber's forward char -> word conversion for one glyph box."""
    return {
        'x0': 72.0,
        'x1': 140.0,
        'top': (page_height - y1) + mediabox_top,
        'bottom': (page_height - y0) + mediabox_top,
        'text': 'glyph',
    }


@pytest.mark.parametrize('mediabox_top', [0, -100])
def test_derived_word_range_equals_pdfplumber_char_coords(mediabox_top):
    page_height = 792.0
    char_y0, char_y1 = 517.516, 529.516  # PDF-space box of the glyph

    word = _pdfplumber_word_box(char_y0, char_y1, page_height, mediabox_top)
    y0, y1 = PdfExtractor._word_y_range(word, page_height, mediabox_top)

    # Round-trip through pdfplumber's forward conversion must return the char box.
    assert y0 == pytest.approx(char_y0)
    assert y1 == pytest.approx(char_y1)


@pytest.mark.parametrize('mediabox_top', [0, -100, -250.5])
def test_derived_shift_equals_mediabox_origin(mediabox_top):
    """The difference to the naive height-bottom inversion is exactly mediabox_top."""
    page_height = 792.0
    word = _pdfplumber_word_box(517.516, 529.516, page_height, mediabox_top)

    y0, y1 = PdfExtractor._word_y_range(word, page_height, mediabox_top)
    naive_y0 = page_height - word['bottom']
    naive_y1 = page_height - word['top']

    assert y0 - naive_y0 == pytest.approx(mediabox_top)
    assert y1 - naive_y1 == pytest.approx(mediabox_top)


def test_zero_mediabox_origin_is_a_plain_inversion():
    word = {'top': 62.5, 'bottom': 74.5}
    assert PdfExtractor._word_y_range(word, 792.0, 0.0) == pytest.approx((717.5, 729.5))


def test_word_y0_y1_pass_through_when_provided():
    word = {'y0': 10.0, 'y1': 20.0, 'top': 999.0, 'bottom': 999.0}
    assert PdfExtractor._word_y_range(word, 792.0, -100.0) == (10.0, 20.0)


@pytest.mark.parametrize(
    'mediabox, baseline',
    [
        (b'[0 0 612 792]', 520),      # origin at y = 0
        (b'[0 100 612 892]', 620),    # non-zero MediaBox vertical origin
    ],
)
def test_extracted_words_align_with_chars(tmp_path, extractor_for, mediabox, baseline):
    path = pdf_fixtures.make_mediabox_text_pdf(
        tmp_path / 'text.pdf', mediabox, 'mediaboxword', baseline
    )

    page = extractor_for(path).extract_page(1)

    assert page['height'] == pytest.approx(792.0)
    assert len(page['words']) == 1
    word = page['words'][0]
    assert word['text'] == 'mediaboxword'

    # Both MediaBoxes place the baseline at PDF-space y = 520, so the word box
    # must be identical and must match the glyph box reported for the chars.
    assert word['y0'] == pytest.approx(517.516, abs=0.5)
    assert word['y1'] == pytest.approx(529.516, abs=0.5)

    char_y0 = min(c['y0'] for c in page['chars'])
    char_y1 = max(c['y1'] for c in page['chars'])
    assert word['y0'] == pytest.approx(char_y0, abs=0.01)
    assert word['y1'] == pytest.approx(char_y1, abs=0.01)

    # A word can never fall outside the page box the renderer draws it into.
    assert 0.0 <= word['y0'] < word['y1'] <= page['height']


def test_words_carry_font_attributes(tmp_path, extractor_for):
    """Word objects expose the font/size of their chars (Inspector + filters)."""
    path = tmp_path / 'word-fonts.pdf'
    doc = rl_canvas.Canvas(str(path))
    doc.setFont('Helvetica-Bold', 18)
    doc.drawString(72, 700, 'Font Word')
    doc.save()

    page = extractor_for(str(path)).extract_page(1)

    by_text = {word['text']: word for word in page['words']}
    assert by_text['Font']['fontname'] == 'Helvetica-Bold'
    assert by_text['Font']['size'] == pytest.approx(18.0)
    assert by_text['Word']['fontname'] == 'Helvetica-Bold'
    assert by_text['Word']['size'] == pytest.approx(18.0)


# ===========================================================================
# tables: cells must be text, never pdfplumber bbox tuples
# ===========================================================================


def test_table_cells_contain_text(table_pdf, extractor_for):
    page = extractor_for(table_pdf).extract_page(1)

    assert len(page['tables']) == 1
    table = page['tables'][0]
    assert table['cells'] == [['Header A', 'Header B'], ['', 'Row B1']]
    assert table['rows'] == 2
    assert table['cols'] == 2


def test_table_cells_are_strings_not_bboxes(table_pdf, extractor_for):
    table = extractor_for(table_pdf).extract_page(1)['tables'][0]

    for row in table['cells']:
        for cell in row:
            assert isinstance(cell, str)
            assert not BBOX_LIKE.match(cell), f'cell looks like a bbox tuple: {cell!r}'


def test_table_geometry_and_metadata_fields_preserved(table_pdf, extractor_for):
    table = extractor_for(table_pdf).extract_page(1)['tables'][0]

    assert table['type'] == 'table'
    assert table['page'] == 1
    assert table['x1'] > table['x0']
    assert table['y1'] > table['y0']
    for field in ('x0', 'y0', 'x1', 'y1'):
        assert isinstance(table[field], float)
    # rows/cols must agree with the returned cell matrix.
    assert table['rows'] == len(table['cells'])
    assert table['cols'] == max(len(row) for row in table['cells'])


# ===========================================================================
# get_metadata: font resources, without laying out any page
# ===========================================================================


class _Ref:
    """Stand-in for pdfminer's PDFObjRef."""

    def __init__(self, value):
        self._value = value

    def resolve(self):
        return self._value


class _BrokenRef:
    def resolve(self):
        raise RuntimeError('broken object reference')


class _ExplodingDict(dict):
    def get(self, key, default=None):
        raise RuntimeError('broken font dictionary')


class _AnonymousLiteral:
    """A BaseFont stand-in exposing no ``.name``, forcing the fallback path."""

    def __str__(self):
        return "/'FallbackFont'"


class _FakePageObj:
    def __init__(self, resources):
        self.resources = resources


class _FakePage:
    def __init__(self, resources, width=100.0, height=200.0):
        self.page_obj = _FakePageObj(resources)
        self.width = width
        self.height = height


class _ExplodingResourcesPage:
    width = 100.0
    height = 200.0

    @property
    def page_obj(self):
        raise RuntimeError('broken page object')


class _FakePdf:
    pdf_version = '1.7'
    is_encrypted = False
    metadata = {'Title': 'T', 'Author': 'A', 'Producer': 'P'}

    def __init__(self, pages):
        self.pages = pages

    def close(self):  # pragma: no cover - the fake is never closed by tests
        pass


def _extractor_for_fake_pdf(pages) -> PdfExtractor:
    extractor = PdfExtractor.__new__(PdfExtractor)
    extractor._path = 'fake.pdf'
    extractor._password = None
    extractor._pdf = _FakePdf(pages)
    extractor._font_stats_cache = None
    return extractor


def _forbidden_property(accesses, label):
    def getter(self):
        accesses.append(label)
        raise AssertionError(f'{label} must not be accessed by get_metadata')

    return property(getter)


@pytest.fixture()
def two_font_pdf(tmp_path):
    """Page 1 sets Helvetica, page 2 sets Courier (reportlab embeds both as resources)."""
    path = tmp_path / 'two_fonts.pdf'
    c = rl_canvas.Canvas(str(path), pagesize=letter)
    c.setFont('Helvetica', 12)
    c.drawString(72, 720, 'alpha')
    c.showPage()
    c.setFont('Courier', 12)
    c.drawString(72, 720, 'beta')
    c.save()
    return str(path)


@pytest.fixture()
def blank_pdf(tmp_path):
    """A one-page PDF with no /Font resources at all."""
    return pdf_fixtures.make_blank_pdf(tmp_path / 'blank.pdf')


@pytest.fixture()
def zero_page_pdf(tmp_path):
    """A hand-built PDF with a genuinely empty page tree."""
    return pdf_fixtures.make_zero_page_pdf(tmp_path / 'zero_pages.pdf')


def test_get_metadata_reads_font_resources_without_laying_out_pages(
    two_font_pdf, monkeypatch, extractor_for
):
    accesses: list[str] = []
    monkeypatch.setattr(PdfPlumberPage, 'chars', _forbidden_property(accesses, 'page.chars'))
    monkeypatch.setattr(PdfPlumberPage, 'objects', _forbidden_property(accesses, 'page.objects'))

    metadata = extractor_for(two_font_pdf).get_metadata()

    assert accesses == [], 'metadata must not parse page content'
    assert metadata['fonts'] == ['Courier', 'Helvetica']
    assert metadata['pages'] == 2
    assert metadata['page_w'] == float(letter[0])
    assert metadata['page_h'] == float(letter[1])
    assert isinstance(metadata['version'], str)
    assert metadata['encrypted'] is False
    assert isinstance(metadata['title'], str)
    assert isinstance(metadata['author'], str)
    assert metadata['producer'], 'reportlab always sets /Producer'
    json.dumps(metadata)


def test_get_metadata_reports_no_fonts_for_a_blank_document(blank_pdf, extractor_for):
    metadata = extractor_for(blank_pdf).get_metadata()
    assert metadata['fonts'] == []
    assert metadata['pages'] == 1
    assert metadata['page_w'] == 612.0
    assert metadata['page_h'] == 792.0


def test_metadata_keys_match_the_wire_contract(text_pdf, extractor_for):
    metadata = extractor_for(text_pdf).get_metadata()
    assert set(metadata) == {
        'pages', 'version', 'encrypted', 'page_w', 'page_h',
        'title', 'author', 'producer', 'fonts',
    }
    assert metadata['pages'] == 1
    assert metadata['fonts'] == ['Helvetica']


def test_subset_prefixed_base_font_names_are_returned_as_is(tmp_path, extractor_for):
    vera = Path(reportlab.__file__).parent / 'fonts' / 'Vera.ttf'
    if not vera.exists():  # pragma: no cover - reportlab always ships Vera.ttf
        pytest.skip('reportlab bundled Vera.ttf unavailable')

    pdfmetrics.registerFont(TTFont('MetadataSubsetProbe', str(vera)))
    path = tmp_path / 'subset.pdf'
    c = rl_canvas.Canvas(str(path), pagesize=letter)
    c.setFont('MetadataSubsetProbe', 12)
    c.drawString(72, 720, 'subset text')
    c.showPage()
    c.save()

    extractor = extractor_for(str(path))
    fonts = extractor.get_metadata()['fonts']

    subset = [name for name in fonts if '+' in name]
    assert len(subset) == 1
    name = subset[0]
    # reportlab writes the six-uppercase-letter subset tag; no "/" or quotes leak in.
    assert re.fullmatch(r'[A-Z]{6}\+BitstreamVeraSans-Roman', name), name
    assert not name.startswith(('/', "'"))

    # Independent oracle: the embedded subset is what the page actually renders.
    char_fonts = {f['fontname'] for f in extractor.analyze_fonts()['fonts']}
    assert name in char_fonts


def test_malformed_font_resources_are_skipped_not_raised():
    good_page = _FakePage({
        'Font': _Ref({
            'F1': _Ref({'Type': LIT('Font'), 'Subtype': LIT('Type1'),
                        'BaseFont': LIT('Helvetica')}),
            # Composite (Type0) font: BaseFont lives on the top-level dict.
            'F2': _Ref({'Type': LIT('Font'), 'Subtype': LIT('Type0'),
                        'BaseFont': LIT('ABCDEF+ArialUnicodeMS'),
                        'DescendantFonts': [_BrokenRef()]}),
            # No `.name` on BaseFont: the PSLiteral-style fallback still works.
            'F3': _Ref({'BaseFont': _AnonymousLiteral()}),
            # Every kind of unusable resource below must be ignored.
            'F4': _BrokenRef(),
            'F5': _Ref('not-a-font-dict'),
            'F6': _Ref({'Type': LIT('Font'), 'Subtype': LIT('Type3')}),  # no BaseFont
            'F7': _Ref(_ExplodingDict()),
        }),
    })
    empty_resources_page = _FakePage({})
    garbage_resources_page = _FakePage('not-a-resource-dict')
    exploding_page = _ExplodingResourcesPage()

    extractor = _extractor_for_fake_pdf([
        good_page,
        empty_resources_page,
        garbage_resources_page,
        exploding_page,
    ])

    metadata = extractor.get_metadata()

    assert metadata['fonts'] == ['ABCDEF+ArialUnicodeMS', 'FallbackFont', 'Helvetica']
    assert metadata['pages'] == 4
    assert metadata['title'] == 'T'
    assert metadata['author'] == 'A'
    assert metadata['producer'] == 'P'
    json.dumps(metadata)


# ===========================================================================
# get_metadata: PDF version detection
#
# pdfminer.six 20260107 / pdfplumber 0.11.10 no longer expose ``pdf_version``,
# so the header marker in the file itself is the only reliable source.
# ===========================================================================


class _FakePdfWithoutVersion:
    """A document object as modern pdfplumber reports it: no version attribute."""

    is_encrypted = False
    metadata: dict[str, str] = {}

    def __init__(self, pages=()):
        self.pages = list(pages)

    def close(self):  # pragma: no cover - the fake is never closed by tests
        pass


def _version_extractor(path, pdf=None) -> PdfExtractor:
    """Extractor wired to an arbitrary path/document, without opening a PDF."""
    extractor = PdfExtractor.__new__(PdfExtractor)
    extractor._path = path
    extractor._password = None
    extractor._pdf = pdf if pdf is not None else _FakePdfWithoutVersion()
    extractor._font_stats_cache = None
    return extractor


def _header_version(path) -> str:
    """Independent oracle: the ``%PDF-<version>`` marker in the file's first 1 KiB."""
    header = Path(path).read_bytes()[:1024]
    match = re.search(rb'%PDF-(\d+\.\d+)', header)
    assert match is not None, f'{path} has no PDF header marker'
    return match.group(1).decode('ascii')


@pytest.mark.parametrize('fixture_name', ['text_pdf', 'multipage_pdf', 'table_pdf'])
def test_metadata_version_is_a_real_pdf_version(fixture_name, request):
    """reportlab documents report their header version, never 'unknown'."""
    path = request.getfixturevalue(fixture_name)

    version = _version_extractor(path).get_metadata()['version']

    assert isinstance(version, str)
    assert re.fullmatch(r'\d+\.\d+', version), version
    assert version == _header_version(path)


def test_metadata_version_reads_the_hand_written_header(blank_pdf, extractor_for):
    """Hand-written fixtures carry ``%PDF-1.4``; that exact value must come back."""
    metadata = extractor_for(blank_pdf).get_metadata()

    assert metadata['version'] == '1.4'
    assert metadata['pages'] == 1


def test_metadata_version_comes_from_the_real_extractor(text_pdf, extractor_for):
    """The public path (open the file, read metadata) agrees with the oracle."""
    metadata = extractor_for(text_pdf).get_metadata()

    assert metadata['version'] == _header_version(text_pdf)
    assert metadata['version'] != 'unknown'


def test_version_survives_junk_before_the_header(tmp_path, extractor_for):
    """The spec allows leading junk, so version detection must look past it."""
    clean = pdf_fixtures.make_text_pdf(tmp_path / 'clean.pdf')
    expected = _header_version(clean)

    dirty = tmp_path / 'junk-prefixed.pdf'
    dirty.write_bytes(b'JUNK' * 125 + b'\n' + Path(clean).read_bytes())

    metadata = extractor_for(str(dirty)).get_metadata()

    assert metadata['version'] == expected
    assert metadata['version'] != 'unknown'
    assert metadata['pages'] == 1


def test_version_prefers_the_document_attribute_when_present(tmp_path):
    """When a pdfminer release does expose ``pdf_version``, it is used first."""
    garbage = tmp_path / 'garbage.bin'
    garbage.write_bytes(b'not a pdf at all')

    class _FakePdfWithVersion(_FakePdfWithoutVersion):
        pdf_version = '1.7'

    assert _version_extractor(str(garbage), _FakePdfWithVersion())._detect_pdf_version() == '1.7'


def test_version_is_unknown_for_a_non_pdf_file(tmp_path):
    """A file without a header marker degrades to 'unknown' instead of raising."""
    garbage = tmp_path / 'garbage.bin'
    garbage.write_bytes(b'\x00\x01 definitely not a PDF\n')

    extractor = _version_extractor(str(garbage))

    assert extractor._detect_pdf_version() == 'unknown'
    metadata = extractor.get_metadata()
    assert metadata['version'] == 'unknown'
    assert metadata['pages'] == 0


def test_version_is_unknown_when_the_file_cannot_be_read(tmp_path):
    """Unreadable paths (missing file, directory) must not break metadata."""
    missing = tmp_path / 'does-not-exist.pdf'
    directory = tmp_path / 'adirectory'
    directory.mkdir()

    assert _version_extractor(str(missing))._detect_pdf_version() == 'unknown'
    assert _version_extractor(str(directory))._detect_pdf_version() == 'unknown'
    assert _version_extractor(str(missing)).get_metadata()['version'] == 'unknown'


def test_detect_pdf_version_has_a_docstring_explaining_its_origin():
    docstring = PdfExtractor._detect_pdf_version.__doc__ or ''
    assert 'pdf_version' in docstring
    assert '1024' in docstring or 'header' in docstring.lower()


# ===========================================================================
# analyze_fonts: whole document
# ===========================================================================


@pytest.fixture()
def multi_font_pdf(tmp_path):
    """Two pages: page 1 uses Helvetica at 10 and 14pt, page 2 uses Courier at 12pt."""
    path = tmp_path / 'fonts.pdf'
    c = rl_canvas.Canvas(str(path), pagesize=letter)
    c.setFont('Helvetica', 10)
    c.drawString(50, 700, 'alpha')
    c.setFont('Helvetica', 14)
    c.drawString(50, 650, 'beta')
    c.showPage()
    c.setFont('Courier', 12)
    c.drawString(50, 700, 'gamma')
    c.save()
    return str(path)


@pytest.fixture()
def empty_pdf(tmp_path):
    path = tmp_path / 'empty.pdf'
    c = rl_canvas.Canvas(str(path), pagesize=letter)
    c.showPage()
    c.save()
    return str(path)


def test_aggregates_pages_and_char_counts(multi_font_pdf, extractor_for):
    result = extractor_for(multi_font_pdf).analyze_fonts()
    fonts = {f['fontname']: f for f in result['fonts']}
    assert 'Helvetica' in fonts
    assert fonts['Helvetica']['pages'] == [1]
    assert fonts['Helvetica']['charCount'] == 9  # "alpha"(5) + "beta"(4)
    assert fonts['Helvetica']['sizeMin'] == 10
    assert fonts['Helvetica']['sizeMax'] == 14
    assert 'Courier' in fonts
    assert fonts['Courier']['pages'] == [2]
    assert fonts['Courier']['charCount'] == 5  # "gamma"


def test_sorted_by_char_count_descending(multi_font_pdf, extractor_for):
    result = extractor_for(multi_font_pdf).analyze_fonts()
    counts = [f['charCount'] for f in result['fonts']]
    assert counts == sorted(counts, reverse=True)


def test_colors_deduplicated(multi_font_pdf, extractor_for):
    result = extractor_for(multi_font_pdf).analyze_fonts()
    helvetica = next(f for f in result['fonts'] if f['fontname'] == 'Helvetica')
    assert helvetica['colors'] == sorted(set(helvetica['colors']))


def test_empty_document_returns_empty_fonts(empty_pdf, extractor_for):
    result = extractor_for(empty_pdf).analyze_fonts()
    assert result['fonts'] == []


def test_analyze_fonts_computes_once_and_returns_the_cached_result(
    two_font_pdf, monkeypatch, extractor_for
):
    extractor = extractor_for(two_font_pdf)
    calls: list[int] = []
    original = extractor._compute_font_stats

    def spy():
        calls.append(1)
        return original()

    monkeypatch.setattr(extractor, '_compute_font_stats', spy)

    first = extractor.analyze_fonts()
    second = extractor.analyze_fonts()

    assert len(calls) == 1, 'second analyze_fonts() must be served from the cache'
    assert first == second
    assert first['fonts'], 'fixture documents have fonts'
    json.dumps(first)

    # A cached call must not walk chars again (i.e. no second page layout).
    monkeypatch.setattr(PdfPlumberPage, 'chars', _forbidden_property([], 'page.chars'))
    assert extractor.analyze_fonts() == first
    assert len(calls) == 1


# ===========================================================================
# analyze_fonts: page ranges (batches)
# ===========================================================================


def _fonts_by_name(result):
    return {font['fontname']: font for font in result['fonts']}


def _merge_batches(batches):
    """Re-merge per-range results the way the renderer would.

    Batches are merged in the order they were requested (ascending pages), so
    ``pages`` stays ascending and ``colors`` keeps first-seen order.
    """
    merged = {}
    for batch in batches:
        for font in batch['fonts']:
            entry = merged.setdefault(font['fontname'], {
                'fontname': font['fontname'],
                'pages': [],
                'charCount': 0,
                'sizeMin': font['sizeMin'],
                'sizeMax': font['sizeMax'],
                'colors': [],
            })
            entry['charCount'] += font['charCount']
            entry['sizeMin'] = min(entry['sizeMin'], font['sizeMin'])
            entry['sizeMax'] = max(entry['sizeMax'], font['sizeMax'])
            for color in font['colors']:
                if color not in entry['colors']:
                    entry['colors'].append(color)
            for page in font['pages']:
                if page not in entry['pages']:
                    entry['pages'].append(page)
    return {
        'fonts': sorted(
            merged.values(), key=lambda f: f['charCount'], reverse=True
        )
    }


def test_page_one_only_returns_page_one_data(styled_multipage_pdf, extractor_for):
    result = extractor_for(styled_multipage_pdf).analyze_fonts(1, 1)
    fonts = _fonts_by_name(result)

    assert list(fonts) == ['Helvetica'], "page 3's Courier must not leak into page 1"
    helvetica = fonts['Helvetica']
    assert helvetica['pages'] == [1]
    assert helvetica['charCount'] == 9  # "alpha" (5) + "beta" (4)
    assert helvetica['sizeMin'] == 10
    assert helvetica['sizeMax'] == 14
    assert len(helvetica['colors']) == 2, 'red (alpha) and blue (beta) are distinct'


def test_range_of_two_pages_covers_both(styled_multipage_pdf, extractor_for):
    result = extractor_for(styled_multipage_pdf).analyze_fonts(2, 3)
    fonts = _fonts_by_name(result)

    assert set(fonts) == {'Helvetica', 'Courier'}
    assert fonts['Helvetica']['pages'] == [2]
    assert fonts['Helvetica']['charCount'] == 5  # "gamma"
    assert fonts['Helvetica']['sizeMin'] == 10
    assert fonts['Helvetica']['sizeMax'] == 10
    assert fonts['Courier']['pages'] == [3]
    assert fonts['Courier']['charCount'] == 5  # "delta"
    assert fonts['Courier']['sizeMin'] == 12
    assert fonts['Courier']['sizeMax'] == 12
    # Sorted by charCount descending, exactly like the full analysis.
    counts = [font['charCount'] for font in result['fonts']]
    assert counts == sorted(counts, reverse=True)


def test_one_sided_ranges_default_to_document_bounds(styled_multipage_pdf, extractor_for):
    extractor = extractor_for(styled_multipage_pdf)

    assert extractor.analyze_fonts(2, None) == extractor.analyze_fonts(2, 3)
    assert extractor.analyze_fonts(None, 2) == extractor.analyze_fonts(1, 2)

    tail = _fonts_by_name(extractor.analyze_fonts(2, None))
    assert tail['Helvetica']['pages'] == [2]
    assert tail['Courier']['pages'] == [3]

    head = _fonts_by_name(extractor.analyze_fonts(None, 2))
    assert head['Helvetica']['pages'] == [1, 2]
    assert head['Helvetica']['charCount'] == 14  # 9 on page 1 + 5 on page 2
    assert 'Courier' not in head


def test_range_fields_match_the_full_analysis_for_the_pages_it_covers(
    styled_multipage_pdf, extractor_for
):
    extractor = extractor_for(styled_multipage_pdf)
    full = _fonts_by_name(extractor.analyze_fonts())

    # Pages 1-2 are exactly the pages Helvetica appears on, so every field must
    # be byte-identical to the full-document entry.
    helvetica_batch = _fonts_by_name(extractor.analyze_fonts(1, 2))['Helvetica']
    assert helvetica_batch == full['Helvetica']

    # Same for Courier, which only exists on page 3.
    courier_batch = _fonts_by_name(extractor.analyze_fonts(3, 3))['Courier']
    assert courier_batch == full['Courier']

    # A partial range reports the same sizes/colors for the pages it sees, in
    # first-seen order: page 1 alone introduces red then blue, page 2 reuses
    # that blue instead of introducing a new color.
    page_one = _fonts_by_name(extractor.analyze_fonts(1, 1))['Helvetica']
    page_two = _fonts_by_name(extractor.analyze_fonts(2, 2))['Helvetica']
    assert page_one['colors'] == full['Helvetica']['colors']
    assert page_two['colors'] == [page_one['colors'][1]]
    assert page_two['sizeMin'] == page_two['sizeMax'] == 10


def test_single_page_batches_compose_into_the_full_result(styled_multipage_pdf, extractor_for):
    extractor = extractor_for(styled_multipage_pdf)
    full = extractor.analyze_fonts()

    batches = [extractor.analyze_fonts(page, page) for page in (1, 2, 3)]
    merged = _merge_batches(batches)

    assert merged == full
    assert _fonts_by_name(merged)['Helvetica']['pages'] == [1, 2]
    assert _fonts_by_name(merged)['Helvetica']['charCount'] == 14
    assert [font['fontname'] for font in merged['fonts']] == ['Helvetica', 'Courier']

    # Batches and merged results cross the JSON-RPC / MCP boundary untouched.
    for payload in [*batches, merged, full]:
        json.dumps(payload)


def test_range_neither_reads_nor_replaces_the_full_document_cache(
    styled_multipage_pdf, extractor_for
):
    extractor = extractor_for(styled_multipage_pdf)
    full = extractor.analyze_fonts()
    cached = extractor._font_stats_cache
    assert cached is full

    batch = extractor.analyze_fonts(1, 1)
    assert batch is not full
    assert _fonts_by_name(batch)['Helvetica']['pages'] == [1]
    assert extractor._font_stats_cache is cached, 'a range must not replace the cache'
    assert extractor.analyze_fonts() is full, 'the full result stays memoized'

    # Even a poisoned cache must not leak into a range result.
    sentinel = {'fonts': [{
        'fontname': 'Sentinel', 'pages': [99], 'charCount': 1,
        'sizeMin': 0.0, 'sizeMax': 0.0, 'colors': [],
    }]}
    extractor._font_stats_cache = sentinel
    poisoned = extractor.analyze_fonts(2, 2)
    assert [font['fontname'] for font in poisoned['fonts']] == ['Helvetica']
    assert extractor._font_stats_cache is sentinel


def test_range_recomputes_instead_of_reading_the_cache(
    styled_multipage_pdf, monkeypatch, extractor_for
):
    extractor = extractor_for(styled_multipage_pdf)
    calls = []
    original = extractor._compute_font_stats

    def spy(*args):
        calls.append(args)
        return original(*args)

    monkeypatch.setattr(extractor, '_compute_font_stats', spy)

    extractor.analyze_fonts()
    assert calls == [()], 'the no-arg call keeps using the uncached full computation'

    extractor.analyze_fonts(2, 3)
    assert calls == [(), (2, 3)], 'a range must compute its own pages'


def test_range_first_then_full_still_returns_the_complete_document(
    styled_multipage_pdf, extractor_for
):
    extractor = extractor_for(styled_multipage_pdf)

    batch = extractor.analyze_fonts(2, 2)
    assert _fonts_by_name(batch)['Helvetica']['pages'] == [2]
    assert extractor._font_stats_cache is None, 'a range must not populate the cache'

    full = _fonts_by_name(extractor.analyze_fonts())
    assert full['Helvetica']['pages'] == [1, 2]
    assert full['Helvetica']['charCount'] == 14
    assert full['Courier']['pages'] == [3]
    assert full['Courier']['charCount'] == 5


@pytest.mark.parametrize('start,end', [
    (0, 1),      # zero is not a page number
    (1, 4),      # past the last page
    (2, 1),      # reversed
    (-1, 2),     # negative
    (3, 2),      # reversed, both valid page numbers
])
def test_out_of_bounds_ranges_raise_value_error(styled_multipage_pdf, extractor_for, start, end):
    with pytest.raises(ValueError, match='Invalid page range'):
        extractor_for(styled_multipage_pdf).analyze_fonts(start, end)


def test_out_of_bounds_message_names_the_range_and_document_size(
    styled_multipage_pdf, extractor_for
):
    with pytest.raises(ValueError) as excinfo:
        extractor_for(styled_multipage_pdf).analyze_fonts(0, 5)
    assert str(excinfo.value) == 'Invalid page range: 0-5 (document has 3 pages)'


@pytest.mark.parametrize('start,end', [
    (True, 2),    # bool is an int subclass but not a page number
    (1, False),
    (1.0, 2),     # float
    (1, 2.5),
    ('1', 2),     # str
    (1, '2'),
])
def test_non_integer_page_numbers_are_rejected(
    styled_multipage_pdf, extractor_for, start, end
):
    with pytest.raises(ValueError, match='page numbers must be integers'):
        extractor_for(styled_multipage_pdf).analyze_fonts(start, end)


def test_blank_page_document_is_empty_for_full_and_range(blank_pdf, extractor_for):
    extractor = extractor_for(blank_pdf)
    assert extractor.analyze_fonts() == {'fonts': []}
    # The page exists, it simply has no chars.
    assert extractor.analyze_fonts(1, 1) == {'fonts': []}


def test_zero_page_document_allows_only_the_full_analysis(zero_page_pdf, extractor_for):
    extractor = extractor_for(zero_page_pdf)
    assert extractor.analyze_fonts() == {'fonts': []}

    for start, end in [(1, 1), (None, 1), (1, None), (1, 0)]:
        with pytest.raises(ValueError, match='Invalid page range'):
            extractor.analyze_fonts(start, end)


# ===========================================================================
# image preview encoding
# ===========================================================================


def _decode(payload: dict) -> bytes:
    return base64.b64decode(payload['base64'])


@pytest.mark.parametrize(
    'data, expected',
    [
        (PNG_SIGNATURE + b'\x00' * 8, 'png'),
        (b'\xff\xd8\xff\xe0' + b'\x00' * 8, 'jpeg'),
        (b'GIF89a' + b'\x00' * 8, 'gif'),
        (b'GIF87a' + b'\x00' * 8, 'gif'),
        (b'RIFF\x00\x00\x00\x00WEBPVP8 ' + b'\x00' * 8, 'webp'),
        (JPX_SIGNATURES[0] + b'\x00' * 8, 'jpx'),
        (JPX_SIGNATURES[1] + b'\x00' * 8, 'jpx'),
        (JBIG2_SIGNATURE + b'\x00' * 8, 'jbig2'),
        (b'not an image at all', None),
        (b'', None),
    ],
)
def test_detect_image_format_signatures(data, expected):
    assert PdfExtractor._detect_image_format(data) == expected


@pytest.mark.parametrize(
    'fmt, expected',
    [('PNG', 'png'), ('JPEG', 'jpeg'), ('GIF', 'gif'), ('WEBP', 'webp')],
)
def test_browser_renderable_formats_pass_through_unchanged(fmt, expected):
    data = pdf_fixtures.image_bytes(fmt)
    payload = PdfExtractor._encode_for_preview(data)

    assert payload['format'] == expected
    assert _decode(payload) == data


@pytest.mark.parametrize('fmt', ['BMP', 'TIFF'])
def test_non_renderable_formats_are_transcoded_to_png(fmt):
    data = pdf_fixtures.image_bytes_or_none(fmt)
    if data is None:
        pytest.skip(f'Pillow cannot encode {fmt} in this build')

    payload = PdfExtractor._encode_for_preview(data)

    assert payload.get('error') is None
    assert payload['format'] == 'png'
    decoded = _decode(payload)
    assert decoded.startswith(PNG_SIGNATURE)
    with Image.open(BytesIO(decoded)) as image:
        assert image.format == 'PNG'
        assert image.size == (4, 4)


def test_undecodable_payload_reports_error_instead_of_mislabeled_bytes():
    payload = PdfExtractor._encode_for_preview(b'\x00\x01\x02 definitely not an image')

    assert 'base64' not in payload
    assert payload['error']


def test_jbig2_payload_that_pillow_cannot_decode_reports_error():
    payload = PdfExtractor._encode_for_preview(JBIG2_SIGNATURE + b'\x00' * 16)

    # Either Pillow decodes it (then it must be real PNG) or we surface an error.
    if 'error' in payload:
        assert 'base64' not in payload
    else:
        assert payload['format'] == 'png'
        assert _decode(payload).startswith(PNG_SIGNATURE)


def test_embedded_jpeg_stream_passes_through(tmp_path, extractor_for):
    jpeg = pdf_fixtures.image_bytes('JPEG')
    path = pdf_fixtures.make_single_image_pdf(tmp_path / 'dct.pdf', jpeg, 'DCTDecode')

    extractor = extractor_for(path)
    page = extractor.extract_page(1)
    assert len(page['images']) == 1
    payload = extractor.get_image_data(page['images'][0]['stream_id'])

    assert payload['format'] == 'jpeg'
    assert _decode(payload) == jpeg


def test_embedded_jpx_stream_is_transcoded_to_png(tmp_path, extractor_for):
    jpx = pdf_fixtures.image_bytes_or_none('JPEG2000')
    if jpx is None:
        pytest.skip('Pillow cannot encode JPEG2000 in this build')

    path = pdf_fixtures.make_single_image_pdf(tmp_path / 'jpx.pdf', jpx, 'JPXDecode')

    extractor = extractor_for(path)
    page = extractor.extract_page(1)
    payload = extractor.get_image_data(page['images'][0]['stream_id'])

    assert payload.get('error') is None
    assert payload['format'] == 'png'
    with Image.open(BytesIO(_decode(payload))) as image:
        assert image.format == 'PNG'


def test_invalid_stream_id_reports_error(image_pdf, extractor_for):
    extractor = extractor_for(image_pdf)
    for stream_id in ['p1-img-0', 'nonsense', '', 'img_0']:
        assert extractor.get_image_data(stream_id) == {
            'error': f'Invalid stream_id: {stream_id}'
        }


def test_out_of_range_stream_id_reports_error(image_pdf, extractor_for):
    extractor = extractor_for(image_pdf)
    # Page 9 does not exist; index 3 does not exist on page 1.
    for stream_id in ['p9_img_0', 'p1_img_3']:
        payload = extractor.get_image_data(stream_id)
        assert 'error' in payload
        assert 'base64' not in payload


def test_image_objects_expose_stream_id_and_hide_internal_stream_data(
    image_pdf, extractor_for
):
    page = extractor_for(image_pdf).extract_page(1)

    assert len(page['images']) == 1
    image = page['images'][0]
    assert image['type'] == 'image'
    assert image['page'] == 1
    assert image['stream_id'] == 'p1_img_0'
    assert image['format'] == 'unknown'
    assert '_stream_data' not in image, 'internal stream handles must never leak out'
    assert isinstance(image['width'], float)
    assert isinstance(image['height'], float)

    # The preview payload is either a renderable image or a reported error.
    payload = extractor_for(image_pdf).get_image_data(image['stream_id'])
    assert ('error' in payload) or payload['format'] in {'png', 'jpeg', 'gif', 'webp'}


# ===========================================================================
# char color contract: stroking_color may be a string *or* a numeric sequence
# ===========================================================================


def test_char_color_is_a_string_or_a_numeric_sequence(
    text_pdf, styled_multipage_pdf, extractor_for
):
    """Char colors are passed through from pdfplumber, so both shapes occur."""
    for path in (text_pdf, styled_multipage_pdf):
        chars = extractor_for(path).extract_page(1)['chars']
        assert chars, 'the fixtures contain text'
        for char in chars:
            assert isinstance(char['color'], (str, list, tuple)), char['color']

        # Either shape crosses the MCP boundary unchanged (tuples become arrays).
        json.dumps(chars)


def test_rect_and_line_colors_are_always_strings(table_pdf, extractor_for):
    """Rect/line colors go through ``str()`` in the extractor, so they stay text."""
    page = extractor_for(table_pdf).extract_page(1)

    assert page['rects'] or page['lines'], 'the ruled-table fixture draws shapes'
    for obj in [*page['rects'], *page['lines']]:
        assert isinstance(obj['color'], str), obj


def test_objects_declare_char_color_as_string_or_numeric_sequence():
    """The declared contract must match what the extractor really produces."""
    char_color = get_type_hints(pdf_objects.PdfChar)['color']

    assert str in get_args(char_color)
    assert {list, tuple} <= {get_origin(arg) for arg in get_args(char_color)}

    # Rects and lines are stringified, so they stay plain ``str``.
    assert get_type_hints(pdf_objects.PdfRect)['color'] is str
    assert get_type_hints(pdf_objects.PdfLine)['color'] is str


# ===========================================================================
# page_count / extract_pages / page bounds (added by this project)
# ===========================================================================


def test_page_count(multipage_pdf, text_pdf, zero_page_pdf, extractor_for):
    assert extractor_for(multipage_pdf).page_count() == 3
    assert extractor_for(text_pdf).page_count() == 1
    assert extractor_for(zero_page_pdf).page_count() == 0


def test_extract_page_returns_the_documented_page_shape(text_pdf, extractor_for):
    page = extractor_for(text_pdf).extract_page(1)

    assert set(page) == {
        'width', 'height', 'chars', 'words', 'rects', 'lines',
        'curves', 'images', 'tables',
    }
    assert page['width'] == float(letter[0])
    assert page['height'] == float(letter[1])
    assert page['chars'] and page['words']
    json.dumps(page)


@pytest.mark.parametrize('page_num', [0, -1, 4, 99])
def test_extract_page_out_of_range_raises_value_error(multipage_pdf, extractor_for, page_num):
    extractor = extractor_for(multipage_pdf)
    with pytest.raises(ValueError) as excinfo:
        extractor.extract_page(page_num)

    message = str(excinfo.value)
    assert str(page_num) in message
    assert '3 pages' in message, 'the message must state the document size'


@pytest.mark.parametrize('page_num', [1.0, '1', True])
def test_extract_page_rejects_non_integer_page_numbers(multipage_pdf, extractor_for, page_num):
    with pytest.raises(ValueError, match='page numbers must be integers'):
        extractor_for(multipage_pdf).extract_page(page_num)


def test_extract_pages_without_bounds_returns_every_page(multipage_pdf, extractor_for):
    pages = extractor_for(multipage_pdf).extract_pages()

    assert len(pages) == 3
    assert all(page['width'] == float(letter[0]) for page in pages)
    texts = [''.join(word['text'] for word in page['words']) for page in pages]
    assert texts == ['page1content', 'page2content', 'page3content']


def test_extract_pages_range_and_one_sided_bounds(multipage_pdf, extractor_for):
    extractor = extractor_for(multipage_pdf)

    middle = extractor.extract_pages(2, 3)
    assert len(middle) == 2
    assert ''.join(w['text'] for w in middle[0]['words']) == 'page2content'

    tail = extractor.extract_pages(2, None)
    assert len(tail) == 2

    head = extractor.extract_pages(None, 2)
    assert len(head) == 2
    assert ''.join(w['text'] for w in head[-1]['words']) == 'page2content'

    single = extractor.extract_pages(3, 3)
    assert len(single) == 1
    assert all(obj['page'] == 3 for obj in single[0]['words'])


def test_extract_pages_matches_extract_page_per_page(table_pdf, extractor_for):
    extractor = extractor_for(table_pdf)
    assert extractor.extract_pages() == [extractor.extract_page(1)]


@pytest.mark.parametrize('first,last', [(0, 1), (1, 4), (3, 2), (-2, 1)])
def test_extract_pages_out_of_range_raises_value_error(
    multipage_pdf, extractor_for, first, last
):
    with pytest.raises(ValueError) as excinfo:
        extractor_for(multipage_pdf).extract_pages(first, last)

    message = str(excinfo.value)
    assert 'Invalid page range' in message
    assert '3 pages' in message


@pytest.mark.parametrize('first,last', [(True, 2), (1, 2.5), ('1', 2)])
def test_extract_pages_rejects_non_integer_page_numbers(
    multipage_pdf, extractor_for, first, last
):
    with pytest.raises(ValueError, match='page numbers must be integers'):
        extractor_for(multipage_pdf).extract_pages(first, last)


def test_extract_pages_on_a_zero_page_document(zero_page_pdf, extractor_for):
    extractor = extractor_for(zero_page_pdf)

    assert extractor.extract_pages() == []
    with pytest.raises(ValueError, match='Invalid page range'):
        extractor.extract_pages(1, 1)
    with pytest.raises(ValueError, match='Invalid page range'):
        extractor.extract_pages(1, None)


def test_extract_page_detects_no_objects_on_a_blank_page(blank_pdf, extractor_for):
    page = extractor_for(blank_pdf).extract_page(1)

    assert page['width'] == 612.0
    assert page['height'] == 792.0
    for key in ('chars', 'words', 'rects', 'lines', 'curves', 'images', 'tables'):
        assert page[key] == [], f'a blank page has no {key}'
