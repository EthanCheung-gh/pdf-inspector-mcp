"""MCP tool layer: six tools over the extractor and the export serialisers.

This module is deliberately thin. It validates the handful of tool-level
arguments that only exist because tools take JSON (``format``, ``scope``,
``object_types``), decides between inline and on-disk payloads, and delegates
everything else:

* ``document.DocumentManager`` owns opening, caching, locking and closing, so no
  tool ever calls ``PdfExtractor``/``close()`` itself;
* ``extractor.PdfExtractor`` owns PDF parsing;
* ``export`` owns JSON/CSV layout and file naming.

Tools are synchronous functions registered with ``structured_output=False``: the
SDK runs them on a worker thread and serialises the returned dict into a JSON
text content block, which every client can read the same way.

Errors are raised as ``ToolValueError``, which is both a ``ValueError`` (so
callers and tests can catch the documented exception type) and an MCP
``ToolError``. The second half matters: this SDK version turns any other
exception raised by a tool into an ``is_error=True`` result whose text is only
``Error executing tool <name>``, with the real message kept in the server log.
Subclassing ``ToolError`` is what delivers the actionable text to the model,
while ``ValueError`` keeps the plain-Python contract.
"""

from __future__ import annotations

import base64
import json
import os
import tempfile
import uuid
from contextlib import ExitStack, contextmanager
from pathlib import Path
from typing import Annotated, Any, Iterable, Iterator, Optional

from mcp.server import MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from pdfminer.psparser import PSException
from pdfplumber.utils.exceptions import MalformedPDFException, PdfminerException
from pydantic import Field

from . import export
from .document import DocumentSession, get_default_manager

__all__ = [
    'MAX_INLINE_BYTES',
    'MIME_TYPES',
    'ToolValueError',
    'mcp',
    'main',
    'pdf_get_metadata',
    'pdf_extract_page',
    'pdf_extract_document',
    'pdf_analyze_fonts',
    'pdf_get_image',
    'pdf_export',
]


class ToolValueError(ValueError, ToolError):
    """Invalid tool input: a ``ValueError`` that also reaches the client verbatim.

    Callers can ``except ValueError``; the MCP layer treats it as an anticipated
    tool failure, so the message is returned to the model as tool error text
    instead of being replaced by a generic "Error executing tool" line.
    """


#: Payloads larger than this are not returned inline; ``pdf_export`` writes them
#: to the OS temp directory instead and ``pdf_extract_*`` refuse with a hint.
MAX_INLINE_BYTES = 1_000_000

#: Image formats the extractor can emit, mapped to their MIME types.
MIME_TYPES = {
    'png': 'image/png',
    'jpeg': 'image/jpeg',
    'jpg': 'image/jpeg',
    'gif': 'image/gif',
    'webp': 'image/webp',
}

_FALLBACK_MIME_TYPE = 'application/octet-stream'

_FORMATS = ('json', 'csv')
_SCOPES = ('document', 'page')

mcp = MCPServer('pdf-inspector')

# --- shared argument documentation -----------------------------------------

_PATH_FIELD = Field(
    description=(
        'Path to the PDF: absolute, or relative to the server process working directory. '
        'Any readable regular file is accepted; the .pdf suffix is not required.'
    )
)
_PASSWORD_FIELD = Field(
    description='Password for an encrypted PDF. Omit or pass null for unprotected documents.'
)
_PAGE_FIELD_DOC = '1-based page number.'


# --- helpers ---------------------------------------------------------------


def _serialized_size(payload: Any) -> int:
    """UTF-8 size of ``payload`` as the SDK would serialise a tool result."""
    return len(json.dumps(payload, indent=2, ensure_ascii=False).encode('utf-8'))


#: pdfminer/pdfplumber errors raised while parsing a document - both when its
#: structure is read (open) and when a page's content stream is interpreted
#: (extraction; pdfplumber wraps every interpreter failure in
#: ``PdfminerException``). ``PSException`` is pdfminer's root for its pdf/ps
#: errors, which covers ``PDFException``, ``PDFSyntaxError``,
#: ``PDFInterpreterError``, ``PDFPasswordIncorrect`` and friends.
_PARSE_ERRORS = (PdfminerException, MalformedPDFException, PSException)

#: Substrings that mark a failure as "the password is missing or wrong".
_PASSWORD_MARKERS = ('password', 'decrypt')


