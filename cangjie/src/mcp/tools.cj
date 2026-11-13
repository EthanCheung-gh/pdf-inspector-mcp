package pdf_inspector_mcp.mcp

import magic.dsl.*
import magic.prelude.*
import std.env.getVariable
import std.fs.{File, FileInfo, exists}
import std.posix.chmod
import std.random.Random
import std.convert.*
import pdf_inspector_mcp.export.*
import pdf4cj.*

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
 * The wording of every message below is copied from `server.py` /
 * `document.py` / `extractor.py` so a client that asserts on error text sees the
 * same strings from both implementations. Only `PdfToolError` and `PdfError`
 * are translated; any other exception is left to the server's generic
 * "Internal error ..." path, so a bug is never disguised as bad user input.
 *
 * Payloads come straight from `pdf_inspector_mcp.export`, which owns the JSON
 * and CSV layout. What this file adds is the thin MCP layer: path/password
 * handling through `DocumentManager`, page-range validation, the 1 MB inline
 * limit, and the choice between returning content inline, writing it to the
 * caller's `output_path`, or parking it in a temp file.
 */

/** Payloads larger than this are not returned inline. */
let MAX_INLINE_BYTES: Int64 = 1_000_000

private let JSON_FORMATS: Array<String> = ["json", "csv"]
private let EXPORT_SCOPES: Array<String> = ["document", "page"]

@tool[description: "Document-level facts for a PDF: page count, PDF version, encryption flag, first-page size, title/author/producer and the font names the pages reference. Call it first to learn how many pages a document has before using the page tools. Returns a JSON object with pages, version, encrypted, page_w, page_h, title, author, producer and fonts.", parameters: {path: "Path to the PDF file on the machine running this server.", password: "Password for an encrypted PDF; omit when the document is not encrypted."}]
public func pdf_get_metadata(path: String, password: Option<String>): String {
    let (_, doc) = openDocument(path, password)
    return metadataToJson(documentMetadata(path, doc))
}

@tool[description: "Extract every object of a single page: characters, words, rectangles, lines, curves, images and tables. page is 1-based and must be within the document. Returns one page object with width, height and one array per object type; pages too large to return inline should be exported with pdf_export and output_path instead.", parameters: {path: "Path to the PDF file on the machine running this server.", page: "1-based page number to extract; must be within the document.", password: "Password for an encrypted PDF; omit when the document is not encrypted."}]
public func pdf_extract_page(path: String, page: Int64, password: Option<String>): String {
    let (_, doc) = openDocument(path, password)
    requirePage(page, doc.pageCount)
    let content = pageToJson(extractPageData(path, doc, page, true))
    let size = content.toArray().size
    if (size > MAX_INLINE_BYTES) {
        throw tooLarge(
            "pdf_extract_page",
            size,
            "Call pdf_export with this page and output_path to write it to a file, or inspect a smaller page."
        )
    }
    return content
}

@tool[description: "Extract every object of every page in a range: the whole document when both bounds are omitted, otherwise first_page..last_page. Returns an object with metadata, pageCount (the number of pages actually returned, not the document total) and pages. Large documents should be read in ranges, or exported with pdf_export.", parameters: {path: "Path to the PDF file on the machine running this server.", first_page: "First page to extract (1-based, inclusive); defaults to page 1.", last_page: "Last page to extract (1-based, inclusive); defaults to the last page.", password: "Password for an encrypted PDF; omit when the document is not encrypted."}]
public func pdf_extract_document(
    path: String,
    first_page: Option<Int64>,
    last_page: Option<Int64>,
    password: Option<String>
): String {
    let (_, doc) = openDocument(path, password)
    let total = doc.pageCount
    let pages = ArrayList<PageData>()
    // A zero-page document is only an error when a bound was written out
    // explicitly; `extract_pages()` in the Python server returns `[]` for the
    // "no arguments" call, which is what makes `pdf_extract_document` usable on
    // a degenerate document.
    if (!(total == 0 && first_page.isNone() && last_page.isNone())) {
        let range = resolveRange(first_page, last_page, total)
        var number = range.first
        while (number <= range.last) {
            pages.add(extractPageData(path, doc, number, true))
            number += 1
        }
    }
    let content = documentToJson(documentMetadata(path, doc), pages, None)
    let size = content.toArray().size
    if (size > MAX_INLINE_BYTES) {
        throw tooLarge(
            "pdf_extract_document",
            size,
            "Narrow the range with first_page/last_page, or call pdf_export with output_path to write the data to a file."
        )
    }
    return content
}

