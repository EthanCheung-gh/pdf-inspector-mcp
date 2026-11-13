#!/usr/bin/env bash
# Build the server, talk JSON-RPC to it over stdio and assert the protocol shape.
#
# Covers: initialize (supported versions echoed, an unsupported one falls back),
# notifications/initialized, tools/list, ping and one tools/call round trip.
# Checks that all six tools are exposed in the MCP shape
# ({name, description, inputSchema}, never the internal `parameters` object),
# that optional parameters are not advertised as required, and that a failing
# call comes back as a well-formed MCP result with isError=true.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${PROJECT_DIR}/.." && pwd)"
CJV="${CJV:-${HOME}/.cjv/bin/cjv}"
TOOLCHAIN="${CJ_TOOLCHAIN:-lts-1.0.0}"
STDX_DIR="${PROJECT_DIR}/libs/cangjie-stdx-linux-x64-1.0.0.1/linux_x86_64_llvm/dynamic/stdx"

# pdf4cj (path dependency) resolves stdx through ${CANGJIE_STDX_PATH}.
export CANGJIE_STDX_PATH="${CANGJIE_STDX_PATH:-${REPO_ROOT}/pdf4cj/stdx/cangjie-stdx-linux-x64-1.0.0.1}"

cd "${PROJECT_DIR}"

if [ ! -d "${STDX_DIR}" ]; then
    echo "error: ${STDX_DIR} is missing; run scripts/setup-stdx.sh first" >&2
    exit 1
fi

echo "==> cjpm build (${TOOLCHAIN})"
"${CJV}" run "${TOOLCHAIN}" cjpm build

REQUESTS="$(cat <<'JSON'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke-mcp","version":"0.0.1"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"ping"}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"pdf_get_metadata","arguments":{"path":"/nonexistent/definitely-not-a.pdf"}}}
{"jsonrpc":"2.0","id":5,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke-mcp","version":"0.0.1"}}}
{"jsonrpc":"2.0","id":6,"method":"initialize","params":{"protocolVersion":"9999-01-01","capabilities":{},"clientInfo":{"name":"smoke-mcp","version":"0.0.1"}}}
JSON
)"

echo "==> running the server over stdio"
OUT_FILE="$(mktemp)"
trap 'rm -f "${OUT_FILE}"' EXIT

set +e
printf '%s\n' "${REQUESTS}" | "${CJV}" run "${TOOLCHAIN}" cjpm run --name pdf_inspector_mcp >"${OUT_FILE}" 2>/dev/null
STATUS=$?
set -e

if [ ${STATUS} -ne 0 ]; then
    echo "error: the MCP server exited with status ${STATUS}" >&2
    cat "${OUT_FILE}" >&2
    exit 1
fi

echo "==> checking the responses"
python3 - "${OUT_FILE}" <<'PY'
import json
import sys

EXPECTED_TOOLS = [
    'pdf_get_metadata',
    'pdf_extract_page',
    'pdf_extract_document',
    'pdf_analyze_fonts',
    'pdf_get_image',
    'pdf_export',
]

failures = []


def check(condition, message):
    if condition:
        print('  ok   %s' % message)
    else:
        print('  FAIL %s' % message)
        failures.append(message)


messages = []
noise = 0
with open(sys.argv[1], encoding='utf-8', errors='replace') as handle:
    for raw in handle:
        line = raw.strip()
        if not line:
            continue
        try:
            messages.append(json.loads(line))
        except json.JSONDecodeError:
            # `cjpm run` appends its own progress line to stdout; anything that
            # is not JSON is not the server talking.
            noise += 1

print('parsed %d JSON-RPC messages (%d non-JSON lines ignored)' % (len(messages), noise))


def response_for(request_id):
    for message in messages:
        if message.get('id') == request_id:
            return message
    return None


init = response_for(1)
check(init is not None, 'initialize is answered')
if init is not None:
    result = init.get('result', {})
    check(result.get('protocolVersion') == '2024-11-05',
          'a supported protocol version is echoed back')
    check(result.get('serverInfo', {}).get('name') == 'pdf-inspector', 'serverInfo.name is pdf-inspector')
    check(result.get('capabilities', {}).get('tools', {}).get('listChanged') is False,
          'capabilities.tools.listChanged is false')

# Version negotiation: the server speaks 2024-11-05 and 2025-06-18 and answers
# anything else with its default revision instead of echoing a lie.
newer = response_for(5)
check(newer is not None and newer.get('result', {}).get('protocolVersion') == '2025-06-18',
      'the other supported protocol version is echoed back')
unsupported = response_for(6)
check(unsupported is not None and unsupported.get('result', {}).get('protocolVersion') == '2024-11-05',
      'an unsupported protocol version falls back to 2024-11-05')

answered_ids = sorted(message.get('id') for message in messages if 'id' in message)
check(answered_ids == [1, 2, 3, 4, 5, 6],
      'exactly the six requests are answered (notification stays silent)')

listing = response_for(2)
tools = {}
if listing is not None:
    tools = {tool['name']: tool for tool in listing.get('result', {}).get('tools', [])}
check(sorted(tools) == sorted(EXPECTED_TOOLS), 'tools/list exposes all six tools')

