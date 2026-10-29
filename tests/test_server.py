"""Tool-level tests: argument handling, payload shapes and the stdio transport.

The tool functions are called directly (they are plain functions; the decorator
only registers them), which keeps the assertions about returned structures
readable. One test then goes through the real MCP stack - a subprocess server,
``stdio_client``, ``initialize``/``list_tools``/``call_tool`` - because the
in-process calls cannot prove that the server actually starts and speaks the
protocol.
"""

from __future__ import annotations

import asyncio
import base64
import json
import re
import sys
from pathlib import Path
from typing import Any

import pytest
from mcp.server.mcpserver.exceptions import ToolError

import pdf_fixtures
from pdf_inspector_mcp import document, server
from pdf_inspector_mcp.export import EXPORT_OBJECT_TYPES
from pdf_inspector_mcp.server import (
    MAX_INLINE_BYTES,
    mcp,
    pdf_analyze_fonts,
    pdf_export,
    pdf_extract_document,
    pdf_extract_page,
    pdf_get_image,
    pdf_get_metadata,
)

TOOL_NAMES = [
    'pdf_get_metadata',
    'pdf_extract_page',
    'pdf_extract_document',
    'pdf_analyze_fonts',
    'pdf_get_image',
    'pdf_export',
]


@pytest.fixture(autouse=True)
def _close_cached_documents():
    """Do not carry open documents (or file handles) from one test to the next."""
    yield
    document.get_default_manager().close_all()


@pytest.fixture()
def jpeg_pdf(tmp_path: Path) -> str:
    """One page whose only XObject is a real JPEG, so image extraction succeeds."""
    jpeg = pdf_fixtures.image_bytes('JPEG')
    return pdf_fixtures.make_single_image_pdf(tmp_path / 'jpeg.pdf', jpeg, 'DCTDecode')


def _make_encrypted_pdf(path: Path, user_password: str = 'userpw') -> str:
    """A one-page PDF encrypted with a user password (needs ``pdf_get_*``'s password)."""
    from reportlab.lib.pdfencrypt import StandardEncryption
    from reportlab.pdfgen import canvas

    c = canvas.Canvas(
        str(path),
        encrypt=StandardEncryption(user_password, ownerPassword='ownerpw', canPrint=1),
    )
    c.setFont('Helvetica', 12)
    c.drawString(72, 700, 'encrypted content')
    c.showPage()
    c.save()
    return str(path)


@pytest.fixture()
def encrypted_pdf(tmp_path: Path) -> str:
    """A PDF that requires the password ``userpw`` to open."""
    return _make_encrypted_pdf(tmp_path / 'encrypted.pdf')


@pytest.fixture()
def garbage_pdf(tmp_path: Path) -> str:
    """A file that exists, is readable, and is not a PDF at all."""
    path = tmp_path / 'garbage.pdf'
    path.write_bytes(b'this file is not a PDF\n' * 8)
    return str(path)


def _quoted_table_pdf(path: Path) -> str:
    """A 2x2 ruled grid whose top-left cell holds ``a,"b`` and ``c`` on two lines.

    pdfplumber joins a cell's text lines with ``\\n``, so the cell value becomes
    ``a,"b\\nc``: a quote *and* an embedded newline, i.e. the worst case for CSV
    quoting and for newline translation when writing to disk.
    """
    from reportlab.lib.pagesizes import letter
    from reportlab.pdfgen import canvas

    c = canvas.Canvas(str(path), pagesize=letter)
    c.rect(50, 650, 300, 80)
    c.line(200, 650, 200, 730)
    c.line(50, 690, 350, 690)
    c.setFont('Helvetica', 10)
    c.drawString(60, 710, 'a,"b')
    c.drawString(60, 698, 'c')
    c.drawString(210, 700, 'plain')
    c.showPage()
    c.save()
    return str(path)


_STREAM_RE = re.compile(rb'stream\n(.*?)endstream', re.S)


def _corrupt_page_stream_pdf(path: Path) -> str:
    """A PDF whose structure is intact but whose page content stream is garbage.

    Built in two steps: reportlab writes a normal one-page document with a
    compressed content stream, then that stream's payload is replaced byte for
    byte with ``0xFF`` (same length, so ``/Length`` and every xref offset stay
    valid). The document therefore still opens - page tree, fonts and metadata are
    readable - but interpreting the page raises ``PdfminerException`` wrapping
    ``ValueError("Non-Ascii85 digit found: ...")``, which is exactly the
    "opens fine, extraction fails" case a real damaged PDF produces.
    """
    from reportlab.lib.pagesizes import letter
    from reportlab.pdfgen import canvas

    c = canvas.Canvas(str(path), pagesize=letter, pageCompression=1)
    c.setFont('Helvetica', 12)
    c.drawString(72, 700, 'page 1 text')
    c.showPage()
    c.save()

    data = path.read_bytes()
    match = _STREAM_RE.search(data)
    assert match is not None, 'the generated PDF has no content stream to corrupt'
    payload = match.group(1)
    path.write_bytes(data[: match.start(1)] + b'\xff' * len(payload) + data[match.end(1):])
    return str(path)