@tool[description: "Per-font usage statistics: character count, the pages a font appears on, its size range and its colours. Omit both bounds to analyse the whole document. Returns a fonts array sorted by charCount descending, each entry with fontname, pages, charCount, sizeMin, sizeMax and colors, which tells you which text is prominent without extracting whole pages.", parameters: {path: "Path to the PDF file on the machine running this server.", start_page: "First page to analyse (1-based, inclusive); defaults to page 1.", end_page: "Last page to analyse (1-based, inclusive); defaults to the last page.", password: "Password for an encrypted PDF; omit when the document is not encrypted."}]
public func pdf_analyze_fonts(
    path: String,
    start_page: Option<Int64>,
    end_page: Option<Int64>,
    password: Option<String>
): String {
    let (_, doc) = openDocument(path, password)
    let total = doc.pageCount
    let fonts = FontAccumulator()
    // An unbounded call walks the whole document, i.e. pages 1..total; a
    // zero-page document therefore simply yields `{"fonts":[]}`.
    var first: Int64 = 1
    var last: Int64 = total
    if (!(start_page.isNone() && end_page.isNone())) {
        let range = resolveRange(start_page, end_page, total)
        first = range.first
        last = range.last
    }
    var number = first
    while (number <= last) {
        fonts.addPage(extractPageData(path, doc, number, false).chars, number)
        number += 1
    }
    return fonts.toJson()
}

@tool[description: "Fetch one embedded image as base64, addressed by the stream_id reported for that image. Call pdf_extract_page or pdf_extract_document first and take stream_id from an object of type image (form p<page>_img_<index>, where index is 0-based within the page). Returns base64, format, mime_type and byte_length; images in non-web formats are transcoded to PNG. The complete payload is always returned inline, so large images produce a large response.", parameters: {path: "Path to the PDF file on the machine running this server.", stream_id: "Image identifier taken from a page images array, in the form p<page>_img_<index>.", password: "Password for an encrypted PDF; omit when the document is not encrypted."}]
public func pdf_get_image(path: String, stream_id: String, password: Option<String>): String {
    let (_, doc) = openDocument(path, password)
    // Every failure below is reported in the payload, not as a tool error: the
    // Python tool answers `{'error': ...}` with `isError: false`, so a client
    // reading the frame does not mistake a stale stream_id for a broken server.
    let (pageNumber, imageIndex) = match (parseStreamId(stream_id)) {
        case Some(parsed) => parsed
        case None => return imageError("Invalid stream_id: " + stream_id)
    }
    if (pageNumber < 1 || pageNumber > doc.pageCount) {
        return imageError("Invalid stream_id: " + stream_id)
    }
    let data = extractPageData(path, doc, pageNumber, false)
    if (imageIndex >= data.images.size) {
        return imageError("Image index ${imageIndex} out of range")
    }
    let payload = imagePayload(doc, data.images[imageIndex])
    if (let Some(message) <- payload.error) {
        return imageError(message)
    }
    return "{\"base64\":" + jsonQuote(payload.base64) +
        ",\"format\":" + jsonQuote(payload.format) +
        ",\"mime_type\":" + jsonQuote(payload.mimeType) +
        ",\"byte_length\":${payload.byteLength}}"
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
    let formatName = normaliseChoice(format, JSON_FORMATS, "format")
    let scopeName = normaliseChoice(scope, EXPORT_SCOPES, "scope")
    if (scopeName == "page" && page.isNone()) {
        throw PdfToolError(
            "Missing page: scope='page' requires the 1-based 'page' argument " +
            "(or use scope='document' to export a page range)."
        )
    }
    let selectedTypes = resolveTypes(object_types)
    let singlePage = match (page) {
        case Some(number) => number
        case None => 1
    }

    let (_, doc) = openDocument(path, password)
    let total = doc.pageCount
    let pages = ArrayList<PageData>()
    if (scopeName == "page") {
        requirePage(singlePage, total)
        pages.add(extractPageData(path, doc, singlePage, true))
    } else {
        if (!(total == 0 && first_page.isNone() && last_page.isNone())) {
            let range = resolveRange(first_page, last_page, total)
            var number = range.first
            while (number <= range.last) {
                pages.add(extractPageData(path, doc, number, true))
                number += 1
            }
        }
    }
    let metadata = documentMetadata(path, doc)
    let content = if (formatName == "csv") {
        pagesToCsv(pages, Some(selectedTypes))
    } else {
        pagesToJson(pages, metadata, Some(selectedTypes), None)
    }
    let bytes = content.toArray().size
    let suggested = suggestFilename(path, scopeName, singlePage, formatName)
    let summary = "\"bytes\":${bytes},\"format\":" + jsonQuote(formatName) +
        ",\"scope\":" + jsonQuote(scopeName) +
        ",\"object_types\":" + jsonStringArray(selectedTypes) +
        ",\"suggested_filename\":" + jsonQuote(suggested)

    match (output_path) {
        case Some(target) =>
            return "{\"path\":" + jsonQuote(writeExportFile(target, content)) + "," + summary + "}"
        case None => ()
    }
    if (bytes <= MAX_INLINE_BYTES) {
        return "{\"content\":" + jsonQuote(content) + "," + summary + ",\"inline\":true}"
    }
    let written = writeTempExport(suggested, content)
    return "{\"path\":" + jsonQuote(written) + "," + summary + ",\"inline\":false,\"note\":" +
        jsonQuote(
            "The export is ${bytes} bytes, over the ${MAX_INLINE_BYTES}-byte inline limit, so it was written to " +
            written + ". Read it there, or narrow the scope, trim object_types, or pass output_path to choose the location."
        ) + "}"
}