# Every advertised tool must be `{name, description, inputSchema}`: the MCP
# shape, not CangjieMagic's internal `{name, description, parameters}` one.
for name, tool in tools.items():
    check(set(tool) == {'name', 'description', 'inputSchema'},
          '%s is advertised as name/description/inputSchema' % name)
    check('parameters' not in tool, '%s does not leak the internal parameters key' % name)
    schema = tool.get('inputSchema', {})
    check(schema.get('type') == 'object', '%s.inputSchema is an object schema' % name)
    check(isinstance(schema.get('properties'), dict), '%s.inputSchema has properties' % name)
    check(isinstance(schema.get('required'), list), '%s.inputSchema has a required list' % name)
    check(bool(tool.get('description')), '%s carries its description' % name)


def required_of(name):
    return tools.get(name, {}).get('inputSchema', {}).get('required', None)


check(required_of('pdf_export') == ['path'], 'pdf_export requires only path (optional args are not required)')
check(required_of('pdf_extract_page') == ['path', 'page'], 'pdf_extract_page requires path and page')
check(required_of('pdf_extract_document') == ['path'], 'pdf_extract_document requires only path')
check(required_of('pdf_get_image') == ['path', 'stream_id'], 'pdf_get_image requires path and stream_id')
check(required_of('pdf_get_metadata') == ['path'], 'pdf_get_metadata requires only path')
check(required_of('pdf_analyze_fonts') == ['path'], 'pdf_analyze_fonts requires only path')

if 'pdf_export' in tools:
    properties = tools['pdf_export']['inputSchema']['properties']
    check('password' in properties, 'pdf_export still describes the password parameter')


def properties_of(name):
    return tools.get(name, {}).get('inputSchema', {}).get('properties', {})


def payload_of(name, parameter):
    """The first (non-null) alternative of a nullable parameter, or the schema itself."""
    schema = properties_of(name).get(parameter, {})
    alternatives = schema.get('anyOf')
    if isinstance(alternatives, list) and alternatives:
        return alternatives[0]
    return schema


def is_nullable(name, parameter):
    schema = properties_of(name).get(parameter, {})
    alternatives = schema.get('anyOf')
    return (isinstance(alternatives, list) and len(alternatives) == 2
            and any(isinstance(item, dict) and item.get('type') == 'null' for item in alternatives))


# `Option<T>` arguments must be advertised as nullable: the server accepts `null`
# for them, and a strict JSON-Schema client would otherwise reject the call
# before sending it. Required arguments keep the plain, non-nullable type.
check(is_nullable('pdf_get_metadata', 'password'), 'pdf_get_metadata.password is nullable')
check(is_nullable('pdf_extract_document', 'first_page'), 'pdf_extract_document.first_page is nullable')
check(is_nullable('pdf_extract_document', 'last_page'), 'pdf_extract_document.last_page is nullable')
check(is_nullable('pdf_analyze_fonts', 'start_page'), 'pdf_analyze_fonts.start_page is nullable')
check(is_nullable('pdf_export', 'page'), 'pdf_export.page is nullable')
check(is_nullable('pdf_export', 'output_path'), 'pdf_export.output_path is nullable')
check(is_nullable('pdf_export', 'object_types'), 'pdf_export.object_types is nullable')
check(payload_of('pdf_export', 'object_types').get('type') == 'array',
      'the nullable object_types still describes its array type')
check(payload_of('pdf_get_metadata', 'password').get('type') == 'string',
      'the nullable password still describes its string type')
check(properties_of('pdf_get_metadata')['password'].get('anyOf')[0].get('description'),
      'the nullable password keeps its description')
check(properties_of('pdf_get_metadata')['password'].get('default', 'missing') is None,
      'password advertises default: null')
check('default' not in properties_of('pdf_export')['format'],
      'format does not advertise default: null (its default is json, not null)')
check(properties_of('pdf_extract_page')['page'].get('type') == 'integer',
      'the required pdf_extract_page.page stays a plain integer')
check(properties_of('pdf_get_metadata')['path'].get('type') == 'string',
      'the required path stays a plain string')

ping = response_for(3)
check(ping is not None and 'result' in ping, 'ping returns a result')

call = response_for(4)
check(call is not None, 'tools/call is answered')
if call is not None:
    check('error' not in call, 'tools/call is not a JSON-RPC error')
    result = call.get('result', {})
    content = result.get('content', [])
    check(isinstance(content, list) and len(content) == 1, 'tools/call returns one content block')
    text = ''
    if content:
        check(content[0].get('type') == 'text', 'the content block is text')
        text = content[0].get('text', '')
        check(isinstance(text, str) and text != '', 'the content block carries non-empty text')
    # A path that does not exist is a tool error, not a crash and not a success:
    # the message has to reach the client so it can correct the call.
    check(result.get('isError') is True, 'a missing file reports isError=true')
    check('Invalid PDF path' in text, 'the error names the invalid path: %r' % text[:120])

if failures:
    print('\n%d check(s) failed' % len(failures))
    for failure in failures:
        print(' - %s' % failure)
    sys.exit(1)

print('\nall MCP protocol checks passed')
PY

echo "==> smoke test passed"