@pytest.fixture()
def corrupt_stream_pdf(tmp_path: Path) -> str:
    """A PDF that opens but whose only page has an unparseable content stream."""
    return _corrupt_page_stream_pdf(tmp_path / 'corrupt-stream.pdf')


# --- registration ----------------------------------------------------------


def test_six_tools_are_registered_with_descriptions() -> None:
    tools = asyncio.run(mcp.list_tools())

    assert sorted(tool.name for tool in tools) == sorted(TOOL_NAMES)
    for tool in tools:
        assert tool.description, f'{tool.name} has no description'
        # structured_output=False: dict results travel as JSON text content.
        assert tool.output_schema is None
        properties = tool.input_schema['properties']
        assert properties['path']['type'] == 'string'
        assert properties['path']['description']
        assert tool.input_schema['required'][0] == 'path'


# --- json serialisability --------------------------------------------------


def test_tool_results_are_json_serialisable(multipage_pdf: str) -> None:
    for payload in [
        pdf_get_metadata(multipage_pdf),
        pdf_extract_page(multipage_pdf, 1),
        pdf_extract_document(multipage_pdf),
        pdf_analyze_fonts(multipage_pdf),
        {key: value for key, value in pdf_export(multipage_pdf).items() if key != 'content'},
    ]:
        json.dumps(payload)  # must not raise


# --- metadata --------------------------------------------------------------


def test_get_metadata_returns_extractor_metadata(multipage_pdf: str) -> None:
    metadata = pdf_get_metadata(multipage_pdf)

    assert metadata['pages'] == 3
    assert metadata['fonts'] == ['Helvetica']
    assert set(metadata) == {
        'pages', 'version', 'encrypted', 'page_w', 'page_h',
        'title', 'author', 'producer', 'fonts',
    }
    # Pure pass-through: no tool-level fields are added.
    assert 'path' not in metadata


def test_get_metadata_loads_nothing_but_metadata(multipage_pdf: str) -> None:
    """Metadata must not force a full page layout (page objects stay unextracted)."""
    metadata = pdf_get_metadata(multipage_pdf)

    assert metadata['page_w'] == pytest.approx(612)
    assert metadata['page_h'] == pytest.approx(792)


def test_tools_reject_missing_files(tmp_path: Path) -> None:
    missing = str(tmp_path / 'absent.pdf')
    for call in [
        lambda: pdf_get_metadata(missing),
        lambda: pdf_extract_page(missing, 1),
        lambda: pdf_extract_document(missing),
        lambda: pdf_analyze_fonts(missing),
        lambda: pdf_get_image(missing, 'p1_img_0'),
        lambda: pdf_export(missing),
    ]:
        with pytest.raises(ValueError):
            call()


# --- unreadable documents --------------------------------------------------


@pytest.mark.parametrize(
    'call',
    [
        pytest.param(lambda path: pdf_get_metadata(path), id='metadata'),
        pytest.param(lambda path: pdf_extract_page(path, 1), id='extract-page'),
        pytest.param(lambda path: pdf_extract_document(path), id='extract-document'),
        pytest.param(lambda path: pdf_analyze_fonts(path), id='analyze-fonts'),
        pytest.param(lambda path: pdf_get_image(path, 'p1_img_0'), id='get-image'),
        pytest.param(lambda path: pdf_export(path), id='export'),
    ],
)
def test_corrupt_file_reports_not_a_valid_pdf(garbage_pdf: str, call: Any) -> None:
    """Every tool opens through the same boundary, so every tool explains a bad file."""
    with pytest.raises(ValueError) as excinfo:
        call(garbage_pdf)

    message = str(excinfo.value)
    assert 'not a valid PDF' in message, message
    assert garbage_pdf in message
    assert message.strip(), 'an error message must never be empty'
    # The original parser message is carried along to make the failure diagnosable.
    assert 'Underlying error:' in message