// ---------------------------------------------------------------------------
// Document handling

/**
 * Open the cached document for `path`, translating the two `PdfDocument.open`
 * failures a client can cause into tool errors.
 */
func openDocument(path: String, password: Option<String>): (String, PdfDocument) {
    let manager = documentManager()
    try {
        return manager.session(path, password)
    } catch (error: PdfError) {
        throw openFailure(path, error.message)
    }
}

/**
 * "not a valid PDF" or "password required or incorrect".
 *
 * `PdfDocument.open` phrases every failure as `cannot open PDF '<path>': <reason>`;
 * the reason is what a client can act on, so it is cut out and re-framed. The
 * password failure is passed through untouched: it already names the fix.
 */
func openFailure(path: String, message: String): PdfToolError {
    if (message.indexOf("password required or incorrect").isSome()) {
        return PdfToolError(message)
    }
    return PdfToolError(
        "Cannot open " + quoted(path) + ": not a valid PDF. Underlying error: " + openReason(message)
    )
}

/** The `<reason>` half of `cannot open PDF '<path>': <reason>`. */
func openReason(message: String): String {
    var start: Int64 = 0
    let marker = "PDF '"
    if (let Some(position) <- message.indexOf(marker)) {
        start = position + marker.size
    }
    if (let Some(separator) <- message[start..message.size].indexOf("': ")) {
        let reason = message[start + separator + 3..message.size].trimAscii()
        if (!reason.isEmpty()) {
            return reason
        }
    }
    let trimmed = message.trimAscii()
    if (trimmed.isEmpty()) {
        return "unknown error"
    }
    return trimmed
}

/**
 * A parse failure raised *while extracting*: the document opened, so the
 * structure is readable and what broke is a page's content stream.
 */
func readFailure(path: String, message: String): PdfToolError {
    let reason = if (message.trimAscii().isEmpty()) {
        "unknown error"
    } else {
        message.trimAscii()
    }
    return PdfToolError(
        "Failed to read " + quoted(path) + ": " + reason +
        " (the document opened, but its page content is damaged or unsupported)"
    )
}

func documentMetadata(path: String, doc: PdfDocument): PdfMetadata {
    try {
        return doc.metadata()
    } catch (error: PdfError) {
        throw readFailure(path, error.message)
    }
}

/**
 * One page's objects. `withTables` is false for the two callers that only look
 * at `chars`/`images`: table detection is the expensive stage, and neither
 * `pdf_analyze_fonts` nor `pdf_get_image` can observe its output.
 */
