"""Port of pdf-inspector ``src/renderer/services/__tests__/export-data.test.ts``.

Every upstream ``it`` block has a Python counterpart whose name mirrors the TS
case name (see the module tail for the extra Python-only cases). Fixtures are
structurally identical to ``makePage()``/``makeTablePage()`` -- integers stay
integers -- so the CSV golden strings can be asserted byte-for-byte.
"""

from __future__ import annotations

import json
import re
from datetime import datetime, timedelta, timezone

import pytest

from pdf_inspector_mcp import export, objects
from pdf_inspector_mcp.export import (
    EXPORT_OBJECT_TYPES,
    objects_to_csv,
    objects_to_json,
    pages_to_csv,
    pages_to_json,
    resolve_types,
    suggest_filename,
)

METADATA = {
    'pages': 1,
    'version': '1.7',
    'encrypted': False,
    'page_w': 612,
    'page_h': 792,
    'title': 'Demo',
    'author': 'A',
    'producer': 'P',
    'fonts': ['F1'],
}


def make_page():
    """Same shape and same integer types as the TS ``makePage()`` fixture."""

    return {
        'width': 612,
        'height': 792,
        'chars': [{
            'type': 'char', 'x0': 1, 'y0': 2, 'x1': 3, 'y1': 4, 'page': 1,
            'text': 'a,"b\nc', 'fontname': 'F1', 'size': 12, 'color': '#000000',
        }],
        'words': [{
            'type': 'word', 'x0': 1, 'y0': 2, 'x1': 9, 'y1': 4, 'page': 1,
            'text': 'hello', 'fontname': 'F1', 'size': 12,
        }],
        'rects': [{
            'type': 'rect', 'x0': 0, 'y0': 0, 'x1': 10, 'y1': 10, 'page': 1,
            'fill': True, 'stroke': False, 'color': '#ff0000', 'width': 1,
        }],
        'lines': [{
            'type': 'line', 'x0': 0, 'y0': 0, 'x1': 10, 'y1': 0, 'page': 1,
            'stroke': True, 'color': '#00ff00', 'width': 0.5,
        }],
        'curves': [{
            'type': 'curve', 'x0': 0, 'y0': 0, 'x1': 5, 'y1': 5, 'page': 1,
            'points': [[0, 0], [5, 5]], 'stroke': True,
        }],
        'images': [{
            'type': 'image', 'x0': 0, 'y0': 0, 'x1': 20, 'y1': 20, 'page': 1,
            'width': 20, 'height': 20, 'stream_id': 'p1_img_0', 'format': 'png',
        }],
        'tables': [{
            'type': 'table', 'x0': 0, 'y0': 0, 'x1': 50, 'y1': 50, 'page': 1,
            'rows': 2, 'cols': 2, 'cells': [['h1', 'h2'], ['v1', 'v2']],
        }],
    }


def section_titles(csv_text):
    """Section titles in order, with the BOM stripped from the first line."""

    return [
        line[1:] if line.startswith('\uFEFF') else line
        for line in csv_text.split('\n')
        if (line.lstrip('\uFEFF')).startswith('# ')
    ]


def make_table_page(page, text):
    return {
        'width': 612,
        'height': 792,
        'chars': [],
        'words': [],
        'rects': [],
        'lines': [],
        'curves': [],
        'images': [],
        'tables': [{
            'type': 'table', 'x0': 0, 'y0': 0, 'x1': 10, 'y1': 10, 'page': page,
            'rows': 1, 'cols': 1, 'cells': [[text]],
        }],
    }


OBJECTS = [
    {
        'type': 'char', 'x0': 0, 'y0': 1, 'x1': 2, 'y1': 3, 'page': 2,
        'text': 'hi, "there"', 'fontname': 'Helvetica', 'size': 12,
        'color': '#000000',
    },
    {
        'type': 'rect', 'x0': 4, 'y0': 5, 'x1': 6, 'y1': 7, 'page': 2,
        'fill': True, 'stroke': False, 'color': '#ff0000', 'width': 1,
    },
]