@pytest.mark.parametrize('tool_name', TOOL_NAMES)
def test_corrupt_file_message_is_never_blank(garbage_pdf: str, tool_name: str) -> None:
    arguments: dict[str, Any] = {'path': garbage_pdf}
    if tool_name == 'pdf_extract_page':
        arguments['page'] = 1
    if tool_name == 'pdf_get_image':
        arguments['stream_id'] = 'p1_img_0'

    with pytest.raises(ValueError) as excinfo:
        getattr(server, tool_name)(**arguments)

    text = str(excinfo.value)
    assert text.startswith('Cannot open ')
    assert text.split('Underlying error:')[-1].strip(), 'the underlying error must be named'


@pytest.mark.parametrize('password', [None, 'wrong', ''])
def test_encrypted_document_without_the_password_explains_password(
    encrypted_pdf: str, password: Any
) -> None:
    """Missing and wrong passwords are both diagnosed as a password problem."""
    with pytest.raises(ValueError) as excinfo:
        pdf_get_metadata(encrypted_pdf, password)

    message = str(excinfo.value)
    assert 'password' in message.lower(), message
    assert "'password'" in message, 'the message should name the argument to pass'
    assert encrypted_pdf in message
    assert 'PDFPasswordIncorrect' in message, 'the parser detail should be present'
    assert message.strip()


@pytest.mark.parametrize('tool_name', TOOL_NAMES)
def test_encrypted_document_password_error_reaches_every_tool(
    encrypted_pdf: str, tool_name: str
) -> None:
    arguments: dict[str, Any] = {'path': encrypted_pdf}
    if tool_name == 'pdf_extract_page':
        arguments['page'] = 1
    if tool_name == 'pdf_get_image':
        arguments['stream_id'] = 'p1_img_0'

    with pytest.raises(ValueError) as excinfo:
        getattr(server, tool_name)(**arguments)

    assert 'password' in str(excinfo.value).lower()
    assert "not a valid PDF" not in str(excinfo.value)


def test_encrypted_document_opens_with_the_right_password(encrypted_pdf: str) -> None:
    metadata = pdf_get_metadata(encrypted_pdf, 'userpw')
    page = pdf_extract_page(encrypted_pdf, 1, 'userpw')

    assert metadata['pages'] == 1
    # Decryption really happened: the text is extractable.
    assert [word['text'] for word in page['words']] == ['encrypted', 'content']


def test_wrong_password_message_differs_from_corrupt_file_message(encrypted_pdf: str, garbage_pdf: str) -> None:
    with pytest.raises(ValueError) as password_error:
        pdf_get_metadata(encrypted_pdf)
    with pytest.raises(ValueError) as corrupt_error:
        pdf_get_metadata(garbage_pdf)

    password_message = str(password_error.value)
    corrupt_message = str(corrupt_error.value)
    assert "pass the 'password' argument" in password_message
    assert 'not a valid PDF' not in password_message
    assert 'not a valid PDF' in corrupt_message
    assert "pass the 'password' argument" not in corrupt_message


# --- documents that open but fail to extract -------------------------------


def test_corrupt_page_stream_still_reports_metadata(corrupt_stream_pdf: str) -> None:
    """The page tree and fonts are readable, so the open phase must not complain."""
    metadata = pdf_get_metadata(corrupt_stream_pdf)

    assert metadata['pages'] == 1
    assert metadata['fonts'] == ['Helvetica']


@pytest.mark.parametrize(
    'call',
    [
        pytest.param(lambda path: pdf_extract_page(path, 1), id='extract-page'),
        pytest.param(lambda path: pdf_extract_document(path), id='extract-document'),
        pytest.param(lambda path: pdf_analyze_fonts(path), id='analyze-fonts'),
        pytest.param(lambda path: pdf_export(path), id='export'),
        pytest.param(lambda path: pdf_get_image(path, 'p1_img_0'), id='get-image'),
    ],
)
def test_corrupt_page_stream_is_reported_as_read_failure(corrupt_stream_pdf: str, call: Any) -> None:
    """A damaged content stream is a client-visible error, distinct from a bad file."""
    with pytest.raises(ValueError) as excinfo:
        call(corrupt_stream_pdf)

    message = str(excinfo.value)
    assert isinstance(excinfo.value, ToolError), 'the message must reach the client'
    assert message.startswith(f"Failed to read '{corrupt_stream_pdf}'"), message
    # The parser's own reason is carried through, so the failure is diagnosable.
    assert 'Non-Ascii85 digit found' in message, message
    assert 'the document opened' in message
    # Open-phase wording must not be reused: this file did open.
    assert 'Cannot open' not in message
    assert 'not a valid PDF' not in message
    assert 'password' not in message.lower()