func extractPageData(path: String, doc: PdfDocument, number: Int64, withTables: Bool): PageData {
    try {
        let page = doc.page(number)
        let data = extractPage(doc, page)
        if (withTables) {
            data.tables.add(all: extractTables(page, data))
        }
        return data
    } catch (error: PdfError) {
        throw readFailure(path, error.message)
    }
}

func requirePage(page: Int64, total: Int64): Unit {
    if (page < 1 || page > total) {
        throw PdfToolError("Invalid page number: ${page} (document has ${total} pages)")
    }
}

/** A validated 1-based, inclusive page range. */
class PageRange {
    let first: Int64
    let last: Int64

    init(first: Int64, last: Int64) {
        this.first = first
        this.last = last
    }
}

/** Resolve a possibly one-sided 1-based range against the document bounds. */
func resolveRange(first_page: Option<Int64>, last_page: Option<Int64>, total: Int64): PageRange {
    let first = match (first_page) {
        case Some(value) => value
        case None => 1
    }
    let last = match (last_page) {
        case Some(value) => value
        case None => total
    }
    if (first < 1 || last < first || last > total) {
        throw PdfToolError("Invalid page range: ${first}-${last} (document has ${total} pages)")
    }
    return PageRange(first, last)
}

func tooLarge(tool: String, size: Int64, hint: String): PdfToolError {
    return PdfToolError(
        "${tool}: the result is ${size} bytes, over the ${MAX_INLINE_BYTES}-byte inline limit. " + hint
    )
}

// ---------------------------------------------------------------------------
// Image stream ids

/** `p<page>_img_<index>` parsed into its two numbers; whole-string match only. */
func parseStreamId(streamId: String): Option<(Int64, Int64)> {
    let marker = "_img_"
    if (streamId.isEmpty() || streamId[0] != b'p') {
        return None
    }
    var position: Int64 = 1
    let pageStart = position
    while (position < streamId.size && isAsciiDigit(streamId[position])) {
        position += 1
    }
    let pageEnd = position
    if (pageEnd == pageStart || !streamId[pageEnd..streamId.size].startsWith(marker)) {
        return None
    }
    position = pageEnd + marker.size
    let indexStart = position
    while (position < streamId.size && isAsciiDigit(streamId[position])) {
        position += 1
    }
    // The identifier must end after the index digits: "p1_img_0xyz" is not one.
    if (position == indexStart || position != streamId.size) {
        return None
    }
    let pageNumber = match (Int64.tryParse(streamId[pageStart..pageEnd])) {
        case Some(value) => value
        case None => return None
    }
    let imageIndex = match (Int64.tryParse(streamId[indexStart..position])) {
        case Some(value) => value
        case None => return None
    }
    return Some((pageNumber, imageIndex))
}

func isAsciiDigit(value: UInt8): Bool {
    return value >= b'0' && value <= b'9'
}

func imageError(message: String): String {
    return "{\"error\":" + jsonQuote(message) + "}"
}

// ---------------------------------------------------------------------------
// Font statistics

/** One accumulated font: the counters `pdf_analyze_fonts` reports. */
class FontEntry {
    let fontname: String
    var pages: ArrayList<Int64>
    var charCount: Int64
    var sizeMin: Float64
    var sizeMax: Float64
    var colors: ArrayList<String>

    init(fontname: String, size: Float64) {
        this.fontname = fontname
        this.pages = ArrayList<Int64>()
        this.charCount = 0
        this.sizeMin = size
        this.sizeMax = size
        this.colors = ArrayList<String>()
    }
}

/**
 * Per-font aggregation over a page range.
 *
 * One rule decides every field, matching `_accumulate_font_stats` in the Python
 * extractor: a char without a font name is ignored, `pages` keeps first-seen
 * (therefore ascending) order, `sizeMin`/`sizeMax` extend, `colors` keeps
 * first-seen order and is de-duplicated, and `charCount` counts *characters*,
 * not distinct strings. Entries are reported sorted by `charCount` descending;
 * the sort is a stable insertion sort, so equal counts keep the order in which
 * the fonts were first seen.
 */
class FontAccumulator {
    var entries: ArrayList<FontEntry>
    var positions: HashMap<String, Int64>