ALL_PAGE_KEYS = ('chars', 'words', 'rects', 'lines', 'curves', 'images', 'tables')


# --- pagesToJson -----------------------------------------------------------


def test_pages_to_json_produces_parseable_json_with_metadata_page_count_and_pages():
    parsed = json.loads(pages_to_json([make_page()], METADATA))
    assert parsed['metadata'] == METADATA
    assert parsed['pageCount'] == 1
    assert len(parsed['pages']) == 1
    assert parsed['pages'][0]['chars'][0]['text'] == 'a,"b\nc'
    assert isinstance(parsed['exportedAt'], str)


def test_pages_to_json_includes_every_type_by_default_undefined_or_explicit_all():
    implicit = json.loads(pages_to_json([make_page()], METADATA))
    explicit_undefined = json.loads(pages_to_json([make_page()], METADATA, None))
    explicit_all = json.loads(pages_to_json([make_page()], METADATA, EXPORT_OBJECT_TYPES))

    assert implicit['objectTypes'] == list(EXPORT_OBJECT_TYPES)
    assert explicit_undefined['objectTypes'] == list(EXPORT_OBJECT_TYPES)
    assert explicit_all['objectTypes'] == list(EXPORT_OBJECT_TYPES)
    assert explicit_undefined['pages'] == implicit['pages']
    assert explicit_all['pages'] == implicit['pages']
    for key in ALL_PAGE_KEYS:
        assert len(implicit['pages'][0][key]) > 0


def test_pages_to_json_keeps_only_selected_arrays_and_reports_canonical_order():
    parsed = json.loads(pages_to_json([make_page()], METADATA, ['table', 'word']))
    page = parsed['pages'][0]

    assert parsed['metadata'] == METADATA
    assert parsed['pageCount'] == 1
    assert parsed['objectTypes'] == ['word', 'table']
    assert page['width'] == 612
    assert page['height'] == 792
    assert len(page['words']) == 1
    assert page['words'][0]['text'] == 'hello'
    assert len(page['tables']) == 1
    assert page['tables'][0]['cells'][1][1] == 'v2'
    for key in ('chars', 'rects', 'lines', 'curves', 'images'):
        assert page[key] == []


def test_pages_to_json_treats_explicit_empty_selection_as_no_object_data():
    parsed = json.loads(pages_to_json([make_page()], METADATA, []))
    page = parsed['pages'][0]

    assert parsed['objectTypes'] == []
    assert parsed['pageCount'] == 1
    assert page['width'] == 612
    assert page['height'] == 792
    for key in ALL_PAGE_KEYS:
        assert page[key] == []


def test_pages_to_json_ignores_unknown_type_strings_and_deduplicates_selections():
    parsed = json.loads(pages_to_json([make_page()], METADATA, ['char', 'bogus', 'char']))
    assert parsed['objectTypes'] == ['char']
    assert len(parsed['pages'][0]['chars']) == 1
    assert parsed['pages'][0]['words'] == []


# --- pagesToCsv ------------------------------------------------------------


@pytest.fixture(scope='module')
def page_csv():
    return pages_to_csv([make_page()])


def test_pages_to_csv_starts_with_utf8_bom(page_csv):
    assert page_csv[0] == '\uFEFF'


def test_pages_to_csv_contains_one_section_per_object_type_in_order(page_csv):
    sections = ['# chars', '# words', '# rects', '# lines', '# curves', '# images', '# tables']
    last = -1
    for section in sections:
        at = page_csv.index(section)
        assert at > last
        last = at


def test_pages_to_csv_escapes_comma_quote_and_newline_per_rfc4180(page_csv):
    # a,"b\nc  ->  "a,""b\nc"
    assert '"a,""b\nc"' in page_csv