def test_unwrapped_pdfminer_error_during_extraction_is_classified(
    multipage_pdf: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A raw (non-wrapped) parser exception from the extractor is classified too."""
    from pdfminer.pdfparser import PDFSyntaxError

    from pdf_inspector_mcp.extractor import PdfExtractor

    def explode(self, page_num):  # noqa: ANN001 - mirrors the real signature
        raise PDFSyntaxError('broken content stream')

    monkeypatch.setattr(PdfExtractor, 'extract_page', explode)

    with pytest.raises(ValueError) as excinfo:
        pdf_extract_page(multipage_pdf, 1)

    message = str(excinfo.value)
    assert isinstance(excinfo.value, ToolError)
    assert message.startswith(f"Failed to read '{multipage_pdf}'")
    assert 'broken content stream' in message


def test_unexpected_bug_during_extraction_is_not_disguised_as_user_error(
    multipage_pdf: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    """No ``except Exception``: a real bug must stay a crash, not a "Failed to read"."""
    from pdf_inspector_mcp.extractor import PdfExtractor

    def explode(self, page_num):  # noqa: ANN001 - mirrors the real signature
        raise AttributeError("the extractor has no attribute 'chars'")

    monkeypatch.setattr(PdfExtractor, 'extract_page', explode)

    with pytest.raises(AttributeError) as excinfo:
        pdf_extract_page(multipage_pdf, 1)

    error = excinfo.value
    assert not isinstance(error, ToolError), 'a crash must not become a tool error'
    assert 'Failed to read' not in str(error)

    # This is the message the SDK puts on the wire for a non-ToolError: only the
    # generic name, with the traceback kept in the server log.
    tool = mcp._tool_manager.get_tool('pdf_extract_page')
    assert tool is not None
    with pytest.raises(Exception) as wire:
        asyncio.run(tool.run({'path': multipage_pdf, 'page': 1}, None))  # type: ignore[arg-type]

    assert str(wire.value) == 'Error executing tool pdf_extract_page'
    assert 'Failed to read' not in str(wire.value)


# --- page extraction -------------------------------------------------------


def test_extract_page_returns_page_data(text_pdf: str) -> None:
    page = pdf_extract_page(text_pdf, 1)

    assert set(page) == {'width', 'height', 'chars', 'words', 'rects', 'lines', 'curves', 'images', 'tables'}
    assert page['chars'], 'expected characters on the page'
    assert [word['text'] for word in page['words']] == ['alphaword']
    assert {obj['page'] for obj in page['chars']} == {1}
    assert {obj['type'] for obj in page['chars']} == {'char'}


def test_extract_page_rejects_out_of_range_pages(multipage_pdf: str) -> None:
    for bad_page in (0, 4, -1):
        with pytest.raises(ValueError) as excinfo:
            pdf_extract_page(multipage_pdf, bad_page)
        assert 'document has 3 pages' in str(excinfo.value)
        # Body-level input errors must also be MCP tool errors, or the client only
        # sees "Error executing tool pdf_extract_page".
        assert isinstance(excinfo.value, ToolError)


def test_tool_body_errors_are_client_visible(multipage_pdf: str, tmp_path: Path) -> None:
    """Every tool-level ValueError is an anticipated failure, not a crash."""
    calls = [
        lambda: pdf_extract_page(multipage_pdf, 99),
        lambda: pdf_extract_page(multipage_pdf, 0),
        lambda: pdf_extract_document(multipage_pdf, first_page=5),
        lambda: pdf_analyze_fonts(multipage_pdf, start_page=0),
        lambda: pdf_export(multipage_pdf, format='yaml'),
        lambda: pdf_export(multipage_pdf, scope='page'),
        lambda: pdf_export(multipage_pdf, output_path=str(tmp_path / 'no-dir' / 'x.json')),
    ]
    for call in calls:
        with pytest.raises(ValueError) as excinfo:
            call()
        assert isinstance(excinfo.value, ToolError), str(excinfo.value)
        assert str(excinfo.value).strip()


def test_extract_document_honours_the_page_range(multipage_pdf: str) -> None:
    whole = pdf_extract_document(multipage_pdf)
    assert whole['pageCount'] == 3
    assert len(whole['pages']) == 3
    assert whole['metadata']['pages'] == 3

    part = pdf_extract_document(multipage_pdf, first_page=2, last_page=3)
    assert part['pageCount'] == 2, 'pageCount is the number of exported pages'
    assert [page['chars'][0]['page'] for page in part['pages']] == [2, 3]
    assert part['pages'][0]['words'][0]['text'] == 'page'

    only_second = pdf_extract_document(multipage_pdf, first_page=2, last_page=2)
    assert only_second['pageCount'] == 1


def test_extract_document_rejects_invalid_ranges(multipage_pdf: str) -> None:
    with pytest.raises(ValueError):
        pdf_extract_document(multipage_pdf, first_page=5)
    with pytest.raises(ValueError):
        pdf_extract_document(multipage_pdf, first_page=3, last_page=1)


# --- fonts -----------------------------------------------------------------


def test_analyze_fonts_sorts_by_char_count(styled_multipage_pdf: str) -> None:
    payload = pdf_analyze_fonts(styled_multipage_pdf)

    assert set(payload) == {'fonts'}
    names = [font['fontname'] for font in payload['fonts']]
    counts = [font['charCount'] for font in payload['fonts']]
    assert names == ['Helvetica', 'Courier']
    assert counts == sorted(counts, reverse=True)
    helvetica = payload['fonts'][0]
    assert helvetica['pages'] == [1, 2]
    assert helvetica['charCount'] == 14  # page 1: alpha+beta (9), page 2: gamma (5)
    assert (helvetica['sizeMin'], helvetica['sizeMax']) == (10.0, 14.0)


def test_analyze_fonts_honours_the_page_range(styled_multipage_pdf: str) -> None:
    payload = pdf_analyze_fonts(styled_multipage_pdf, start_page=3, end_page=3)

    assert [font['fontname'] for font in payload['fonts']] == ['Courier']

    with pytest.raises(ValueError):
        pdf_analyze_fonts(styled_multipage_pdf, start_page=9)


# --- images ----------------------------------------------------------------


def test_get_image_returns_base64_and_mime_type(jpeg_pdf: str) -> None:
    page = pdf_extract_page(jpeg_pdf, 1)
    assert len(page['images']) == 1
    stream_id = page['images'][0]['stream_id']
    assert stream_id == 'p1_img_0'

    payload = pdf_get_image(jpeg_pdf, stream_id)

    assert set(payload) == {'base64', 'format', 'mime_type', 'byte_length'}
    assert payload['format'] == 'jpeg'
    assert payload['mime_type'] == 'image/jpeg'
    image = base64.b64decode(payload['base64'])
    assert image.startswith(b'\xff\xd8\xff')
    assert payload['byte_length'] == len(image)


def test_get_image_error_is_passed_through(jpeg_pdf: str) -> None:
    payload = pdf_get_image(jpeg_pdf, 'not-a-stream-id')

    assert set(payload) == {'error'}
    assert 'not-a-stream-id' in payload['error']


def test_get_image_reports_unusable_streams(jpeg_pdf: str) -> None:
    payload = pdf_get_image(jpeg_pdf, 'p9_img_0')
    assert set(payload) == {'error'}


# --- export: inline --------------------------------------------------------


def test_export_json_is_parseable(multipage_pdf: str) -> None:
    result = pdf_export(multipage_pdf)

    assert result['format'] == 'json'
    assert result['scope'] == 'document'
    assert result['inline'] is True
    assert result['object_types'] == list(EXPORT_OBJECT_TYPES)
    assert result['suggested_filename'] == 'multipage-all.json'
    assert result['bytes'] == len(result['content'].encode('utf-8'))

    document_payload = json.loads(result['content'])
    assert set(document_payload) == {'metadata', 'exportedAt', 'pageCount', 'objectTypes', 'pages'}
    assert document_payload['pageCount'] == 3
    assert document_payload['metadata']['pages'] == 3
    assert document_payload['objectTypes'] == list(EXPORT_OBJECT_TYPES)
    assert document_payload['pages'][1]['words'][0]['text'] == 'page'


def test_export_csv_starts_with_bom_and_has_sections(table_pdf: str) -> None:
    result = pdf_export(table_pdf, format='csv')

    content = result['content']
    assert content.startswith('\uFEFF')
    assert '# chars' in content
    assert '# words' in content
    assert '# tables' in content
    assert result['suggested_filename'] == 'table-all.csv'


def test_export_csv_keeps_the_bom_on_disk(table_pdf: str, tmp_path: Path) -> None:
    target = tmp_path / 'table-all.csv'
    result = pdf_export(table_pdf, format='csv', output_path=str(target))

    raw = target.read_bytes()
    assert raw.startswith(b'\xef\xbb\xbf')
    # Byte-exact: no newline translation (CRLF on Windows) may sneak in.
    assert result['bytes'] == len(raw) == target.stat().st_size
    assert b'\r\n' not in raw


def test_export_writes_csv_with_an_embedded_newline_byte_for_byte(tmp_path: Path) -> None:
    """A quoted, multi-line cell must reach disk as a bare ``\\n``, size included."""
    source = _quoted_table_pdf(tmp_path / 'quoted.pdf')
    target = tmp_path / 'quoted.csv'

    inline = pdf_export(source, format='csv', object_types=['table'])
    written = pdf_export(source, format='csv', object_types=['table'], output_path=str(target))

    expected = inline['content'].encode('utf-8')
    raw = target.read_bytes()

    rows = table_rows(raw)
    assert rows[0] == ['page', 'table_index', 'row', 'col', 'text']
    assert rows[1] == ['1', '0', '0', '0', 'a,"b\nc'], 'the cell keeps its quote and its LF'
    assert b'"a,""b\nc"' in raw, 'quoted, doubled quote, bare LF - the RFC 4180 form'
    assert raw == expected, 'the file must be the serialised content, byte for byte'
    assert written['bytes'] == len(raw) == target.stat().st_size
    assert b'\r\n' not in raw, 'no CRLF: embedded newlines must stay LF'


def table_rows(raw: bytes) -> list[list[str]]:
    """Parse the ``# tables`` section of a CSV document written to disk."""
    import csv
    import io

    text = raw.decode('utf-8').lstrip('\uFEFF')
    section = text.split('# tables\n', 1)[1]
    return list(csv.reader(io.StringIO(section, newline='')))


def test_write_export_file_is_byte_exact(tmp_path: Path) -> None:
    """``_write_export_file`` must not translate newlines or alter encoding."""
    content = '\uFEFF# words\r\nrow,"a\nb"\nnon-ascii: 文档\n'
    target = server._write_export_file(str(tmp_path / 'export.csv'), content)

    raw = target.read_bytes()
    assert raw == content.encode('utf-8')
    assert b'\r\n' in raw, 'the CRLF the content itself contains is preserved'
    assert b'a\nb' in raw, 'the bare LF inside the cell is preserved'
    assert raw.count(b'\r\n') == 1, 'no newline was invented'


def test_export_json_written_file_is_exact_bytes(multipage_pdf: str, tmp_path: Path) -> None:
    target = tmp_path / 'doc.json'
    result = pdf_export(multipage_pdf, output_path=str(target))

    raw = target.read_bytes()
    assert result['bytes'] == len(raw) == target.stat().st_size
    assert b'\r\n' not in raw
    assert json.loads(raw.decode('utf-8'))['pageCount'] == 3


def test_export_filters_object_types(table_pdf: str) -> None:
    result = pdf_export(table_pdf, object_types=['word', 'table'])
    payload = json.loads(result['content'])

    assert result['object_types'] == ['word', 'table']
    assert payload['objectTypes'] == ['word', 'table']
    page = payload['pages'][0]
    assert page['words'] and page['tables']
    for empty_type in ('chars', 'rects', 'lines', 'curves', 'images'):
        assert page[empty_type] == [], f'{empty_type} should be filtered out'


def test_export_normalises_object_types(table_pdf: str) -> None:
    result = pdf_export(table_pdf, object_types=['table', 'word', 'bogus', 'word'])

    assert result['object_types'] == ['word', 'table']
    assert json.loads(result['content'])['objectTypes'] == ['word', 'table']


def test_export_csv_only_emits_selected_sections(table_pdf: str) -> None:
    content = pdf_export(table_pdf, format='csv', object_types=['table'])['content']

    assert '# tables' in content
    assert '# chars' not in content
    assert content.startswith('\uFEFF')


def test_export_empty_object_types_selects_nothing(table_pdf: str) -> None:
    """Upstream semantics: an explicit empty list means "no object data"."""
    result = pdf_export(table_pdf, object_types=[])
    payload = json.loads(result['content'])

    assert result['object_types'] == []
    assert payload['objectTypes'] == []
    assert all(payload['pages'][0][key] == [] for key in
               ('chars', 'words', 'rects', 'lines', 'curves', 'images', 'tables'))


def test_export_page_scope_exports_a_single_page(multipage_pdf: str) -> None:
    result = pdf_export(multipage_pdf, scope='page', page=2)
    payload = json.loads(result['content'])

    assert result['suggested_filename'] == 'multipage-p2.json'
    assert payload['pageCount'] == 1
    assert len(payload['pages']) == 1
    assert {obj['page'] for obj in payload['pages'][0]['chars']} == {2}


def test_export_document_scope_honours_first_and_last_page(multipage_pdf: str) -> None:
    payload = json.loads(pdf_export(multipage_pdf, first_page=2, last_page=3)['content'])

    assert payload['pageCount'] == 2
    assert [page['chars'][0]['page'] for page in payload['pages']] == [2, 3]


def test_export_accepts_case_insensitive_format_and_scope(multipage_pdf: str) -> None:
    result = pdf_export(multipage_pdf, format='CSV', scope='Page', page=1)

    assert result['format'] == 'csv'
    assert result['scope'] == 'page'


# --- export: argument validation -------------------------------------------


@pytest.mark.parametrize('bad_format', ['xml', '', None])
def test_export_rejects_unknown_formats(multipage_pdf: str, bad_format: Any) -> None:
    with pytest.raises(ValueError) as excinfo:
        pdf_export(multipage_pdf, format=bad_format)

    message = str(excinfo.value)
    assert "'json'" in message and "'csv'" in message


@pytest.mark.parametrize('bad_scope', ['everything', '', None])
def test_export_rejects_unknown_scopes(multipage_pdf: str, bad_scope: Any) -> None:
    with pytest.raises(ValueError) as excinfo:
        pdf_export(multipage_pdf, scope=bad_scope)

    message = str(excinfo.value)
    assert "'document'" in message and "'page'" in message


def test_export_page_scope_requires_a_page(multipage_pdf: str) -> None:
    with pytest.raises(ValueError) as excinfo:
        pdf_export(multipage_pdf, scope='page')

    message = str(excinfo.value)
    assert 'page' in message
    assert 'scope' in message


def test_export_rejects_non_list_object_types(multipage_pdf: str) -> None:
    with pytest.raises(ValueError):
        pdf_export(multipage_pdf, object_types='word')  # type: ignore[arg-type]


# --- export: to disk -------------------------------------------------------


def test_export_writes_to_output_path(multipage_pdf: str, tmp_path: Path) -> None:
    target = tmp_path / 'nested-export'
    target.mkdir()
    output = target / 'doc.json'

    result = pdf_export(multipage_pdf, output_path=str(output))

    assert Path(result['path']) == output
    assert 'inline' not in result
    assert set(result) == {'path', 'bytes', 'format', 'scope', 'object_types', 'suggested_filename'}
    assert output.exists()
    assert result['bytes'] == output.stat().st_size
    assert json.loads(output.read_text(encoding='utf-8'))['pageCount'] == 3


def test_export_rejects_missing_output_directory(multipage_pdf: str, tmp_path: Path) -> None:
    output = tmp_path / 'no-such-dir' / 'doc.json'

    with pytest.raises(ValueError) as excinfo:
        pdf_export(multipage_pdf, output_path=str(output))

    message = str(excinfo.value)
    assert 'no-such-dir' in message
    assert 'does not exist' in message


def test_export_rejects_directory_output_path(multipage_pdf: str, tmp_path: Path) -> None:
    with pytest.raises(ValueError):
        pdf_export(multipage_pdf, output_path=str(tmp_path))


# --- inline size limit -----------------------------------------------------


def test_export_falls_back_to_temp_file_when_over_the_limit(
    multipage_pdf: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(server, 'MAX_INLINE_BYTES', 200)

    result = pdf_export(multipage_pdf)

    assert result['inline'] is False
    assert 'content' not in result
    assert result['note']
    assert str(server.MAX_INLINE_BYTES) in result['note']
    written = Path(result['path'])
    try:
        assert written.exists()
        assert written.parent == Path(server.tempfile.gettempdir())
        assert written.name.endswith('-multipage-all.json')
        raw = written.read_bytes()
        assert result['bytes'] == len(raw) == written.stat().st_size
        assert b'\r\n' not in raw, 'the temp-file branch must not translate newlines either'
        payload = json.loads(raw.decode('utf-8'))
        assert payload['pageCount'] == 3
    finally:
        written.unlink(missing_ok=True)


def test_export_stays_inline_at_exactly_the_limit(
    multipage_pdf: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    size = pdf_export(multipage_pdf)['bytes']
    monkeypatch.setattr(server, 'MAX_INLINE_BYTES', size)

    assert pdf_export(multipage_pdf)['inline'] is True


def test_extract_page_refuses_oversized_payloads(
    multipage_pdf: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(server, 'MAX_INLINE_BYTES', 50)

    with pytest.raises(ValueError) as excinfo:
        pdf_extract_page(multipage_pdf, 1)

    message = str(excinfo.value)
    assert 'pdf_export' in message
    assert 'output_path' in message


def test_extract_document_refuses_oversized_payloads(
    multipage_pdf: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(server, 'MAX_INLINE_BYTES', 50)

    with pytest.raises(ValueError) as excinfo:
        pdf_extract_document(multipage_pdf)

    message = str(excinfo.value)
    assert 'first_page' in message and 'last_page' in message


def test_default_inline_limit_is_one_megabyte() -> None:
    assert MAX_INLINE_BYTES == 1_000_000


# --- real MCP transport ----------------------------------------------------


async def _stdio_round_trip(
    command: str, pdf_path: str, encrypted_path: str, corrupt_stream_path: str
) -> dict[str, Any]:
    """initialize -> list_tools -> call_tool over a spawned stdio server."""
    from mcp.client.session import ClientSession
    from mcp.client.stdio import StdioServerParameters, stdio_client

    params = StdioServerParameters(
        command=command,
        args=['-m', 'pdf_inspector_mcp.server'],
        # A different cwd proves the server needs neither the repo nor PYTHONPATH.
        cwd=str(Path(pdf_path).parent),
    )

    async with stdio_client(params) as (read_stream, write_stream):
        async with ClientSession(read_stream, write_stream) as session:
            init = await session.initialize()
            tools = await session.list_tools()
            result = await session.call_tool('pdf_get_metadata', {'path': pdf_path})
            # A rejected argument must arrive as an actionable tool error, not as
            # a bare "Error executing tool ..." line.
            failure = await session.call_tool('pdf_export', {'path': pdf_path, 'format': 'xml'})
            # A password failure is the one case where the exception raised by the
            # PDF library carries no message of its own: the client must still learn
            # that a password is what is missing.
            locked = await session.call_tool('pdf_get_metadata', {'path': encrypted_path})
            # A body-level input error (page out of range) must also stay readable.
            overflow = await session.call_tool('pdf_extract_page', {'path': pdf_path, 'page': 999})
            # A document that opens but whose page stream is damaged must say so.
            damaged = await session.call_tool('pdf_extract_page', {'path': corrupt_stream_path, 'page': 1})
            return {
                'server_name': init.server_info.name,
                'tool_names': sorted(tool.name for tool in tools.tools),
                'is_error': result.is_error,
                'text': result.content[0].text,
                'failure_is_error': failure.is_error,
                'failure_text': failure.content[0].text,
                'locked_is_error': locked.is_error,
                'locked_text': locked.content[0].text,
                'overflow_is_error': overflow.is_error,
                'overflow_text': overflow.content[0].text,
                'damaged_is_error': damaged.is_error,
                'damaged_text': damaged.content[0].text,
            }


@pytest.mark.parametrize(
    'resolver',
    [
        pytest.param(lambda: sys.executable, id='python-m-module'),
        pytest.param(
            lambda: str(Path(sys.executable).with_name('pdf-inspector-mcp')),
            id='console-script',
        ),
    ],
)
def test_stdio_transport_end_to_end(
    multipage_pdf: str,
    encrypted_pdf: str,
    corrupt_stream_pdf: str,
    monkeypatch: pytest.MonkeyPatch,
    resolver,
) -> None:
    command = resolver()
    if not Path(command).exists():
        pytest.skip(f'MCP server entry point not available: {command}')

    # The subprocess must import the package without inheriting this session's
    # PYTHONPATH tricks; the editable install provides that. If it does not (a
    # bare checkout), the handshake fails and this test must fail loudly.
    monkeypatch.delenv('PYTHONPATH', raising=False)

    try:
        outcome = asyncio.run(
            asyncio.wait_for(
                _stdio_round_trip(command, multipage_pdf, encrypted_pdf, corrupt_stream_pdf),
                timeout=60,
            )
        )
    except (OSError, ImportError) as exc:  # pragma: no cover - environment-specific
        pytest.skip(f'Cannot start an MCP stdio subprocess here: {exc}')

    assert outcome['server_name'] == 'pdf-inspector'
    assert outcome['tool_names'] == sorted(TOOL_NAMES)
    assert not outcome['is_error']
    payload = json.loads(outcome['text'])
    assert payload['pages'] == 3
    assert 'pages' in outcome['text']

    assert outcome['failure_is_error'] is True
    assert "'json'" in outcome['failure_text'] and "'csv'" in outcome['failure_text']

    # Encrypted document, no password: the password hint must survive the wire.
    assert outcome['locked_is_error'] is True
    assert 'password' in outcome['locked_text'].lower(), outcome['locked_text']
    assert 'PDFPasswordIncorrect' in outcome['locked_text'], outcome['locked_text']
    assert 'not a valid PDF' not in outcome['locked_text']

    # Body-level input error: the reason must survive the wire as well.
    assert outcome['overflow_is_error'] is True
    assert 'Invalid page number: 999' in outcome['overflow_text'], outcome['overflow_text']

    # Document opens, page stream is damaged: the extraction phase must explain it.
    assert outcome['damaged_is_error'] is True
    assert 'Failed to read' in outcome['damaged_text'], outcome['damaged_text']
    assert corrupt_stream_pdf in outcome['damaged_text']
    assert 'Non-Ascii85 digit found' in outcome['damaged_text'], outcome['damaged_text']