def _exception_chain(exc: BaseException) -> list[BaseException]:
    """``exc`` plus every exception it wraps, via ``args``/``__cause__``/``__context__``.

    pdfplumber re-raises pdfminer failures as ``PdfminerException(cause)``: the
    wrapper's ``str()`` is empty and the real error only exists in ``args``, so
    classifying on the outermost exception alone would lose it.
    """
    chain: list[BaseException] = []
    seen: set[int] = set()
    pending: list[BaseException] = [exc]
    while pending:
        current = pending.pop()
        if id(current) in seen:
            continue
        seen.add(id(current))
        chain.append(current)
        pending.extend(arg for arg in getattr(current, 'args', ()) if isinstance(arg, BaseException))
        for link in (current.__cause__, current.__context__):
            if link is not None:
                pending.append(link)
    return chain


def _is_password_failure(exc: BaseException) -> bool:
    """Whether one exception in the chain means "password missing or wrong"."""
    if 'password' in type(exc).__name__.lower():
        return True
    text = str(exc).lower()
    return any(marker in text for marker in _PASSWORD_MARKERS)


def _describe_exception(exc: BaseException) -> str:
    """The exception's message, or its class name when it has none.

    pdfminer's password failure is message-less at every level, so the class name
    (``PDFPasswordIncorrect``) is the only useful thing left; an error message must
    never be empty.
    """
    text = str(exc).strip()
    return text or type(exc).__name__


def _open_failure(path: str, exc: BaseException) -> ToolValueError:
    """Turn a parse failure into an actionable, non-empty tool error."""
    nodes = _exception_chain(exc)
    password_node = next((node for node in nodes if _is_password_failure(node)), None)
    if password_node is not None:
        return ToolValueError(
            f"Cannot open '{path}': password required or incorrect "
            f"(pass the 'password' argument for encrypted PDFs). "
            f'Underlying error: {_describe_exception(password_node)}'
        )
    return ToolValueError(
        f"Cannot open '{path}': not a valid PDF. Underlying error: {_describe_exception(exc)}"
    )


def _read_failure(path: str, exc: BaseException) -> ToolValueError:
    """Turn a parse failure raised *while extracting* into an actionable tool error.

    The document opened, so the structure is readable; what failed is a page's
    content stream (damaged bytes, an unsupported encoding, a broken embedded
    object). The wording therefore differs from ``_open_failure``, and there is no
    password hint here: a missing/wrong password would already have failed on open.
    """
    return ToolValueError(
        f"Failed to read '{path}': {_describe_exception(exc)} "
        f'(the document opened, but its page content is damaged or unsupported)'
    )


@contextmanager
def _document_session(path: str, password: Optional[str]) -> Iterator[DocumentSession]:
    """Open the cached session for ``path``, reporting failures as tool errors.

    Failure handling has two phases, both driven by the same classification
    helpers, and both keeping the message the client reads actionable:

    * **open** - ``ValueError`` from the manager (the path is not an existing
      regular file) keeps its own text; a known pdfminer/pdfplumber parse error
      becomes ``Cannot open '<path>': ...``, split into "password missing/wrong"
      (pdfminer reports it as a message-less ``PdfminerException`` wrapping
      ``PDFPasswordIncorrect``) and "not a valid PDF";
    * **extraction** - a known parse error from the tool body becomes
      ``Failed to read '<path>': <reason>``, i.e. "the document opened, this page
      did not"; a ``ValueError`` (out-of-range page, bad ``format``/``output_path``)
      keeps its own text.

    Only those known parser types are intercepted. Anything else - a genuine bug
    such as ``AttributeError``, ``TypeError`` or ``KeyError`` - still propagates
    and is reported by the SDK as a crash (generic client message, traceback in
    the server log), so a programming error is never disguised as user error.
    """
    manager = get_default_manager()
    with ExitStack() as stack:
        try:
            session = stack.enter_context(manager.session(path, password))
        except _PARSE_ERRORS as exc:
            # Kept ahead of the ValueError clause as a guard: these are parse
            # failures, never bad input. In pdfminer.six 20260107 none of them is
            # a ValueError subclass (PSValueError derives from PSException only;
            # PDFKeyError is a KeyError), so the order is defensive, not load
            # bearing - if a future version re-parents one, it is still classified
            # as a parse failure rather than echoed as client input.
            raise _open_failure(path, exc) from exc
        except ValueError as exc:
            raise ToolValueError(str(exc)) from exc
        try:
            yield session
        except _PARSE_ERRORS as exc:
            raise _read_failure(path, exc) from exc
        except ValueError as exc:
            # Body-level input errors (page out of range, missing page, ...) must
            # reach the client too; a bare ValueError would be reported as a crash.
            raise ToolValueError(str(exc)) from exc