def test_pages_to_csv_writes_chars_header_and_row_with_page_prefix(page_csv):
    assert 'page,x0,y0,x1,y1,text,fontname,size,color' in page_csv
    assert '1,1,2,3,4,"a,""b' in page_csv


def test_pages_to_csv_flattens_table_cells_as_page_table_index_row_col_text(page_csv):
    assert 'page,table_index,row,col,text' in page_csv
    assert '1,0,0,0,h1' in page_csv
    assert '1,0,1,1,v2' in page_csv


def test_pages_to_csv_serializes_curve_points_as_json(page_csv):
    assert '"[[0,0],[5,5]]"' in page_csv


def test_pages_to_csv_keeps_full_output_for_none_and_explicit_all_types(page_csv):
    pages = [make_page()]
    assert pages_to_csv(pages, None) == page_csv
    assert pages_to_csv(pages, EXPORT_OBJECT_TYPES) == page_csv


def test_pages_to_csv_emits_only_selected_sections_in_canonical_order():
    subset_csv = pages_to_csv([make_page()], ['table', 'word'])

    assert subset_csv[0] == '\uFEFF'
    assert section_titles(subset_csv) == ['# words', '# tables']
    assert 'page,x0,y0,x1,y1,text,fontname,size' in subset_csv
    assert '1,1,2,9,4,hello,F1,12' in subset_csv
    assert '1,0,1,1,v2' in subset_csv
    for omitted in ('# chars', '# rects', '# lines', '# curves', '# images'):
        assert omitted not in subset_csv


def test_pages_to_csv_returns_only_bom_when_selection_is_explicitly_empty():
    assert pages_to_csv([make_page()], []) == '\uFEFF'


def test_pages_to_csv_ignores_unknown_types():
    assert pages_to_csv([make_page()], ['bogus']) == '\uFEFF'


def test_pages_to_csv_restarts_table_index_for_each_page():
    multi_page_csv = pages_to_csv(
        [make_table_page(1, 'a'), make_table_page(2, 'b')], ['table']
    )

    assert section_titles(multi_page_csv) == ['# tables']
    assert '1,0,0,0,a' in multi_page_csv
    assert '2,0,0,0,b' in multi_page_csv


# --- suggestFilename -------------------------------------------------------


def test_suggest_filename_builds_page_scoped_and_document_scoped_names():
    assert suggest_filename('/docs/report.pdf', 'page', 3, 'json') == 'report-p3.json'
    assert suggest_filename('C:\\docs\\report.pdf', 'document', 1, 'csv') == 'report-all.csv'


def test_suggest_filename_handles_missing_path_and_non_pdf_extension():
    assert suggest_filename(None, 'page', 1, 'json') == 'document-p1.json'
    assert suggest_filename('/a/b.txt', 'document', 1, 'csv') == 'b.txt-all.csv'


def test_suggest_filename_keeps_local_basename_when_no_source_url_is_given():
    assert suggest_filename(
        '/tmp/report-1a2b3c4d.pdf', 'page', 2, 'json', None
    ) == 'report-1a2b3c4d-p2.json'
    assert suggest_filename(
        '/tmp/report-1a2b3c4d.pdf', 'document', 1, 'csv'
    ) == 'report-1a2b3c4d-all.csv'


def test_suggest_filename_prefers_url_stem_over_temp_file_name():
    assert suggest_filename(
        '/tmp/report-1a2b3c4d.pdf', 'page', 1, 'json', 'https://example.com/docs/report.pdf'
    ) == 'report-p1.json'
    assert suggest_filename(
        '/tmp/report-1a2b3c4d.pdf', 'document', 1, 'csv',
        'https://example.com/docs/report.PDF',
    ) == 'report-all.csv'


def test_suggest_filename_strips_query_and_hash_and_decodes_url_segment():
    assert suggest_filename(
        '/tmp/My%20Report-1a2b3c4d.pdf',
        'page',
        4,
        'csv',
        'https://example.com/files/My%20Report.pdf?token=abc#page=4',
    ) == 'My Report-p4.csv'


