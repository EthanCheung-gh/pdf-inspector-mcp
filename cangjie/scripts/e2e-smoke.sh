#!/usr/bin/env bash
# End-to-end smoke test for the Cangjie MCP server.
#
# What it does:
#   1. builds the fixtures with `.venv/bin/python` + `tests/pdf_fixtures.py`
#      (plus two script-local extras: an oversized page for the inline limit and
#      a reportlab-encrypted document);
#   2. builds the server with the LTS toolchain the CangjieMagic dependency needs;
#   3. feeds a JSON-RPC conversation over stdio (initialize ->
#      notifications/initialized -> tools/list -> every tool -> error cases) in
#      one server process, so "a bad call does not stop the server" is part of
#      the result rather than an assumption;
#   4. asserts on the real payloads: text, tables, font statistics, image bytes,
#      inline/temp-file exports, error text, and the files written to disk;
#   5. runs the built binary (`target/release/bin/pdf_inspector_mcp`) directly to
#      prove its stdout is pure JSON-RPC - `cjpm run` adds its own progress lines,
#      so only the bare binary can show that a client would not choke on noise;
#   6. validates the wire shape with the official Python SDK
#      (`mcp.types.ListToolsResult` / `InitializeResult`), not just by eye.
#
# `cjpm run` prints its own progress lines on stdout, so the checker parses every
# line and ignores the ones that are not JSON. A failure prints the offending
# response and exits non-zero.
#
# Usage: bash cangjie/scripts/e2e-smoke.sh
#
# Environment overrides: CJV, CJ_TOOLCHAIN, PDF_INSPECTOR_CJ_WORKDIR, PYTHON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${PROJECT_DIR}/.." && pwd)"
CJV="${CJV:-${HOME}/.cjv/bin/cjv}"
TOOLCHAIN="${CJ_TOOLCHAIN:-lts-1.0.0}"
STDX_DIR="${PROJECT_DIR}/libs/cangjie-stdx-linux-x64-1.0.0.1/linux_x86_64_llvm/dynamic/stdx"
PYTHON="${PYTHON:-${REPO_ROOT}/.venv/bin/python}"
WORK_DIR="${PDF_INSPECTOR_CJ_WORKDIR:-/tmp/pdf-inspector-cj}"
DRIVER="${WORK_DIR}/driver.py"

# pdf4cj (standalone sibling project, path dependency) resolves stdx through
# ${CANGJIE_STDX_PATH}.
export CANGJIE_STDX_PATH="${CANGJIE_STDX_PATH:-${REPO_ROOT}/../pdf4cj/stdx/cangjie-stdx-linux-x64-1.0.0.1}"

if [ ! -x "${PYTHON}" ]; then
    echo "error: ${PYTHON} is missing; create the venv and install the dev dependencies first" >&2
    exit 1
fi
if [ ! -d "${STDX_DIR}" ]; then
    echo "error: ${STDX_DIR} is missing; run scripts/setup-stdx.sh first" >&2
    exit 1
fi

mkdir -p "${WORK_DIR}"

# One Python program serves both halves of the conversation: `prepare` writes the
# fixtures and the JSON-RPC request file, `check` asserts on the responses. They
# share the request ids because they are the same file.
cat > "${DRIVER}" <<'PY'
"""Prepare fixtures + requests, then assert on the MCP server's responses."""

from __future__ import annotations

import base64
import json
import shutil
import sys
from pathlib import Path

# Every request in the conversation. One table, so `prepare` and `check` cannot
# drift apart.
IDS = {
    'initialize': 1,
    'tools_list': 2,
    'initialize_supported': 3,
    'initialize_unsupported': 4,
    'metadata': 10,
    'extract_page_text': 11,
    'extract_page_table': 12,
    'analyze_fonts': 13,
    'extract_document': 14,
    'get_image': 15,
    'get_image_bad_stream': 16,
    'get_image_bad_index': 17,
    'export_json_inline': 18,
    'export_csv_file': 19,
    'export_csv_inline': 20,
    'export_big_temp': 21,
    'extract_page_big': 22,
    'get_image_png': 23,
    'export_page_scope': 24,
    'metadata_null_password': 25,
    'error_missing_path': 30,
    'error_bad_page': 31,
    'error_bad_format': 32,
    'error_missing_page': 33,
    'error_bad_range': 34,
    'error_encrypted': 35,
    'error_directory': 36,
    'error_not_pdf': 37,
    'error_output_path_empty': 38,
    'error_output_path_directory': 39,
    'still_alive': 40,
}

TABLE_CELLS = [['Header A', 'Header B'], ['', 'Row B1']]

# Ids of the standalone-binary conversation (kept apart from the main ids so a
# stray response from either process would be obvious).
BINARY_IDS = {
    'initialize': 100,
    'tools_list': 101,
    'ping': 102,
}

EXPECTED_REQUIRED = {
    'pdf_get_metadata': ['path'],
    'pdf_extract_page': ['path', 'page'],
    'pdf_extract_document': ['path'],
    'pdf_analyze_fonts': ['path'],
    'pdf_get_image': ['path', 'stream_id'],
    'pdf_export': ['path'],
}