def _too_large(tool: str, size: int, hint: str) -> ToolValueError:
    """The consistent, actionable error for an inline payload over the limit."""
    return ToolValueError(
        f'{tool}: the result is {size} bytes, over the {MAX_INLINE_BYTES}-byte inline limit. '
        f'{hint}'
    )


def _normalise_choice(value: Any, choices: Iterable[str], name: str) -> str:
    """Lower-case ``value`` and require it to be one of ``choices``."""
    allowed = ', '.join(repr(choice) for choice in choices)
    if not isinstance(value, str):
        raise ToolValueError(f'Invalid {name}: {value!r} (expected one of {allowed})')
    normalised = value.strip().lower()
    if normalised not in choices:
        raise ToolValueError(f'Invalid {name}: {value!r} (expected one of {allowed})')
    return normalised


def _new_temp_output(suggested_filename: str) -> Path:
    """Reserve a uniquely named file for an oversized export in the temp directory."""
    handle, name = tempfile.mkstemp(
        prefix=f'pdf-inspector-{uuid.uuid4().hex[:8]}-',
        suffix=f'-{suggested_filename}',
        dir=tempfile.gettempdir(),
    )
    os.close(handle)
    return Path(name)


# --- tools -----------------------------------------------------------------


@mcp.tool(structured_output=False)
def pdf_get_metadata(
    path: Annotated[str, _PATH_FIELD],
    password: Annotated[Optional[str], _PASSWORD_FIELD] = None,
) -> dict[str, Any]:
    """Document-level facts: page count, PDF version, encryption flag, first-page size, title/author/producer and the font names the pages reference.

    Use this first to learn how many pages a document has before calling the page tools.
    Returns the extractor's metadata dictionary unchanged (``pages``, ``version``,
    ``encrypted``, ``page_w``, ``page_h``, ``title``, ``author``, ``producer``, ``fonts``).
    """
    with _document_session(path, password) as session:
        return session.extractor.get_metadata()


@mcp.tool(structured_output=False)
def pdf_extract_page(
    path: Annotated[str, _PATH_FIELD],
    page: Annotated[int, Field(description=_PAGE_FIELD_DOC)],
    password: Annotated[Optional[str], _PASSWORD_FIELD] = None,
) -> dict[str, Any]:
    """Extract every object of one page: characters, words, rectangles, lines, curves, images and tables.

    ``page`` is 1-based and must be within the document. The result is one PageData
    object (``width``, ``height`` and one array per object type), suitable for
    inspecting layout, text runs and detected tables. Very large pages are rejected:
    use ``pdf_export`` with ``output_path`` for those.
    """
    with _document_session(path, password) as session:
        data = session.extractor.extract_page(page)
    size = _serialized_size(data)
    if size > MAX_INLINE_BYTES:
        raise _too_large(
            'pdf_extract_page',
            size,
            'Call pdf_export with this page and output_path to write it to a file, '
            'or inspect a smaller page.',
        )
    return data


@mcp.tool(structured_output=False)
def pdf_extract_document(
    path: Annotated[str, _PATH_FIELD],
    first_page: Annotated[
        Optional[int], Field(description='First page to extract (1-based, inclusive). Defaults to page 1.')
    ] = None,
    last_page: Annotated[
        Optional[int], Field(description='Last page to extract (1-based, inclusive). Defaults to the last page.')
    ] = None,
    password: Annotated[Optional[str], _PASSWORD_FIELD] = None,
) -> dict[str, Any]:
    """Extract every object of every page in a range: the whole document, or first_page..last_page.

    Omit both bounds for the whole document. Returns ``{'metadata', 'pageCount',
    'pages'}`` where ``pages`` holds one PageData object per extracted page and
    ``pageCount`` is the number of pages actually returned, not the document's
    total. Large documents should be read in ranges, or exported with ``pdf_export``.
    """
    with _document_session(path, password) as session:
        metadata = session.extractor.get_metadata()
        pages = session.extractor.extract_pages(first_page, last_page)
    payload = {'metadata': metadata, 'pageCount': len(pages), 'pages': pages}
    size = _serialized_size(payload)
    if size > MAX_INLINE_BYTES:
        raise _too_large(
            'pdf_extract_document',
            size,
            'Narrow the range with first_page/last_page, or call pdf_export with output_path '
            'to write the data to a file.',
        )
    return payload