def test_suggest_filename_falls_back_to_temp_basename_when_url_has_no_file_name():
    assert suggest_filename(
        '/tmp/Q1-9f8e7d6c.pdf', 'document', 1, 'json', 'https://example.com/'
    ) == 'Q1-9f8e7d6c-all.json'
    assert suggest_filename(
        '/tmp/Q1-9f8e7d6c.pdf', 'page', 2, 'csv', 'https://example.com/downloads/'
    ) == 'Q1-9f8e7d6c-p2.csv'


def test_suggest_filename_does_not_raise_on_malformed_percent_encoding():
    # decodeURIComponent throws on '%E0%A4%A'; upstream swallows it and falls back.
    assert suggest_filename(
        '/tmp/report-1a2b3c4d.pdf', 'page', 1, 'json', 'https://example.com/bad%E0%A4%A.pdf'
    ) == 'report-1a2b3c4d-p1.json'


def test_suggest_filename_does_not_let_encoded_path_separator_escape():
    assert suggest_filename(
        '/tmp/report-1a2b3c4d.pdf', 'page', 1, 'json', 'https://example.com/a%2Fb.pdf'
    ) == 'a_b-p1.json'


# --- objectsToJson ---------------------------------------------------------


def test_objects_to_json_emits_metadata_page_object_count_and_objects():
    parsed = json.loads(objects_to_json(OBJECTS, None, 2))
    assert parsed['page'] == 2
    assert parsed['objectCount'] == 2
    assert parsed['objects'][0]['text'] == 'hi, "there"'


def test_objects_to_json_reports_every_type_in_canonical_order_by_default():
    parsed = json.loads(objects_to_json(OBJECTS, None, 2, None))
    assert parsed['objectTypes'] == list(EXPORT_OBJECT_TYPES)
    assert parsed['objectCount'] == len(OBJECTS)


def test_objects_to_json_filters_objects_and_updates_object_count_and_types():
    parsed = json.loads(objects_to_json(OBJECTS, None, 2, ['rect']))
    assert parsed['page'] == 2
    assert parsed['objectCount'] == 1
    assert parsed['objectTypes'] == ['rect']
    assert len(parsed['objects']) == 1
    assert parsed['objects'][0]['type'] == 'rect'


def test_objects_to_json_treats_explicit_empty_selection_as_no_objects():
    parsed = json.loads(objects_to_json(OBJECTS, None, 2, []))
    assert parsed['objectCount'] == 0
    assert parsed['objectTypes'] == []
    assert parsed['objects'] == []


# --- objectsToCsv ----------------------------------------------------------


def test_objects_to_csv_uses_same_section_headers_with_page_prefixed_rows():
    csv_text = objects_to_csv(OBJECTS, 2)
    assert '# chars' in csv_text
    assert '# rects' in csv_text
    # RFC 4180: text containing comma + quotes is escaped.
    assert '2,0,1,2,3,"hi, ""there"""' in csv_text
    # No table objects: '# tables' section is header-only.
    assert csv_text.endswith('# tables\npage,table_index,row,col,text\n')


def test_objects_to_csv_emits_all_sections_by_default_and_for_all_types():
    all_titles = ['# chars', '# words', '# rects', '# lines', '# curves', '# images', '# tables']
    assert section_titles(objects_to_csv(OBJECTS, 2)) == all_titles
    assert section_titles(objects_to_csv(OBJECTS, 2, EXPORT_OBJECT_TYPES)) == all_titles


def test_objects_to_csv_emits_only_selected_sections_and_their_rows():
    csv_text = objects_to_csv(OBJECTS, 2, ['rect'])
    assert section_titles(csv_text) == ['# rects']
    assert '2,4,5,6,7,true,false,#ff0000,1' in csv_text
    assert '# chars' not in csv_text
    assert '# tables' not in csv_text


