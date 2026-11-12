#!/usr/bin/env bash
# Build the server, talk JSON-RPC to it over stdio and assert the protocol shape.
#
# Covers: initialize, notifications/initialized, tools/list, ping and one
# tools/call round trip. Checks that all six tools are exposed, that optional
# parameters are not advertised as required, and that the call comes back as a
# well-formed MCP result.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CJV="${CJV:-${HOME}/.cjv/bin/cjv}"
TOOLCHAIN="${CJ_TOOLCHAIN:-lts-1.0.0}"
STDX_DIR="${PROJECT_DIR}/libs/cangjie-stdx-linux-x64-1.0.0.1/linux_x86_64_llvm/dynamic/stdx"

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
    check(result.get('protocolVersion') == '2024-11-05', 'initialize echoes the client protocol version')
    check(result.get('serverInfo', {}).get('name') == 'pdf-inspector', 'serverInfo.name is pdf-inspector')
    check(result.get('capabilities', {}).get('tools', {}).get('listChanged') is False,
          'capabilities.tools.listChanged is false')

answered_ids = sorted(message.get('id') for message in messages if 'id' in message)
check(answered_ids == [1, 2, 3, 4], 'exactly the four requests are answered (notification stays silent)')

listing = response_for(2)
tools = {}
if listing is not None:
    tools = {tool['name']: tool for tool in listing.get('result', {}).get('tools', [])}
check(sorted(tools) == sorted(EXPECTED_TOOLS), 'tools/list exposes all six tools')


def required_of(name):
    return tools.get(name, {}).get('parameters', {}).get('required', None)


check(required_of('pdf_export') == ['path'], 'pdf_export requires only path (optional args are not required)')
check(required_of('pdf_extract_page') == ['path', 'page'], 'pdf_extract_page requires path and page')
check(required_of('pdf_extract_document') == ['path'], 'pdf_extract_document requires only path')
check(required_of('pdf_get_image') == ['path', 'stream_id'], 'pdf_get_image requires path and stream_id')
check(required_of('pdf_get_metadata') == ['path'], 'pdf_get_metadata requires only path')
check(required_of('pdf_analyze_fonts') == ['path'], 'pdf_analyze_fonts requires only path')

if 'pdf_export' in tools:
    properties = tools['pdf_export']['parameters']['properties']
    check('password' in properties, 'pdf_export still describes the password parameter')
    check(properties.get('object_types', {}).get('type') == 'array', 'pdf_export.object_types is an array schema')

ping = response_for(3)
check(ping is not None and 'result' in ping, 'ping returns a result')

call = response_for(4)
check(call is not None, 'tools/call is answered')
if call is not None:
    check('error' not in call, 'tools/call is not a JSON-RPC error')
    result = call.get('result', {})
    content = result.get('content', [])
    check(isinstance(content, list) and len(content) == 1, 'tools/call returns one content block')
    if content:
        check(content[0].get('type') == 'text', 'the content block is text')
        check(isinstance(content[0].get('text'), str) and content[0]['text'] != '',
              'the content block carries non-empty JSON text')
    check(isinstance(result.get('isError'), bool),
          'tools/call reports isError as a boolean (placeholder tools do not fail yet)')

if failures:
    print('\n%d check(s) failed' % len(failures))
    for failure in failures:
        print(' - %s' % failure)
    sys.exit(1)

print('\nall MCP protocol checks passed')
PY

echo "==> smoke test passed"