    init() {
        this.entries = ArrayList<FontEntry>()
        this.positions = HashMap<String, Int64>()
    }

    func addPage(chars: ArrayList<CharObj>, pageNumber: Int64): Unit {
        for (glyph in chars) {
            if (glyph.fontname.isEmpty()) {
                continue
            }
            var entry: FontEntry
            match (positions.get(glyph.fontname)) {
                case Some(position) => entry = entries[position]
                case None =>
                    entry = FontEntry(glyph.fontname, glyph.size)
                    positions.add(glyph.fontname, entries.size)
                    entries.add(entry)
            }
            entry.charCount += 1
            if (glyph.size < entry.sizeMin) {
                entry.sizeMin = glyph.size
            }
            if (glyph.size > entry.sizeMax) {
                entry.sizeMax = glyph.size
            }
            let color = colorStatString(glyph.color)
            if (!containsString(entry.colors, color)) {
                entry.colors.add(color)
            }
            if (!containsInt(entry.pages, pageNumber)) {
                entry.pages.add(pageNumber)
            }
        }
    }

    func toJson(): String {
        let builder = StringBuilder()
        builder.append("{\"fonts\":[")
        var first = true
        for (entry in sortedByCharCount()) {
            if (!first) {
                builder.append(",")
            }
            first = false
            builder.append("{\"fontname\":")
            builder.append(jsonQuote(entry.fontname))
            builder.append(",\"pages\":")
            builder.append(jsonIntArray(entry.pages))
            builder.append(",\"charCount\":${entry.charCount}")
            builder.append(",\"sizeMin\":")
            builder.append(formatFloatPy(entry.sizeMin))
            builder.append(",\"sizeMax\":")
            builder.append(formatFloatPy(entry.sizeMax))
            builder.append(",\"colors\":")
            builder.append(jsonStringArray(entry.colors.toArray()))
            builder.append("}")
        }
        builder.append("]}")
        return builder.toString()
    }

    func sortedByCharCount(): ArrayList<FontEntry> {
        let ordered = ArrayList<FontEntry>()
        for (entry in entries) {
            ordered.add(entry)
        }
        for (index in 1..ordered.size) {
            let current = ordered[index]
            var position = index - 1
            while (position >= 0 && ordered[position].charCount < current.charCount) {
                ordered[position + 1] = ordered[position]
                position -= 1
            }
            ordered[position + 1] = current
        }
        return ordered
    }
}

func containsString(values: ArrayList<String>, value: String): Bool {
    for (candidate in values) {
        if (candidate == value) {
            return true
        }
    }
    return false
}

func containsInt(values: ArrayList<Int64>, value: Int64): Bool {
    for (candidate in values) {
        if (candidate == value) {
            return true
        }
    }
    return false
}

// ---------------------------------------------------------------------------
// Export arguments and output files

/**
 * Trim/lower-case `value` and require it to be one of `choices`; `None` takes
 * the first choice, which is the documented default for both `format` and
 * `scope`.
 */
func normaliseChoice(value: Option<String>, choices: Array<String>, name: String): String {
    let raw = match (value) {
        case Some(text) => text
        case None => choices[0]
    }
    let normalised = raw.trimAscii().toAsciiLower()
    if (!choiceContains(choices, normalised)) {
        throw PdfToolError(
            "Invalid ${name}: " + quoted(raw) + " (expected one of " + quotedChoices(choices) + ")"
        )
    }
    return normalised
}

func choiceContains(choices: Array<String>, value: String): Bool {
    for (candidate in choices) {
        if (candidate == value) {
            return true
        }
    }
    return false
}

/** `'json', 'csv'` - the way the Python message lists the alternatives. */
func quotedChoices(choices: Array<String>): String {
    let builder = StringBuilder()
    var first = true
    for (choice in choices) {
        if (!first) {
            builder.append(", ")
        }
        first = false
        builder.append(quoted(choice))
    }
    return builder.toString()
}

/**
 * Write `content` to `output_path` and return the absolute path written.
 *
 * The bytes are the UTF-8 encoding of `content` and nothing else: no newline
 * translation and no BOM handling, so a CSV's leading BOM and its `\n` inside
 * quoted cells survive exactly as the exporter produced them.
 */