def test_objects_to_csv_returns_only_bom_when_selection_is_explicitly_empty():
    assert objects_to_csv(OBJECTS, 2, []) == '\uFEFF'


def test_objects_to_csv_returns_only_bom_when_selection_is_invalid():
    # Upstream asserts both scenarios in one `it`; they are split here.
    assert objects_to_csv(OBJECTS, 2, ['bogus']) == '\uFEFF'


# --- Python-only coverage --------------------------------------------------

ISO_MS_UTC = re.compile(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$')


def test_export_object_types_is_reexported_from_objects():
    assert export.EXPORT_OBJECT_TYPES is objects.EXPORT_OBJECT_TYPES
    assert list(export.EXPORT_OBJECT_TYPES) == [
        'char', 'word', 'rect', 'line', 'curve', 'image', 'table',
    ]


def test_pages_to_json_default_exported_at_uses_iso_utc_with_milliseconds():
    parsed = json.loads(pages_to_json([make_page()], METADATA))
    assert ISO_MS_UTC.match(parsed['exportedAt'])


def test_pages_to_json_exported_at_accepts_an_injected_timestamp():
    moment = datetime(2026, 1, 1, 12, 0, 0, 123456, tzinfo=timezone.utc)
    parsed = json.loads(pages_to_json([make_page()], METADATA, exported_at=moment))
    assert parsed['exportedAt'] == '2026-01-01T12:00:00.123Z'
    assert ISO_MS_UTC.match(parsed['exportedAt'])


def test_objects_to_json_exported_at_normalises_other_timezones_and_naive_values():
    offset = timezone(timedelta(hours=8))
    aware = datetime(2026, 1, 1, 20, 0, 0, 999999, tzinfo=offset)
    parsed = json.loads(objects_to_json(OBJECTS, None, 2, exported_at=aware))
    # 20:00+08:00 == 12:00Z, microseconds truncate like toISOString().
    assert parsed['exportedAt'] == '2026-01-01T12:00:00.999Z'

    naive = datetime(2026, 1, 1, 12, 0, 0)
    parsed_naive = json.loads(objects_to_json(OBJECTS, None, 2, exported_at=naive))
    assert parsed_naive['exportedAt'] == '2026-01-01T12:00:00.000Z'


def test_pages_to_json_does_not_escape_non_ascii_text():
    page = make_page()
    page['chars'][0]['text'] = '中文 “quoted” — naïve'
    raw = pages_to_json([page], METADATA)

    assert '中文 “quoted” — naïve' in raw
    assert '\\u' not in raw
    assert json.loads(raw)['pages'][0]['chars'][0]['text'] == '中文 “quoted” — naïve'


def test_json_top_level_key_order_matches_upstream():
    pages_keys = list(json.loads(pages_to_json([make_page()], METADATA)).keys())
    assert pages_keys == ['metadata', 'exportedAt', 'pageCount', 'objectTypes', 'pages']

    objects_keys = list(json.loads(objects_to_json(OBJECTS, None, 2)).keys())
    assert objects_keys == [
        'metadata', 'exportedAt', 'page', 'objectCount', 'objectTypes', 'objects',
    ]


def test_pages_to_json_page_keys_follow_the_page_dict_order():
    parsed = json.loads(pages_to_json([make_page()], METADATA))
    assert list(parsed['pages'][0].keys()) == ['width', 'height', *ALL_PAGE_KEYS]


def test_pages_to_json_keeps_float_coordinates_and_documents_the_deviation():
    # Python keeps the float type where JS prints `612`; documented in export.py.
    page = make_page()
    page['width'] = 612.0
    raw = pages_to_json([page], METADATA)
    assert '"width": 612.0,' in raw
    assert json.loads(raw)['pages'][0]['width'] == 612.0


def test_pages_to_json_raises_for_unserialisable_values():
    page = make_page()
    page['chars'][0]['text'] = {1, 2}
    with pytest.raises(TypeError):
        pages_to_json([page], METADATA)


def test_resolve_types_none_returns_every_type_in_canonical_order():
    assert resolve_types(None) == [
        'char', 'word', 'rect', 'line', 'curve', 'image', 'table',
    ]


def test_resolve_types_explicit_empty_stays_empty():
    assert resolve_types([]) == []


def test_resolve_types_reports_canonical_order_regardless_of_input_order():
    assert resolve_types(['table', 'char', 'image']) == ['char', 'image', 'table']


def test_resolve_types_deduplicates_and_drops_unknown_values():
    assert resolve_types(['rect', 'rect', 'bogus', 'line', '???']) == ['rect', 'line']


def test_resolve_types_accepts_any_sequence_of_strings():
    assert resolve_types(('word',)) == ['word']
    assert resolve_types(iter(['word'])) == ['word']


def test_resolve_types_rejects_non_iterable_input():
    with pytest.raises(TypeError):
        resolve_types(42)


@pytest.mark.parametrize(
    ('value', 'expected'),
    [
        (True, 'true'),
        (False, 'false'),
        (0, '0'),
        (12, '12'),
        (12.0, '12'),
        (1.0, '1'),
        (-0.0, '0'),
        (0.5, '0.5'),
        (-0.5, '-0.5'),
        (1.25, '1.25'),
        (1e-6, '0.000001'),
        (1e-7, '1e-7'),
        (1e21, '1e+21'),
        ('#000000', '#000000'),
        (None, 'null'),
    ],
)
def test_csv_cells_are_formatted_like_javascript_string(value, expected):
    assert export._csv_cell(value) == expected


@pytest.mark.parametrize(
    ('value', 'expected'),
    [
        ((), ''),
        ([], ''),
        ([0], '0'),
        ((0,), '0'),
        ([0.5], '0.5'),
        ([-0.0], '0'),
        ([1e-7], '1e-7'),
        ((0.1, 0.2, 0.3), '0.1,0.2,0.3'),
        ([0.1, 0.2, 0.3], '0.1,0.2,0.3'),
        ([True, False], 'true,false'),
        ([1.0, 2.0], '1,2'),
        (['a', 'b'], 'a,b'),
        # Array.prototype.join renders null/undefined as an empty element.
        ([None], ''),
        ([None, 1], ',1'),
        # Nested arrays toString recursively.
        ([[0, 0], [5, 5]], '0,0,5,5'),
        ([[None, 1], [2]], ',1,2'),
    ],
)
def test_csv_cells_render_arrays_like_javascript_array_to_string(value, expected):
    assert export._csv_cell(value) == expected


@pytest.mark.parametrize(
    ('color', 'expected_row'),
    [
        # DeviceGray: pdfplumber gives a tuple, String([0]) is '0'.
        ((0,), '1,1,2,3,4,"a,""b\nc",F1,12,0'),
        ((0.0,), '1,1,2,3,4,"a,""b\nc",F1,12,0'),
        ((0.5,), '1,1,2,3,4,"a,""b\nc",F1,12,0.5'),
        # DeviceRGB: joined with ',', then quoted by RFC 4180.
        ((0.1, 0.2, 0.3), '1,1,2,3,4,"a,""b\nc",F1,12,"0.1,0.2,0.3"'),
        ([0.1, 0.2, 0.3], '1,1,2,3,4,"a,""b\nc",F1,12,"0.1,0.2,0.3"'),
        # Empty array: empty cell (trailing comma, nothing after it).
        ([], '1,1,2,3,4,"a,""b\nc",F1,12,'),
        # Strings keep the existing path untouched.
        ('#ff0000', '1,1,2,3,4,"a,""b\nc",F1,12,#ff0000'),
    ],
)
def test_pages_to_csv_char_color_renders_like_upstream(color, expected_row):
    page = make_page()
    page['chars'][0]['color'] = color

    assert pages_to_csv([page], ['char']) == (
        '\uFEFF# chars\n'
        'page,x0,y0,x1,y1,text,fontname,size,color\n'
        f'{expected_row}\n'
    )


def test_objects_to_csv_char_color_uses_the_same_array_rendering():
    char = dict(OBJECTS[0], color=(0.1, 0.2, 0.3))

    csv_text = objects_to_csv([char], 2, ['char'])

    assert csv_text == (
        '\uFEFF# chars\n'
        'page,x0,y0,x1,y1,text,fontname,size,color\n'
        '2,0,1,2,3,"hi, ""there""",Helvetica,12,"0.1,0.2,0.3"\n'
    )


def test_curve_points_stay_compact_json_even_though_arrays_join_otherwise():
    # The array rule must not leak into `points`: upstream JSON-stringifies them.
    page = make_page()

    csv_text = pages_to_csv([page], ['curve'])

    assert csv_text == (
        '\uFEFF# curves\n'
        'page,x0,y0,x1,y1,points,stroke\n'
        '1,0,0,5,5,"[[0,0],[5,5]]",true\n'
    )


@pytest.mark.parametrize(
    ('text', 'expected'),
    [
        ('plain', 'plain'),
        ('a,b', '"a,b"'),
        ('say "hi"', '"say ""hi"""'),
        ('line\nbreak', '"line\nbreak"'),
        ('carriage\rreturn', '"carriage\rreturn"'),
        ('#ff0000', '#ff0000'),
    ],
)
def test_csv_escaping_matches_rfc4180(text, expected):
    assert export._csv_escape(text) == expected


def test_csv_boolean_and_integer_cells_reach_the_output_unquoted():
    page = make_page()
    csv_text = pages_to_csv([page], ['rect', 'line'])

    assert '1,0,0,10,10,true,false,#ff0000,1\n' in csv_text
    assert '1,0,0,10,0,true,#00ff00,0.5\n' in csv_text
    assert 'True' not in csv_text
    assert 'False' not in csv_text


def test_csv_float_integer_coordinates_lose_their_trailing_zero():
    page = make_page()
    page['rects'][0].update({'x0': 0.0, 'y0': 1.0, 'x1': 10.0, 'y1': 10.0, 'width': 1.0})
    csv_text = pages_to_csv([page], ['rect'])

    assert '1,0,1,10,10,true,false,#ff0000,1\n' in csv_text


def test_curve_points_use_compact_json_then_get_quoted():
    page = make_page()
    page['curves'][0]['points'] = [[0.5, 0], [5, -5.25]]
    csv_text = pages_to_csv([page], ['curve'])

    assert '"[[0.5,0],[5,-5.25]]"' in csv_text


def test_pages_to_csv_row_counts_and_trailing_newline():
    csv_text = pages_to_csv([make_page()])

    assert csv_text.endswith('\n')
    assert csv_text.endswith('1,0,1,1,v2\n')
    # 7 titles + 7 headers + 10 data rows (1 char, 1 word, 1 rect, 1 line,
    # 1 curve, 1 image, 4 table cells). The char text carries a newline, so it
    # spans two physical lines, and the trailing newline yields one empty piece.
    assert len(csv_text.split('\n')) == 1 + 7 + 7 + 10 + 1


def test_pages_to_csv_of_empty_page_list_still_emits_headers():
    csv_text = pages_to_csv([], ['table'])

    assert csv_text == '\uFEFF# tables\npage,table_index,row,col,text\n'


def test_objects_to_csv_table_index_follows_filtered_order():
    table_a = {
        'type': 'table', 'x0': 0, 'y0': 0, 'x1': 1, 'y1': 1, 'page': 3,
        'rows': 1, 'cols': 1, 'cells': [['a']],
    }
    table_b = {
        'type': 'table', 'x0': 0, 'y0': 0, 'x1': 1, 'y1': 1, 'page': 3,
        'rows': 1, 'cols': 1, 'cells': [['b']],
    }
    mixed = [OBJECTS[0], table_a, OBJECTS[1], table_b]
    csv_text = objects_to_csv(mixed, 3, ['table'])

    assert '3,0,0,0,a' in csv_text
    assert '3,1,0,0,b' in csv_text


def test_suggest_filename_strips_case_insensitive_pdf_suffix():
    assert suggest_filename('/docs/REPORT.PDF', 'page', 1, 'json') == 'REPORT-p1.json'
    assert suggest_filename('/docs/REPORT.Pdf', 'document', 1, 'csv') == 'REPORT-all.csv'


def test_suggest_filename_empty_path_matches_upstream_behaviour():
    # JS keeps '' (only null/undefined fall back to 'document').
    assert suggest_filename('', 'page', 1, 'json') == '-p1.json'


def test_suggest_filename_unknown_scope_falls_back_to_document_form():
    # Upstream does not validate scope; anything but 'page' means the whole file.
    assert suggest_filename('/docs/report.pdf', 'bogus', 5, 'json') == 'report-all.json'


def test_suggest_filename_relative_source_url_falls_back_to_local_stem():
    # `new URL()` throws for relative input, so the URL stem is unusable.
    assert suggest_filename(
        '/tmp/report-1a2b3c4d.pdf', 'page', 1, 'json', 'not a url'
    ) == 'report-1a2b3c4d-p1.json'


def test_suggest_filename_tolerates_encoded_backslash():
    assert suggest_filename(
        '/tmp/x.pdf', 'page', 1, 'json', 'https://example.com/a%5Cb.pdf'
    ) == 'a_b-p1.json'


@pytest.mark.parametrize(
    'url',
    [
        # decodeURIComponent throws URIError on malformed escapes, so upstream
        # falls back to the local file name.
        'https://example.com/a%zzb.pdf',
        'https://example.com/a%2.pdf',
        'https://example.com/a%',
        # WHATWG dot-segment removal collapses these to the root, which has no
        # file segment. '%2E%2E' is a percent-encoded '..' segment.
        'https://example.com/..',
        'https://example.com/.',
        'https://example.com/a/..',
        'https://example.com/a/.',
        'https://example.com/%2E%2E',
        'https://example.com/a/%2E.',
    ],
)
def test_suggest_filename_falls_back_for_unusable_url_paths(url):
    assert suggest_filename(
        '/tmp/report-1a2b3c4d.pdf', 'page', 1, 'json', url
    ) == 'report-1a2b3c4d-p1.json'


@pytest.mark.parametrize(
    'url',
    [
        'https://example.com/docs/./report.pdf',
        'https://example.com/docs/../files/report.pdf',
        'https://example.com/a//report.pdf',
        'https://example.com/a/b/../../report.pdf',
    ],
)
def test_suggest_filename_normalises_dot_segments_before_picking_a_stem(url):
    assert suggest_filename(
        '/tmp/report-1a2b3c4d.pdf', 'document', 1, 'csv', url
    ) == 'report-all.csv'


@pytest.mark.parametrize(
    ('path', 'expected'),
    [
        ('/', '/'),
        ('/..', '/'),
        ('/a/..', '/'),
        ('/a/.', '/a/'),
        ('/a/./b.pdf', '/a/b.pdf'),
        ('/a/../b.pdf', '/b.pdf'),
        ('/a/b/../../c.pdf', '/c.pdf'),
        ('/a//b.pdf', '/a/b.pdf'),  # empty segments dropped (last one is what matters)
        ('report.pdf', 'report.pdf'),  # opaque path for non-special schemes
    ],
)
def test_url_path_normalisation_matches_whatwg(path, expected):
    assert export._normalize_pathname(path) == expected