# --- prepare ---------------------------------------------------------------


def make_fixtures(repo_root: Path, work: Path) -> dict[str, Path]:
    """Write every fixture the conversation needs and return their paths."""
    sys.path.insert(0, str(repo_root / 'tests'))
    import pdf_fixtures as fixtures

    from reportlab.lib import pdfencrypt
    from reportlab.lib.pagesizes import letter
    from reportlab.pdfgen import canvas as rl_canvas

    work.mkdir(parents=True, exist_ok=True)
    paths = {
        'text': Path(fixtures.make_text_pdf(work / 'text.pdf')),
        'multipage': Path(fixtures.make_multipage_pdf(work / 'multipage.pdf')),
        'table': Path(fixtures.make_table_pdf(work / 'table.pdf')),
        'image': Path(fixtures.make_image_pdf(work / 'image.pdf')),
        'styled': Path(fixtures.make_styled_multipage_pdf(work / 'styled.pdf')),
        'blank': Path(fixtures.make_blank_pdf(work / 'blank.pdf')),
        'zero': Path(fixtures.make_zero_page_pdf(work / 'zero.pdf')),
        'mediabox': Path(fixtures.make_mediabox_text_pdf(work / 'mediabox.pdf')),
        'jpeg': Path(
            fixtures.make_single_image_pdf(work / 'jpeg.pdf', fixtures.image_bytes('JPEG'), 'DCTDecode', 4)
        ),
    }

    # A single page whose extracted JSON is well over the 1 MB inline limit, so
    # the pdf_extract_page refusal and pdf_export's temp-file fallback both run
    # against real data instead of a mocked size.
    big = work / 'big.pdf'
    canvas = rl_canvas.Canvas(str(big), pagesize=letter)
    canvas.setFont('Helvetica', 5)
    line = 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMN'
    for row in range(110):
        canvas.drawString(20, 20 + row * 6.0, line)
    canvas.showPage()
    canvas.save()
    paths['big'] = big

    # A password-protected document: the Cangjie engine cannot decrypt it and
    # says so, and the tool layer must pass that message through untouched.
    encrypted = work / 'encrypted.pdf'
    canvas = rl_canvas.Canvas(
        str(encrypted), pagesize=letter, encrypt=pdfencrypt.StandardEncryption('secret', canPrint=0)
    )
    canvas.setFont('Helvetica', 12)
    canvas.drawString(72, 700, 'locked')
    canvas.showPage()
    canvas.save()
    paths['encrypted'] = encrypted

    # A readable regular file that is not a PDF at all.
    not_pdf = work / 'not-a-pdf.txt'
    not_pdf.write_text('this is not a PDF\n', encoding='utf-8')
    paths['not_pdf'] = not_pdf
    return paths