@mcp.tool(structured_output=False)
def pdf_analyze_fonts(
    path: Annotated[str, _PATH_FIELD],
    start_page: Annotated[
        Optional[int], Field(description='First page to analyse (1-based, inclusive). Defaults to page 1.')
    ] = None,
    end_page: Annotated[
        Optional[int], Field(description='Last page to analyse (1-based, inclusive). Defaults to the last page.')
    ] = None,
    password: Annotated[Optional[str], _PASSWORD_FIELD] = None,
) -> dict[str, Any]:
    """Per-font usage statistics: character count, pages, size range and colours.

    Omit both bounds to analyse the whole document. Returns ``{'fonts': [...]}``
    sorted by ``charCount`` descending; each entry has ``fontname``, ``pages``,
    ``charCount``, ``sizeMin``, ``sizeMax`` and ``colors``. Use it to find which
    text is prominent without extracting whole pages.
    """
    with _document_session(path, password) as session:
        return session.extractor.analyze_fonts(start_page, end_page)


@mcp.tool(structured_output=False)
def pdf_get_image(
    path: Annotated[str, _PATH_FIELD],
    stream_id: Annotated[
        str,
        Field(description="Image identifier from a page's images array, in the form 'p<page>_img_<index>'."),
    ],
    password: Annotated[Optional[str], _PASSWORD_FIELD] = None,
) -> dict[str, Any]:
    """Fetch one embedded image's bytes as base64, addressed by the stream_id reported for that image.

    Call ``pdf_extract_page``/``pdf_extract_document`` first and take ``stream_id``
    from an object of type ``image`` (``p<page>_img_<index>``, index is 0-based
    within the page). On success returns ``{'base64', 'format', 'mime_type',
    'byte_length'}`` with the full, untruncated payload; images in non-web formats
    are transcoded to PNG. On failure returns ``{'error': '...'}`` unchanged.

    The complete base64 payload is always returned inline: this tool is the one
    deliberate exception to the 1 MB inline limit the other tools enforce, because
    the image is the whole point of the call. Large images therefore produce a
    large response.
    """
    with _document_session(path, password) as session:
        data = session.extractor.get_image_data(stream_id)
    if 'error' in data:
        return data
    payload = data['base64']
    try:
        byte_length = len(base64.b64decode(payload))
    except Exception:  # pragma: no cover - the extractor produced this payload
        byte_length = 0
    return {
        'base64': payload,
        'format': data['format'],
        'mime_type': MIME_TYPES.get(data['format'], _FALLBACK_MIME_TYPE),
        'byte_length': byte_length,
    }