func writeExportFile(outputPath: String, content: String): String {
    if (outputPath.trimAscii().isEmpty()) {
        throw PdfToolError("Invalid output_path: " + quoted(outputPath) + " (expected a file path)")
    }
    let absolute = absolutePath(expandUser(outputPath))
    let parent = parentOf(absolute)
    if (!exists(parent) || !FileInfo(parent).isDirectory()) {
        throw PdfToolError(
            "Invalid output_path: " + quoted(outputPath) +
            " (directory ${parent} does not exist; create it first or choose another location)"
        )
    }
    if (exists(absolute) && FileInfo(absolute).isDirectory()) {
        throw PdfToolError("Invalid output_path: " + quoted(outputPath) + " (it is a directory, not a file)")
    }
    try {
        File.writeTo(absolute, content.toArray())
    } catch (error: Exception) {
        throw PdfToolError(
            "Invalid output_path: " + quoted(outputPath) + " (cannot write it: " + describe(error) + ")"
        )
    }
    return absolute
}

/**
 * Park an oversized export in the temp directory and return its path.
 *
 * The name follows `tempfile.mkstemp(prefix='pdf-inspector-', suffix='-<name>')`
 * — `pdf-inspector-<16 hex>-<suggested name>` — so every export gets its own file
 * while the client can still tell which document it belongs to.
 *
 * **Permissions.** The file holds document text, which the caller asked to see,
 * not to publish, so it is narrowed to `0600` right after being written: the
 * default umask leaves it world-readable, and in a shared `/tmp` that is a leak.
 * The `chmod` runs after the write because the file has to exist first; when it
 * fails the export itself is still valid, so the failure is reported on stderr
 * and the path is returned.
 *
 * **Remaining TOCTOU.** The name is reserved by checking `exists` and then
 * writing, which is not atomic: between the two calls another process could
 * create that exact path — a file, or a symlink the write would follow. This
 * toolchain has no `mkstemp`/`O_EXCL` binding to close the window, so the risk is
 * reduced rather than removed: the name carries 16 hex digits from the process
 * PRNG plus the suggested name, so landing on it requires guessing the name
 * before the write, and the file is narrowed to `0600` immediately afterwards.
 * That is accepted because the payload is an export the caller is already being
 * handed in full — the worst case is a copy of data the caller possesses, not
 * access to anything else the server can read.
 */
func writeTempExport(suggestedFilename: String, content: String): String {
    let directory = tempDirectoryPath()
    let bytes = content.toArray()
    let random = Random()
    var attempt = 0
    var failure = ""
    while (attempt < 8) {
        let token = hexToken(random.nextUInt32()) + hexToken(random.nextUInt32())
        let candidate = directory + "/pdf-inspector-" + token + "-" + suggestedFilename
        if (exists(candidate)) {
            attempt += 1
            continue
        }
        try {
            File.writeTo(candidate, bytes)
        } catch (error: Exception) {
            failure = describe(error)
            attempt += 1
            continue
        }
        restrictToOwner(candidate)
        return candidate
    }
    let reason = if (failure.isEmpty()) {
        "no unused file name could be reserved"
    } else {
        failure
    }
    throw PdfToolError("Cannot write the export to a temporary file in " + directory + ": " + reason)
}

/** Narrow an export file to owner read/write (`0600`); failures only warn. */
func restrictToOwner(path: String): Unit {
    // 0o600: read and write for the owner, nothing for group or other.
    if (chmod(path, 0o600) != 0) {
        eprintln("pdf-inspector-mcp: cannot restrict " + path + " to mode 0600")
    }
}

/** Eight lower-case hex digits; two calls make the 16-digit temp-file token. */
func hexToken(value: UInt32): String {
    let number = Int64(value)
    let builder = StringBuilder()
    var shift: Int64 = 28
    while (shift >= 0) {
        builder.append(hexDigit((number >> shift) & 0x0F))
        shift -= 4
    }
    return builder.toString()
}

/** `TMPDIR` when it is set, `/tmp` otherwise (Python's `tempfile.gettempdir()`). */
func tempDirectoryPath(): String {
    match (getVariable("TMPDIR")) {
        case Some(value) =>
            let trimmed = value.trimAscii()
            if (!trimmed.isEmpty()) {
                return trimmed
            }
        case None => ()
    }
    return "/tmp"
}