def write_requests(work: Path, paths: dict[str, Path]) -> None:
    """Write the JSON-RPC conversation, one message per line."""
    csv_target = work / 'exports' / 'table.csv'
    calls = [
        ('metadata', 'pdf_get_metadata', {'path': str(paths['text'])}),
        ('extract_page_text', 'pdf_extract_page', {'path': str(paths['text']), 'page': 1}),
        ('extract_page_table', 'pdf_extract_page', {'path': str(paths['table']), 'page': 1}),
        ('analyze_fonts', 'pdf_analyze_fonts', {'path': str(paths['styled'])}),
        ('extract_document', 'pdf_extract_document', {'path': str(paths['multipage'])}),
        ('get_image', 'pdf_get_image', {'path': str(paths['jpeg']), 'stream_id': 'p1_img_0'}),
        ('get_image_bad_stream', 'pdf_get_image', {'path': str(paths['jpeg']), 'stream_id': 'not-a-stream-id'}),
        ('get_image_bad_index', 'pdf_get_image', {'path': str(paths['jpeg']), 'stream_id': 'p1_img_3'}),
        ('export_json_inline', 'pdf_export', {'path': str(paths['table']), 'object_types': ['table', 'word']}),
        ('export_csv_file', 'pdf_export',
         {'path': str(paths['table']), 'format': 'csv', 'output_path': str(csv_target)}),
        ('export_csv_inline', 'pdf_export',
         {'path': str(paths['text']), 'format': 'csv', 'object_types': ['word']}),
        ('export_big_temp', 'pdf_export', {'path': str(paths['big']), 'object_types': ['char']}),
        ('extract_page_big', 'pdf_extract_page', {'path': str(paths['big']), 'page': 1}),
        ('get_image_png', 'pdf_get_image', {'path': str(paths['image']), 'stream_id': 'p1_img_0'}),
        ('export_page_scope', 'pdf_export',
         {'path': str(paths['text']), 'scope': 'page', 'page': 1, 'object_types': ['word']}),
        # An explicit `null` for an Option<T> argument is legal (it decodes to
        # None); the advertised schema says so, and this proves the runtime agrees.
        ('metadata_null_password', 'pdf_get_metadata', {'path': str(paths['text']), 'password': None}),
        # Error cases. More traffic follows each of them, so the conversation also
        # proves that a failed call does not stop the server loop.
        ('error_missing_path', 'pdf_get_metadata', {'path': str(work / 'definitely-missing.pdf')}),
        ('error_bad_page', 'pdf_extract_page', {'path': str(paths['text']), 'page': 99}),
        ('error_bad_format', 'pdf_export', {'path': str(paths['text']), 'format': 'xml'}),
        ('error_missing_page', 'pdf_export', {'path': str(paths['text']), 'scope': 'page'}),
        ('error_bad_range', 'pdf_export',
         {'path': str(paths['multipage']), 'first_page': 2, 'last_page': 1}),
        ('error_encrypted', 'pdf_get_metadata', {'path': str(paths['encrypted'])}),
        ('error_directory', 'pdf_get_metadata', {'path': str(work)}),
        ('error_not_pdf', 'pdf_get_metadata', {'path': str(paths['not_pdf'])}),
        ('error_output_path_empty', 'pdf_export', {'path': str(paths['text']), 'output_path': '   '}),
        ('error_output_path_directory', 'pdf_export',
         {'path': str(paths['text']), 'output_path': str(work / 'no-such-directory' / 'x.json')}),
        ('still_alive', 'pdf_get_metadata', {'path': str(paths['zero'])}),
    ]

    requests: list[dict] = [
        {
            'jsonrpc': '2.0',
            'id': IDS['initialize'],
            'method': 'initialize',
            'params': {
                'protocolVersion': '2024-11-05',
                'capabilities': {},
                'clientInfo': {'name': 'e2e-smoke', 'version': '0.0.1'},
            },
        },
        {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
        {'jsonrpc': '2.0', 'id': IDS['tools_list'], 'method': 'tools/list'},
        # Version negotiation: both supported revisions are echoed, anything else
        # is answered with the default one instead of being echoed blindly.
        {
            'jsonrpc': '2.0',
            'id': IDS['initialize_supported'],
            'method': 'initialize',
            'params': {
                'protocolVersion': '2025-06-18',
                'capabilities': {},
                'clientInfo': {'name': 'e2e-smoke', 'version': '0.0.1'},
            },
        },
        {
            'jsonrpc': '2.0',
            'id': IDS['initialize_unsupported'],
            'method': 'initialize',
            'params': {
                'protocolVersion': '9999-01-01',
                'capabilities': {},
                'clientInfo': {'name': 'e2e-smoke', 'version': '0.0.1'},
            },
        },
    ]
    for key, tool_name, arguments in calls:
        requests.append(
            {
                'jsonrpc': '2.0',
                'id': IDS[key],
                'method': 'tools/call',
                'params': {'name': tool_name, 'arguments': arguments},
            }
        )

    target = work / 'requests.jsonl'
    with target.open('w', encoding='utf-8') as handle:
        for request in requests:
            handle.write(json.dumps(request) + '\n')
    print('  wrote %d requests to %s' % (len(requests), target))


def prepare(repo_root: Path, work: Path) -> None:
    shutil.rmtree(work / 'exports', ignore_errors=True)
    (work / 'exports').mkdir(parents=True, exist_ok=True)
    paths = make_fixtures(repo_root, work)
    print('  fixtures in %s' % work)
    for name in sorted(paths):
        print('    %-10s %s' % (name, paths[name]))
    write_requests(work, paths)


def write_binary_requests(work: Path) -> None:
    """The three messages used to check the built binary's stdout is clean."""
    requests = [
        {
            'jsonrpc': '2.0',
            'id': BINARY_IDS['initialize'],
            'method': 'initialize',
            'params': {
                'protocolVersion': '2024-11-05',
                'capabilities': {},
                'clientInfo': {'name': 'e2e-binary', 'version': '0.0.1'},
            },
        },
        {'jsonrpc': '2.0', 'id': BINARY_IDS['tools_list'], 'method': 'tools/list'},
        {'jsonrpc': '2.0', 'id': BINARY_IDS['ping'], 'method': 'ping'},
    ]
    target = work / 'binary-requests.jsonl'
    with target.open('w', encoding='utf-8') as handle:
        for request in requests:
            handle.write(json.dumps(request) + '\n')
    print('  wrote %d requests to %s' % (len(requests), target))


# --- check -----------------------------------------------------------------


class Checker:
    """Collects failures so one bad payload does not hide the rest."""

    def __init__(self, responses: dict[int, dict], noise: int) -> None:
        self.responses = responses
        self.noise = noise
        self.failures: list[str] = []

    def check(self, condition: bool, message: str, detail: object = None) -> None:
        if condition:
            print('  ok   %s' % message)
            return
        print('  FAIL %s' % message)
        if detail is not None:
            print('       %s' % str(detail)[:2000])
        self.failures.append(message)

    def result(self, key: str) -> dict:
        """The `result` object of a tools/call response, or `{}` when absent."""
        message = self.responses.get(IDS[key], {})
        result = message.get('result')
        return result if isinstance(result, dict) else {}

    def text(self, key: str) -> str:
        content = self.result(key).get('content') or []
        if not content:
            return ''
        return content[0].get('text', '')

    def is_error(self, key: str) -> bool:
        return self.result(key).get('isError') is True

    def payload(self, key: str) -> dict:
        try:
            return json.loads(self.text(key))
        except json.JSONDecodeError as error:
            self.check(False, '%s returns JSON' % key, '%s: %s' % (error, self.text(key)))
            return {}

    def failure(self) -> bool:
        return bool(self.failures)


def check_conversation(checker: Checker) -> None:
    print('  parsed %d JSON-RPC responses (%d non-JSON lines ignored)'
          % (len(checker.responses), checker.noise))

    answered = sorted(checker.responses)
    expected = sorted(IDS.values())
    checker.check(answered == expected, 'every request is answered',
                  'answered=%s expected=%s' % (answered, expected))

    init = checker.responses.get(IDS['initialize'], {}).get('result', {})
    checker.check(init.get('protocolVersion') == '2024-11-05',
                  'a supported protocol version is echoed back', init.get('protocolVersion'))
    checker.check(init.get('serverInfo', {}).get('name') == 'pdf-inspector', 'serverInfo.name is pdf-inspector')
    supported = checker.responses.get(IDS['initialize_supported'], {}).get('result', {})
    checker.check(supported.get('protocolVersion') == '2025-06-18',
                  'the second supported protocol version is echoed back', supported.get('protocolVersion'))
    unsupported = checker.responses.get(IDS['initialize_unsupported'], {}).get('result', {})
    checker.check(unsupported.get('protocolVersion') == '2024-11-05',
                  'an unsupported protocol version falls back to 2024-11-05',
                  unsupported.get('protocolVersion'))

    # --- tools/list -------------------------------------------------------
    listing = checker.responses.get(IDS['tools_list'], {}).get('result', {})
    tools = {tool['name']: tool for tool in listing.get('tools', [])}
    checker.check(sorted(tools) == sorted(EXPECTED_REQUIRED), 'tools/list exposes the six tools', sorted(tools))
    for name, tool in tools.items():
        # The MCP shape, not CangjieMagic's internal {name, description, parameters}.
        checker.check(set(tool) == {'name', 'description', 'inputSchema'},
                      '%s is advertised as name/description/inputSchema' % name, sorted(tool))
        schema = tool.get('inputSchema', {})
        checker.check(schema.get('type') == 'object' and isinstance(schema.get('properties'), dict)
                      and isinstance(schema.get('required'), list),
                      '%s.inputSchema is an object schema with properties/required' % name, schema)
    for name, required in EXPECTED_REQUIRED.items():
        actual = tools.get(name, {}).get('inputSchema', {}).get('required')
        checker.check(actual == required, '%s requires %s' % (name, required), actual)

    # `Option<T>` arguments must be advertised as nullable. The server accepts
    # `null` for them (Option<T>.fromJsonValue(JsonNull) is None), so a schema
    # without `null` in it would make a strict client reject a legal call before
    # sending it. Required arguments keep the plain type.
    for name, tool in tools.items():
        properties = tool.get('inputSchema', {}).get('properties', {})
        required_names = tool.get('inputSchema', {}).get('required', [])
        optional = [key for key in properties if key not in required_names]
        checker.check(bool(optional), '%s has at least one optional argument' % name, optional)
        for key in optional:
            schema = properties[key]
            alternatives = schema.get('anyOf') if isinstance(schema, dict) else None
            checker.check(isinstance(alternatives, list) and len(alternatives) == 2
                          and any(isinstance(item, dict) and item.get('type') == 'null'
                                  for item in alternatives),
                          '%s.%s is nullable (anyOf includes null)' % (name, key), schema)
            payload = alternatives[0] if isinstance(alternatives, list) and alternatives else {}
            checker.check(bool(payload.get('type')),
                          '%s.%s keeps its type inside anyOf' % (name, key), payload)
            checker.check(bool(payload.get('description')),
                          '%s.%s keeps its description inside anyOf' % (name, key), payload)
        for key in required_names:
            checker.check('anyOf' not in properties.get(key, {}),
                          '%s.%s (required) keeps a plain, non-nullable schema' % (name, key),
                          properties.get(key))

    export_properties = tools.get('pdf_export', {}).get('inputSchema', {}).get('properties', {})
    checker.check('default' not in export_properties.get('format', {}),
                  'format does not advertise default: null (its default is json, not null)',
                  export_properties.get('format'))
    checker.check('default' not in export_properties.get('scope', {}),
                  'scope does not advertise default: null (its default is document, not null)',
                  export_properties.get('scope'))
    for key in ('password', 'page', 'first_page', 'last_page', 'output_path'):
        checker.check(export_properties.get(key, {}).get('default', 'missing') is None,
                      'pdf_export.%s advertises default: null' % key, export_properties.get(key))

    # The wire shape has to satisfy the *official* client library, not just our
    # own reading of it: a wrong key here is a hard failure for every real client.
    try:
        from mcp.types import InitializeResult, ListToolsResult, Tool
    except ImportError as error:  # pragma: no cover - the venv always has it
        checker.check(False, 'the official MCP SDK is importable', error)
    else:
        try:
            parsed_tools = ListToolsResult.model_validate(listing)
        except Exception as error:  # noqa: BLE001 - the validation message is the point
            checker.check(False, 'mcp.types.ListToolsResult parses the tools/list result', error)
        else:
            checker.check(len(parsed_tools.tools) == 6, 'the official SDK sees six tools',
                          len(parsed_tools.tools))
            checker.check(all(isinstance(tool, Tool) for tool in parsed_tools.tools),
                          'every entry parses as an mcp.types.Tool')
            names = sorted(tool.name for tool in parsed_tools.tools)
            checker.check(names == sorted(EXPECTED_REQUIRED), 'the official SDK parses the tool names', names)
            export_tool = next(tool for tool in parsed_tools.tools if tool.name == 'pdf_export')
            checker.check(export_tool.input_schema.get('required') == ['path'],
                          'the official SDK parses pdf_export.inputSchema.required',
                          export_tool.input_schema.get('required'))
            checker.check(bool(export_tool.description), 'the official SDK parses the description')
            password_schema = export_tool.input_schema.get('properties', {}).get('password', {})
            checker.check(any(isinstance(item, dict) and item.get('type') == 'null'
                              for item in password_schema.get('anyOf', [])),
                          'the official SDK parses the nullable password schema', password_schema)
        try:
            InitializeResult.model_validate(init)
        except Exception as error:  # noqa: BLE001 - the validation message is the point
            checker.check(False, 'mcp.types.InitializeResult parses the initialize result', error)
        else:
            checker.check(True, 'mcp.types.InitializeResult parses the initialize result')

    # --- pdf_get_metadata -------------------------------------------------
    metadata = checker.payload('metadata')
    checker.check(not checker.is_error('metadata'), 'pdf_get_metadata succeeds', checker.text('metadata'))
    checker.check(metadata.get('pages') == 1, 'metadata reports the page count', metadata.get('pages'))
    checker.check(str(metadata.get('version', '')).startswith('1.'), 'metadata reports the PDF version',
                  metadata.get('version'))
    checker.check(metadata.get('encrypted') is False, 'metadata reports the encryption flag')
    checker.check(metadata.get('fonts') == ['Helvetica'], 'metadata lists the referenced fonts',
                  metadata.get('fonts'))

    # `password: null` is what a client sends when the schema allows null and it
    # has no password: the tool must treat it exactly like an omitted argument.
    null_password = checker.payload('metadata_null_password')
    checker.check(not checker.is_error('metadata_null_password'),
                  'an explicit password: null is accepted', checker.text('metadata_null_password'))
    checker.check(null_password.get('pages') == 1, 'password: null behaves like no password',
                  null_password.get('pages'))

    # --- pdf_extract_page -------------------------------------------------
    page = checker.payload('extract_page_text')
    checker.check(not checker.is_error('extract_page_text'), 'pdf_extract_page succeeds (text)')
    words = [word['text'] for word in page.get('words', [])]
    checker.check('alphaword' in words, 'extract_page finds the word alphaword', words)
    checker.check(len(page.get('chars', [])) == len('alphaword'),
                  'extract_page returns one char per glyph', len(page.get('chars', [])))
    checker.check(page.get('width') == 612 and page.get('height') == 792,
                  'extract_page reports the page box', (page.get('width'), page.get('height')))

    table_page = checker.payload('extract_page_table')
    tables = table_page.get('tables') or []
    checker.check(len(tables) == 1, 'extract_page detects one table', len(tables))
    if tables:
        checker.check(tables[0].get('cells') == TABLE_CELLS, 'the table cells match the fixture',
                      tables[0].get('cells'))
        checker.check(tables[0].get('rows') == 2 and tables[0].get('cols') == 2,
                      'the table reports its row/column counts',
                      (tables[0].get('rows'), tables[0].get('cols')))

    # --- pdf_analyze_fonts ------------------------------------------------
    font_payload = checker.payload('analyze_fonts')
    fonts = {font['fontname']: font for font in font_payload.get('fonts', [])}
    checker.check(sorted(fonts) == ['Courier', 'Helvetica'], 'analyze_fonts finds both fonts', sorted(fonts))
    helvetica = fonts.get('Helvetica', {})
    checker.check(helvetica.get('charCount') == 14, 'Helvetica charCount counts every glyph',
                  helvetica.get('charCount'))
    checker.check(helvetica.get('pages') == [1, 2], 'Helvetica pages are ascending and de-duplicated',
                  helvetica.get('pages'))
    checker.check(helvetica.get('sizeMin') == 10 and helvetica.get('sizeMax') == 14,
                  'Helvetica size range spans both sizes',
                  (helvetica.get('sizeMin'), helvetica.get('sizeMax')))
    checker.check(len(helvetica.get('colors', [])) == 2, 'Helvetica keeps two first-seen colours',
                  helvetica.get('colors'))
    courier = fonts.get('Courier', {})
    checker.check(courier.get('charCount') == 5 and courier.get('sizeMin') == 12,
                  'Courier is aggregated separately',
                  (courier.get('charCount'), courier.get('sizeMin')))
    counts = [font['charCount'] for font in font_payload.get('fonts', [])]
    checker.check(counts == sorted(counts, reverse=True), 'fonts are sorted by charCount descending', counts)

    # --- pdf_extract_document ---------------------------------------------
    document = checker.payload('extract_document')
    checker.check(document.get('pageCount') == 3, 'extract_document reports the page count',
                  document.get('pageCount'))
    checker.check(len(document.get('pages', [])) == 3, 'extract_document returns one page per page',
                  len(document.get('pages', [])))
    checker.check(document.get('metadata', {}).get('pages') == 3, 'extract_document embeds the metadata')
    all_pages = document.get('pages') or [{}, {}]
    second_page_words = [word['text'] for word in all_pages[1].get('words', [])]
    checker.check('page' in second_page_words and '2' in second_page_words,
                  'the second page carries its own text', second_page_words)

    # --- pdf_get_image ----------------------------------------------------
    image = checker.payload('get_image')
    checker.check(not checker.is_error('get_image'), 'pdf_get_image succeeds')
    checker.check(image.get('format') == 'jpeg', 'the image payload reports the JPEG format', image.get('format'))
    checker.check(image.get('mime_type') == 'image/jpeg', 'the image payload reports its MIME type',
                  image.get('mime_type'))
    try:
        decoded = base64.b64decode(image.get('base64', ''), validate=True)
    except Exception as error:  # noqa: BLE001 - the payload is server output
        decoded = b''
        checker.check(False, 'the base64 payload decodes', error)
    else:
        checker.check(len(decoded) > 0 and decoded[:2] == b'\xff\xd8', 'the base64 payload is a JPEG',
                      decoded[:4])
    checker.check(image.get('byte_length') == len(decoded), 'byte_length matches the decoded size',
                  (image.get('byte_length'), len(decoded)))

    bad_stream = checker.payload('get_image_bad_stream')
    checker.check(not checker.is_error('get_image_bad_stream'),
                  'an invalid stream_id is a success payload, not a tool error')
    checker.check(bad_stream.get('error') == 'Invalid stream_id: not-a-stream-id',
                  'the invalid stream_id is echoed', bad_stream)
    bad_index = checker.payload('get_image_bad_index')
    checker.check(bad_index.get('error') == 'Image index 3 out of range',
                  'an out-of-range image index is reported', bad_index)

    png_image = checker.payload('get_image_png')
    checker.check(png_image.get('format') == 'png' and png_image.get('mime_type') == 'image/png',
                  'an embedded PNG keeps its format',
                  (png_image.get('format'), png_image.get('mime_type')))
    try:
        png_bytes = base64.b64decode(png_image.get('base64', ''), validate=True)
    except Exception as error:  # noqa: BLE001 - the payload is server output
        png_bytes = b''
        checker.check(False, 'the PNG base64 payload decodes', error)
    else:
        checker.check(png_bytes[:8] == b'\x89PNG\r\n\x1a\n', 'the PNG payload starts with the PNG signature',
                      png_bytes[:8])

    # --- pdf_export: JSON inline -----------------------------------------
    inline_export = checker.payload('export_json_inline')
    checker.check(inline_export.get('inline') is True, 'a small export comes back inline')
    inner_text = inline_export.get('content', '')
    checker.check(inline_export.get('bytes') == len(inner_text.encode('utf-8')),
                  'the reported byte count matches the content',
                  (inline_export.get('bytes'), len(inner_text.encode('utf-8'))))
    checker.check(inline_export.get('format') == 'json' and inline_export.get('scope') == 'document',
                  'the export reports its format and default scope')
    try:
        inner = json.loads(inner_text)
    except json.JSONDecodeError as error:
        inner = {}
        checker.check(False, 'the inline JSON parses', error)
    checker.check(inner.get('pageCount') == 1, 'the inline JSON reports pageCount', inner.get('pageCount'))
    checker.check(inner.get('objectTypes') == ['word', 'table'], 'object_types keeps the canonical order',
                  inner.get('objectTypes'))
    inner_tables = ((inner.get('pages') or [{}])[0].get('tables') or [])
    checker.check(bool(inner_tables) and inner_tables[0].get('cells') == TABLE_CELLS,
                  'the exported table matches the fixture',
                  inner_tables[0].get('cells') if inner_tables else None)
    checker.check(inline_export.get('suggested_filename') == 'table-all.json',
                  'the suggested filename follows the scope',
                  inline_export.get('suggested_filename'))

    # --- pdf_export: CSV to output_path -----------------------------------
    csv_export = checker.payload('export_csv_file')
    target = Path(csv_export.get('path', ''))
    checker.check(not checker.is_error('export_csv_file'), 'pdf_export writes to output_path',
                  checker.text('export_csv_file'))
    checker.check(target.is_absolute(), 'the written path is absolute', target)
    checker.check(target.is_file(), 'the exported CSV exists', target)
    if target.is_file():
        data = target.read_bytes()
        checker.check(data.startswith(b'\xef\xbb\xbf'), 'the CSV starts with a UTF-8 BOM', data[:8])
        checker.check(csv_export.get('bytes') == len(data), 'the reported byte count matches the file',
                      (csv_export.get('bytes'), len(data)))
        checker.check(b'# chars\n' in data, 'the CSV carries the char section')
        checker.check(b'\r\n' not in data, 'no newline translation happened', data[:200])
    checker.check(csv_export.get('format') == 'csv' and csv_export.get('scope') == 'document',
                  'the CSV export reports its format and scope')
    checker.check(len(csv_export.get('object_types', [])) == 7,
                  'the CSV export keeps every object type', csv_export.get('object_types'))

    inline_csv = checker.payload('export_csv_inline')
    checker.check(inline_csv.get('content', '').startswith('\ufeff# words\n'),
                  'an inline CSV keeps its BOM and section header',
                  inline_csv.get('content', '')[:40])
    checker.check(inline_csv.get('object_types') == ['word'], 'object_types trims the payload',
                  inline_csv.get('object_types'))

    # --- pdf_export: scope=page -------------------------------------------
    page_scope = checker.payload('export_page_scope')
    checker.check(page_scope.get('scope') == 'page' and page_scope.get('inline') is True,
                  'a page-scope export is inline and reports its scope', page_scope.get('scope'))
    checker.check(page_scope.get('suggested_filename') == 'text-p1.json',
                  'a page-scope export names the page', page_scope.get('suggested_filename'))
    try:
        page_scope_json = json.loads(page_scope.get('content', ''))
    except json.JSONDecodeError as error:
        page_scope_json = {}
        checker.check(False, 'the page-scope JSON parses', error)
    checker.check(page_scope_json.get('pageCount') == 1, 'the page-scope export holds one page',
                  page_scope_json.get('pageCount'))

    # --- the 1 MB inline limit --------------------------------------------
    oversized = checker.payload('export_big_temp')
    checker.check(oversized.get('inline') is False, 'an oversized export is not inline')
    note = oversized.get('note', '')
    checker.check('over the 1000000-byte inline limit' in note,
                  'the oversized note explains the limit', note)
    temp_path = Path(oversized.get('path', ''))
    checker.check(temp_path.is_file(), 'the oversized export was written to a temp file', temp_path)
    if temp_path.is_file():
        checker.check(oversized.get('bytes') == temp_path.stat().st_size,
                      'the reported size matches the temp file',
                      (oversized.get('bytes'), temp_path.stat().st_size))
        checker.check(temp_path.name.startswith('pdf-inspector-')
                      and temp_path.name.endswith('-big-all.json'),
                      'the temp file is named after the export', temp_path.name)
        # The export holds document text: it must not be world-readable.
        mode = temp_path.stat().st_mode & 0o777
        checker.check(mode == 0o600, 'the temp export is restricted to its owner (0600)', oct(mode))
        temp_path.unlink()

    checker.check(checker.is_error('extract_page_big'), 'pdf_extract_page refuses an oversized page')
    extract_page_error = checker.text('extract_page_big')
    checker.check(extract_page_error.startswith('pdf_extract_page: the result is ')
                  and 'over the 1000000-byte inline limit' in extract_page_error,
                  'the oversized page error explains the limit and the way out', extract_page_error)

    # --- error cases ------------------------------------------------------
    cases = [
        ('error_missing_path', 'does not exist'),
        ('error_bad_page', 'Invalid page number: 99 (document has 1 pages)'),
        ('error_bad_format', "Invalid format: 'xml' (expected one of 'json', 'csv')"),
        ('error_missing_page', "Missing page: scope='page' requires the 1-based 'page' argument"),
        ('error_bad_range', 'Invalid page range: 2-1 (document has 3 pages)'),
        ('error_encrypted', 'password required or incorrect'),
        ('error_directory', 'which is not a regular file'),
        ('error_not_pdf', 'not a valid PDF'),
        ('error_output_path_empty', "Invalid output_path: '   ' (expected a file path)"),
        ('error_output_path_directory', 'does not exist; create it first or choose another location'),
    ]
    for key, fragment in cases:
        checker.check(checker.is_error(key), '%s reports isError=true' % key, checker.result(key))
        text = checker.text(key)
        checker.check(fragment in text, '%s mentions %r' % (key, fragment), text)
    for key, _ in cases:
        checker.check(checker.text(key).strip() != '', '%s returns a non-empty message' % key)

    alive = checker.payload('still_alive')
    checker.check(not checker.is_error('still_alive'), 'the server still answers after the error cases')
    checker.check(alive.get('pages') == 0, 'the zero-page document reports zero pages', alive.get('pages'))


def check_binary_output(checker: Checker, work: Path) -> None:
    """The built binary must not print anything but JSON-RPC on stdout.

    `cjpm run` mixes its own progress lines into stdout (the main conversation
    skips them), so it cannot prove the server itself is clean. Running
    `target/release/bin/pdf_inspector_mcp` directly can: a client that speaks the
    protocol reads every stdout line and must not find a stray `println` there.
    """
    stdout_path = work / 'binary-stdout.txt'
    stderr_path = work / 'binary-stderr.txt'
    checker.check(stdout_path.is_file(), 'the built binary produced stdout', stdout_path)
    if not stdout_path.is_file():
        return
    answered: dict[int, dict] = {}
    non_json: list[str] = []
    for raw in stdout_path.read_text(encoding='utf-8', errors='replace').splitlines():
        line = raw.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            non_json.append(line)
            continue
        if not isinstance(message, dict) or message.get('jsonrpc') != '2.0':
            non_json.append(line)
            continue
        if isinstance(message.get('id'), int):
            answered[message['id']] = message
    checker.check(not non_json, 'every stdout line of the built binary is JSON-RPC', non_json[:5])
    checker.check(sorted(answered) == sorted(BINARY_IDS.values()),
                  'the built binary answers every request', sorted(answered))
    listing = answered.get(BINARY_IDS['tools_list'], {}).get('result', {})
    checker.check(len(listing.get('tools', [])) == 6, 'the built binary advertises six tools',
                  len(listing.get('tools', [])))
    checker.check(answered.get(BINARY_IDS['ping'], {}).get('result') is not None,
                  'the built binary answers ping')
    checker.check(stderr_path.is_file(), 'the built binary wrote its diagnostics to stderr', stderr_path)
    if stderr_path.is_file():
        diagnostics = stderr_path.read_text(encoding='utf-8', errors='replace')
        checker.check('stdio JSON-RPC server ready' in diagnostics,
                      'the startup banner goes to stderr, not stdout', diagnostics[:200])


def check(work: Path) -> None:
    responses: dict[int, dict] = {}
    noise = 0
    with (work / 'responses.txt').open(encoding='utf-8', errors='replace') as handle:
        for raw in handle:
            line = raw.strip()
            if not line:
                continue
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                # `cjpm run` prints its own progress lines on stdout.
                noise += 1
                continue
            if isinstance(message.get('id'), int):
                responses[message['id']] = message

    checker = Checker(responses, noise)
    check_conversation(checker)
    check_binary_output(checker, work)
    if checker.failure():
        print('\n%d check(s) failed' % len(checker.failures))
        for failure in checker.failures:
            print(' - %s' % failure)
        print('\nresponses are in %s' % (work / 'responses.txt'))
        sys.exit(1)
    print('\nall end-to-end checks passed')


def main() -> None:
    mode = sys.argv[1]
    if mode == 'prepare':
        prepare(Path(sys.argv[2]), Path(sys.argv[3]))
        return
    if mode == 'binary-requests':
        write_binary_requests(Path(sys.argv[2]))
        return
    check(Path(sys.argv[2]))


if __name__ == '__main__':
    main()
PY

echo "==> preparing fixtures and requests in ${WORK_DIR}"
"${PYTHON}" "${DRIVER}" prepare "${REPO_ROOT}" "${WORK_DIR}"

echo "==> cjpm build (${TOOLCHAIN})"
cd "${PROJECT_DIR}"
"${CJV}" run "${TOOLCHAIN}" cjpm build

echo "==> running the server over stdio"
RESPONSES="${WORK_DIR}/responses.txt"
SERVER_LOG="${WORK_DIR}/server.log"

set +e
"${CJV}" run "${TOOLCHAIN}" cjpm run --name pdf_inspector_mcp \
    < "${WORK_DIR}/requests.jsonl" > "${RESPONSES}" 2> "${SERVER_LOG}"
STATUS=$?
set -e

if [ ${STATUS} -ne 0 ]; then
    echo "error: the MCP server exited with status ${STATUS}" >&2
    echo "--- responses" >&2
    cat "${RESPONSES}" >&2
    echo "--- server log" >&2
    cat "${SERVER_LOG}" >&2
    exit 1
fi

echo "==> running the built binary directly (stdout purity)"
BINARY="${PROJECT_DIR}/target/release/bin/pdf_inspector_mcp"
RUNTIME_LIB_DIR="${HOME}/.cjv/toolchains/${TOOLCHAIN}/runtime/lib/linux_x86_64_llvm"
BINARY_LIBS="${PROJECT_DIR}/target/release/magic:${PROJECT_DIR}/target/release/pdf4cj:${PROJECT_DIR}/target/release/pdf_inspector_mcp:${STDX_DIR}:${RUNTIME_LIB_DIR}"

if [ ! -x "${BINARY}" ]; then
    echo "error: ${BINARY} is missing; the build did not produce the server binary" >&2
    exit 1
fi

"${PYTHON}" "${DRIVER}" binary-requests "${WORK_DIR}"

set +e
LD_LIBRARY_PATH="${BINARY_LIBS}:${LD_LIBRARY_PATH:-}" "${BINARY}" \
    < "${WORK_DIR}/binary-requests.jsonl" \
    > "${WORK_DIR}/binary-stdout.txt" 2> "${WORK_DIR}/binary-stderr.txt"
BINARY_STATUS=$?
set -e

if [ ${BINARY_STATUS} -ne 0 ]; then
    echo "error: ${BINARY} exited with status ${BINARY_STATUS}" >&2
    echo "--- stdout" >&2
    cat "${WORK_DIR}/binary-stdout.txt" >&2
    echo "--- stderr" >&2
    cat "${WORK_DIR}/binary-stderr.txt" >&2
    exit 1
fi

echo "==> checking the responses"
"${PYTHON}" "${DRIVER}" check "${WORK_DIR}"

echo "==> end-to-end smoke test passed"