@mcp.tool(structured_output=False)
def pdf_export(
    path: Annotated[str, _PATH_FIELD],
    format: Annotated[
        str, Field(description="Output format: 'json' (default) or 'csv'.")
    ] = 'json',
    scope: Annotated[
        str, Field(description="'document' (default) exports a page range; 'page' exports the single 'page'.")
    ] = 'document',
    page: Annotated[
        Optional[int],
        Field(
            description=(
                "1-based page number; only used when scope='page' (required there). "
                "Ignored when scope='document' - use first_page/last_page to bound a range."
            )
        ),
    ] = None,
    first_page: Annotated[
        Optional[int],
        Field(description='First page of a document-scope export (1-based, inclusive). Defaults to page 1.'),
    ] = None,
    last_page: Annotated[
        Optional[int],
        Field(description='Last page of a document-scope export (1-based, inclusive). Defaults to the last page.'),
    ] = None,
    object_types: Annotated[
        Optional[list[str]],
        Field(
            description=(
                'Object types to include: any of char, word, rect, line, curve, image, table. '
                "Omit for all types; unknown names are ignored and the output uses the canonical order."
            )
        ),
    ] = None,
    output_path: Annotated[
        Optional[str],
        Field(
            description=(
                'File to write the export to. The parent directory must already exist. '
                'Omit to receive the content inline (large results are written to the temp directory instead).'
            )
        ),
    ] = None,
    password: Annotated[Optional[str], _PASSWORD_FIELD] = None,
) -> dict[str, Any]:
    """Export extracted PDF data as JSON or CSV, either inline or to a file.

    This is the tool for anything bigger than a single page: JSON keeps the same
    shapes as the extract tools (metadata, page count, object types, pages) and CSV
    lays out one ``# <type>`` section per type. Choose ``scope='page'`` with
    ``page`` for one page, or ``scope='document'`` with optional
    ``first_page``/``last_page``. ``object_types`` trims the payload and
    ``output_path`` writes the file to disk; otherwise the content comes back
    inline unless it exceeds the inline limit, in which case it is written to a
    file in the OS temp directory and that path is returned instead.
    """
    fmt = _normalise_choice(format, _FORMATS, 'format')
    export_scope = _normalise_choice(scope, _SCOPES, 'scope')

    if export_scope == 'page' and page is None:
        raise ToolValueError(
            "Missing page: scope='page' requires the 1-based 'page' argument "
            "(or use scope='document' to export a page range)."
        )
    if object_types is not None and not isinstance(object_types, list):
        raise ToolValueError(
            f'Invalid object_types: {object_types!r} (expected a list of type names, e.g. ["word", "table"])'
        )

    selected_types = export.resolve_types(object_types)

    with _document_session(path, password) as session:
        metadata = session.extractor.get_metadata()
        if export_scope == 'page':
            pages = [session.extractor.extract_page(page)]
        else:
            pages = session.extractor.extract_pages(first_page, last_page)

    if fmt == 'csv':
        content = export.pages_to_csv(pages, selected_types)
    else:
        content = export.pages_to_json(pages, metadata, selected_types)

    suggested_filename = export.suggest_filename(path, export_scope, page or 1, fmt)
    payload_bytes = len(content.encode('utf-8'))
    result: dict[str, Any] = {
        'bytes': payload_bytes,
        'format': fmt,
        'scope': export_scope,
        'object_types': selected_types,
        'suggested_filename': suggested_filename,
    }

    if output_path is not None:
        target = _write_export_file(output_path, content)
        return {'path': str(target), **result}

    if payload_bytes > MAX_INLINE_BYTES:
        target = _new_temp_output(suggested_filename)
        target.write_text(content, encoding='utf-8', newline='')
        return {
            'path': str(target),
            **result,
            'inline': False,
            'note': (
                f'The export is {payload_bytes} bytes, over the {MAX_INLINE_BYTES}-byte inline limit, '
                f'so it was written to {str(target)}. Read it there, or narrow the scope, '
                'trim object_types, or pass output_path to choose the location.'
            ),
        }

    return {'content': content, **result, 'inline': True}


def _write_export_file(output_path: str, content: str) -> Path:
    """Write ``content`` to ``output_path`` (UTF-8, BOM preserved) and return the target.

    ``newline=''`` disables newline translation, so the bytes on disk are exactly
    ``content.encode('utf-8')`` on every platform. Without it, Windows would turn
    every ``\\n`` into ``\\r\\n`` - including the line breaks *inside* quoted CSV
    cells, which is precisely what RFC 4180 quoting must preserve - and the
    reported ``bytes`` would no longer match the file size.
    """
    if not isinstance(output_path, str) or not output_path.strip():
        raise ToolValueError(f'Invalid output_path: {output_path!r} (expected a file path)')

    target = Path(output_path).expanduser()
    parent = target.parent
    if not parent.is_dir():
        raise ToolValueError(
            f'Invalid output_path: {output_path!r} (directory {str(parent)} does not exist; '
            'create it first or choose another location)'
        )
    if target.is_dir():
        raise ToolValueError(f'Invalid output_path: {output_path!r} (it is a directory, not a file)')

    try:
        target.write_text(content, encoding='utf-8', newline='')
    except OSError as exc:
        raise ToolValueError(f'Invalid output_path: {output_path!r} (cannot write it: {exc})') from exc
    return target


def main() -> None:
    """Run the server over stdio, the transport MCP clients launch it with."""
    mcp.run()


if __name__ == '__main__':
    main()
