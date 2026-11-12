package pdf_inspector_mcp.mcp

import magic.dsl.*
import magic.prelude.*

/**
 * The six MCP tools of the Python `pdf-inspector-mcp` server, declared as
 * CangjieMagic `@tool` functions.
 *
 * IMPORTANT (contract for follow-up work):
 * - tool names, parameter names, parameter order and `Option`-ness are part of
 *   the public MCP surface and must not change;
 * - every function returns a `String` holding JSON text (the MCP `text`
 *   content), so tools stay schema-identical to the Python implementation;
 * - raise `PdfToolError` for user-facing failures (bad path, page out of
 *   range, unsupported format, bad password) - the server reports it with
 *   `isError: true` and the message is shown to the client verbatim.
 *
 * The bodies are placeholders for now: the PDF layer is not implemented yet.
 */
private let NOT_IMPLEMENTED = "{\"error\":\"not implemented\"}"

@tool[description: "Document-level facts for a PDF: page count, PDF version, encryption flag, first-page size, title/author/producer and the font names the pages reference. Call it first to learn how many pages a document has before using the page tools. Returns a JSON object with pages, version, encrypted, page_w, page_h, title, author, producer and fonts.", parameters: {path: "Path to the PDF file on the machine running this server.", password: "Password for an encrypted PDF; omit when the document is not encrypted."}]
public func pdf_get_metadata(path: String, password: Option<String>): String {
    return NOT_IMPLEMENTED
}

@tool[description: "Extract every object of a single page: characters, words, rectangles, lines, curves, images and tables. page is 1-based and must be within the document. Returns one page object with width, height and one array per object type; pages too large to return inline should be exported with pdf_export and output_path instead.", parameters: {path: "Path to the PDF file on the machine running this server.", page: "1-based page number to extract; must be within the document.", password: "Password for an encrypted PDF; omit when the document is not encrypted."}]
public func pdf_extract_page(path: String, page: Int64, password: Option<String>): String {
    return NOT_IMPLEMENTED
}

@tool[description: "Extract every object of every page in a range: the whole document when both bounds are omitted, otherwise first_page..last_page. Returns an object with metadata, pageCount (the number of pages actually returned, not the document total) and pages. Large documents should be read in ranges, or exported with pdf_export.", parameters: {path: "Path to the PDF file on the machine running this server.", first_page: "First page to extract (1-based, inclusive); defaults to page 1.", last_page: "Last page to extract (1-based, inclusive); defaults to the last page.", password: "Password for an encrypted PDF; omit when the document is not encrypted."}]
public func pdf_extract_document(
    path: String,
    first_page: Option<Int64>,
    last_page: Option<Int64>,
    password: Option<String>
): String {
    return NOT_IMPLEMENTED
}

@tool[description: "Per-font usage statistics: character count, the pages a font appears on, its size range and its colours. Omit both bounds to analyse the whole document. Returns a fonts array sorted by charCount descending, each entry with fontname, pages, charCount, sizeMin, sizeMax and colors, which tells you which text is prominent without extracting whole pages.", parameters: {path: "Path to the PDF file on the machine running this server.", start_page: "First page to analyse (1-based, inclusive); defaults to page 1.", end_page: "Last page to analyse (1-based, inclusive); defaults to the last page.", password: "Password for an encrypted PDF; omit when the document is not encrypted."}]
public func pdf_analyze_fonts(
    path: String,
    start_page: Option<Int64>,
    end_page: Option<Int64>,
    password: Option<String>
): String {
    return NOT_IMPLEMENTED
}

@tool[description: "Fetch one embedded image as base64, addressed by the stream_id reported for that image. Call pdf_extract_page or pdf_extract_document first and take stream_id from an object of type image (form p<page>_img_<index>, where index is 0-based within the page). Returns base64, format, mime_type and byte_length; images in non-web formats are transcoded to PNG. The complete payload is always returned inline, so large images produce a large response.", parameters: {path: "Path to the PDF file on the machine running this server.", stream_id: "Image identifier taken from a page images array, in the form p<page>_img_<index>.", password: "Password for an encrypted PDF; omit when the document is not encrypted."}]
public func pdf_get_image(path: String, stream_id: String, password: Option<String>): String {
    return NOT_IMPLEMENTED
}

@tool[description: "Export extracted PDF data as JSON or CSV, either inline or to a file. This is the tool for anything bigger than a single page: JSON keeps the same shapes as the extract tools (metadata, page count, object types, pages) and CSV writes one section per object type. Choose scope=page with page for one page, or scope=document with optional first_page/last_page; object_types trims the payload and output_path writes the result to disk. Without output_path the content comes back inline unless it exceeds the inline limit, in which case it is written to a temp file and that path is returned.", parameters: {path: "Path to the PDF file on the machine running this server.", format: "Output format: json (default) or csv.", scope: "Export scope: document (default) exports a page range; page exports the single page given by page.", page: "1-based page number, only used when scope=page (required there); ignored when scope=document.", first_page: "First page of a document-scope export (1-based, inclusive); defaults to page 1.", last_page: "Last page of a document-scope export (1-based, inclusive); defaults to the last page.", object_types: "Object types to include: any of char, word, rect, line, curve, image, table. Omit for all types; unknown names are ignored.", output_path: "File to write the export to; the parent directory must already exist. Omit to receive the content inline.", password: "Password for an encrypted PDF; omit when the document is not encrypted."}]
public func pdf_export(
    path: String,
    format: Option<String>,
    scope: Option<String>,
    page: Option<Int64>,
    first_page: Option<Int64>,
    last_page: Option<Int64>,
    object_types: Option<Array<String>>,
    output_path: Option<String>,
    password: Option<String>
): String {
    return NOT_IMPLEMENTED
}
