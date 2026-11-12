package pdf_inspector_mcp.export

import std.collection.*
import std.convert.*
import std.time.*
import pdf_inspector_mcp.pdf.*

/**
 * JSON rendering of extracted pages, mirroring `export.pages_to_json` in
 * `src/pdf_inspector_mcp/export.py`.
 *
 * Two deliberate deviations from the Python module are documented here:
 *
 * 1. **Numbers.** Python's `json.dumps` keeps the float type, so a coordinate
 *    of 612 renders as `612.0`. This port renders every coordinate and size the
 *    way JavaScript's `String()`/`JSON.stringify` does (`612`), which is the
 *    behaviour the upstream TypeScript exporter has; `stdx`'s `JsonFloat`
 *    renders `612.000000` (fixed six decimals), so it is unusable here and the
 *    number text is produced by `jsNumberText` instead. Integral values lose
 *    their `.0`; other values use the shortest round-trip decimal in the same
 *    fixed/exponential ranges JavaScript uses (`1e-7` rather than `1e-07`).
 *
 * 2. **Key order.** `stdx.encoding.json.JsonObject` is backed by a hash map, so
 *    it cannot express the fixed key order the Python dictionaries (and the TS
 *    exporter) produce. The document is therefore built as an ordered node
 *    tree (`JNode`) and serialised with an explicit renderer that emits two
 *    spaces of indentation per level, exactly like `json.dumps(indent=2)` /
 *    `JSON.stringify(value, null, 2)`: `{}` and `[]` stay on one line, nested
 *    values are indented, and non-ASCII text is never escaped
 *    (`ensure_ascii=False`).
 *
 * The MCP layer exposes four entry points built on the same tree:
 *
 * - `pagesToJson` — the export payload (`pdf_export`), used for both
 *   `scope=page` (a one-element page list) and `scope=document`, exactly like
 *   the Python tool: metadata, timestamp, page count, object types, pages;
 * - `metadataToJson` — the `pdf_get_metadata` payload;
 * - `pageToJson` — one bare page (`pdf_extract_page`);
 * - `documentToJson` — metadata plus a page range (`pdf_extract_document`).
 *
 * `objects_to_json` (a flat object list with `page`/`objectCount`) is not
 * ported: no tool calls it.
 */

/** Ordered JSON tree: object field order is insertion order, not hash order. */
enum JNode {
    | JObj(ArrayList<(String, JNode)>)
    | JArr(ArrayList<JNode>)
    | JStr(String)
    | JInt(Int64)
    | JFloat(Float64)
    | JBool(Bool)
    | JNull
}

// --- document --------------------------------------------------------------

/**
 * Whole-document JSON: metadata, timestamp, page count, object types, pages.
 *
 * `types` follows `resolveTypes` (`None` = every type, explicit empty = no
 * object data). `exportedAt` is used verbatim when given, so callers can pin a
 * timestamp in tests; `None` uses the current UTC time.
 */
public func pagesToJson(
    pages: ArrayList<PageData>,
    metadata: PdfMetadata,
    types: Option<Array<String>>,
    exportedAt: Option<String>
): String {
    let selected = resolveTypes(types)
    let document = ArrayList<(String, JNode)>()
    document.add(("metadata", metadataNode(metadata)))
    document.add(("exportedAt", JStr(exportedAtText(exportedAt))))
    document.add(("pageCount", JInt(pages.size)))
    let objectTypes = ArrayList<JNode>()
    for (typeName in selected) {
        objectTypes.add(JStr(typeName))
    }
    document.add(("objectTypes", JArr(objectTypes)))
    let pageNodes = ArrayList<JNode>()
    for (page in pages) {
        pageNodes.add(pageNode(page, selected))
    }
    document.add(("pages", JArr(pageNodes)))
    return render(JObj(document))
}

// --- narrower entry points (MCP tool payloads) -----------------------------

/**
 * Document facts as JSON: `pages, version, encrypted, page_w, page_h, title,
 * author, producer, fonts` (the `pdf_get_metadata` payload).
 *
 * Same number rules as `pagesToJson`, so `page_w` of `612.0` prints `612`.
 */
public func metadataToJson(metadata: PdfMetadata): String {
    return render(metadataNode(metadata))
}

/**
 * One page as a bare page object: `width, height, chars, words, rects, lines,
 * curves, images, tables` — no metadata, timestamp, page count or object-type
 * list around it (the `pdf_extract_page` payload).
 *
 * Every type is emitted; this entry point does not filter. Field order inside
 * each object matches `pagesToJson`.
 */
public func pageToJson(page: PageData): String {
    return render(pageNode(page, resolveTypes(None)))
}

/**
 * Document facts plus pages, without the export bookkeeping: `metadata,
 * pageCount, pages` (the `pdf_extract_document` payload).
 *
 * `pageCount` is the number of pages handed in (a page range, not necessarily
 * the document total) and `pages` is filtered by `types` exactly like
 * `pagesToJson`: `None` keeps every type, an explicit empty selection blanks all
 * arrays while keeping the keys.
 */
public func documentToJson(
    metadata: PdfMetadata,
    pages: ArrayList<PageData>,
    types: Option<Array<String>>
): String {
    let selected = resolveTypes(types)
    let document = ArrayList<(String, JNode)>()
    document.add(("metadata", metadataNode(metadata)))
    document.add(("pageCount", JInt(pages.size)))
    let pageNodes = ArrayList<JNode>()
    for (page in pages) {
        pageNodes.add(pageNode(page, selected))
    }
    document.add(("pages", JArr(pageNodes)))
    return render(JObj(document))
}

func exportedAtText(exportedAt: Option<String>): String {
    match (exportedAt) {
        case Some(value) => return value
        case None => return isoNowUtc()
    }
}

/** ISO-8601 UTC with millisecond precision, as `Date.toISOString()`. */
func isoNowUtc(): String {
    let now = DateTime.nowUTC()
    let millisecond = now.nanosecond / 1_000_000
    return "${padLeft(now.year, 4)}-${padLeft(now.month.toInteger(), 2)}-${padLeft(now.dayOfMonth, 2)}T" +
        "${padLeft(now.hour, 2)}:${padLeft(now.minute, 2)}:${padLeft(now.second, 2)}." +
        "${padLeft(millisecond, 3)}Z"
}

func padLeft(value: Int64, width: Int64): String {
    let text = "${value}"
    let builder = StringBuilder()
    for (_ in 0..(width - text.size)) {
        builder.append("0")
    }
    builder.append(text)
    return builder.toString()
}

// --- page / object nodes ---------------------------------------------------

func metadataNode(metadata: PdfMetadata): JNode {
    let fields = ArrayList<(String, JNode)>()
    fields.add(("pages", JInt(metadata.pages)))
    fields.add(("version", JStr(metadata.version)))
    fields.add(("encrypted", JBool(metadata.encrypted)))
    fields.add(("page_w", JFloat(metadata.pageW)))
    fields.add(("page_h", JFloat(metadata.pageH)))
    fields.add(("title", JStr(metadata.title)))
    fields.add(("author", JStr(metadata.author)))
    fields.add(("producer", JStr(metadata.producer)))
    let fonts = ArrayList<JNode>()
    for (font in metadata.fonts) {
        fonts.add(JStr(font))
    }
    fields.add(("fonts", JArr(fonts)))
    return JObj(fields)
}

/** Spread the page, blanking out the arrays of unselected types. */
func pageNode(page: PageData, selected: Array<String>): JNode {
    let fields = ArrayList<(String, JNode)>()
    fields.add(("width", JFloat(page.width)))
    fields.add(("height", JFloat(page.height)))
    fields.add(("chars", charNodes(page, selected)))
    fields.add(("words", wordNodes(page, selected)))
    fields.add(("rects", rectNodes(page, selected)))
    fields.add(("lines", lineNodes(page, selected)))
    fields.add(("curves", curveNodes(page, selected)))
    fields.add(("images", imageNodes(page, selected)))
    fields.add(("tables", tableNodes(page, selected)))
    return JObj(fields)
}

func charNodes(page: PageData, selected: Array<String>): JNode {
    let nodes = ArrayList<JNode>()
    if (isSelected(selected, "char")) {
        for (char in page.chars) {
            let fields = ArrayList<(String, JNode)>()
            fields.add(("type", JStr("char")))
            fields.add(("x0", JFloat(char.x0)))
            fields.add(("y0", JFloat(char.y0)))
            fields.add(("x1", JFloat(char.x1)))
            fields.add(("y1", JFloat(char.y1)))
            fields.add(("text", JStr(char.text)))
            fields.add(("fontname", JStr(char.fontname)))
            fields.add(("size", JFloat(char.size)))
            fields.add(("color", colorNode(char.color)))
            fields.add(("page", JInt(char.page)))
            nodes.add(JObj(fields))
        }
    }
    return JArr(nodes)
}

func wordNodes(page: PageData, selected: Array<String>): JNode {
    let nodes = ArrayList<JNode>()
    if (isSelected(selected, "word")) {
        for (word in page.words) {
            let fields = ArrayList<(String, JNode)>()
            fields.add(("type", JStr("word")))
            fields.add(("x0", JFloat(word.x0)))
            fields.add(("y0", JFloat(word.y0)))
            fields.add(("x1", JFloat(word.x1)))
            fields.add(("y1", JFloat(word.y1)))
            fields.add(("text", JStr(word.text)))
            fields.add(("fontname", JStr(word.fontname)))
            fields.add(("size", JFloat(word.size)))
            fields.add(("page", JInt(word.page)))
            nodes.add(JObj(fields))
        }
    }
    return JArr(nodes)
}

func rectNodes(page: PageData, selected: Array<String>): JNode {
    let nodes = ArrayList<JNode>()
    if (isSelected(selected, "rect")) {
        for (rect in page.rects) {
            let fields = ArrayList<(String, JNode)>()
            fields.add(("type", JStr("rect")))
            fields.add(("x0", JFloat(rect.x0)))
            fields.add(("y0", JFloat(rect.y0)))
            fields.add(("x1", JFloat(rect.x1)))
            fields.add(("y1", JFloat(rect.y1)))
            fields.add(("fill", JBool(rect.fill)))
            fields.add(("stroke", JBool(rect.stroke)))
            fields.add(("color", colorNode(rect.color)))
            fields.add(("width", JFloat(rect.width)))
            fields.add(("page", JInt(rect.page)))
            nodes.add(JObj(fields))
        }
    }
    return JArr(nodes)
}

func lineNodes(page: PageData, selected: Array<String>): JNode {
    let nodes = ArrayList<JNode>()
    if (isSelected(selected, "line")) {
        for (line in page.lines) {
            let fields = ArrayList<(String, JNode)>()
            fields.add(("type", JStr("line")))
            fields.add(("x0", JFloat(line.x0)))
            fields.add(("y0", JFloat(line.y0)))
            fields.add(("x1", JFloat(line.x1)))
            fields.add(("y1", JFloat(line.y1)))
            fields.add(("stroke", JBool(line.stroke)))
            fields.add(("color", colorNode(line.color)))
            fields.add(("width", JFloat(line.width)))
            fields.add(("page", JInt(line.page)))
            nodes.add(JObj(fields))
        }
    }
    return JArr(nodes)
}

func curveNodes(page: PageData, selected: Array<String>): JNode {
    let nodes = ArrayList<JNode>()
    if (isSelected(selected, "curve")) {
        for (curve in page.curves) {
            let fields = ArrayList<(String, JNode)>()
            fields.add(("type", JStr("curve")))
            fields.add(("x0", JFloat(curve.x0)))
            fields.add(("y0", JFloat(curve.y0)))
            fields.add(("x1", JFloat(curve.x1)))
            fields.add(("y1", JFloat(curve.y1)))
            fields.add(("points", pointNodes(curve.points)))
            fields.add(("stroke", JBool(curve.stroke)))
            fields.add(("page", JInt(curve.page)))
            nodes.add(JObj(fields))
        }
    }
    return JArr(nodes)
}

/** `points` holds `[x, y]` pairs; render them as `[[x, y], ...]`. */
func pointNodes(points: Array<Array<Float64>>): JNode {
    let outer = ArrayList<JNode>()
    for (point in points) {
        let inner = ArrayList<JNode>()
        for (coordinate in point) {
            inner.add(JFloat(coordinate))
        }
        outer.add(JArr(inner))
    }
    return JArr(outer)
}

func imageNodes(page: PageData, selected: Array<String>): JNode {
    let nodes = ArrayList<JNode>()
    if (isSelected(selected, "image")) {
        for (image in page.images) {
            let fields = ArrayList<(String, JNode)>()
            fields.add(("type", JStr("image")))
            fields.add(("x0", JFloat(image.x0)))
            fields.add(("y0", JFloat(image.y0)))
            fields.add(("x1", JFloat(image.x1)))
            fields.add(("y1", JFloat(image.y1)))
            fields.add(("width", JFloat(image.width)))
            fields.add(("height", JFloat(image.height)))
            fields.add(("stream_id", JStr(image.streamId)))
            fields.add(("format", JStr(image.format)))
            fields.add(("page", JInt(image.page)))
            nodes.add(JObj(fields))
        }
    }
    return JArr(nodes)
}

func tableNodes(page: PageData, selected: Array<String>): JNode {
    let nodes = ArrayList<JNode>()
    if (isSelected(selected, "table")) {
        for (table in page.tables) {
            let fields = ArrayList<(String, JNode)>()
            fields.add(("type", JStr("table")))
            fields.add(("x0", JFloat(table.x0)))
            fields.add(("y0", JFloat(table.y0)))
            fields.add(("x1", JFloat(table.x1)))
            fields.add(("y1", JFloat(table.y1)))
            fields.add(("rows", JInt(table.rows)))
            fields.add(("cols", JInt(table.cols)))
            let rows = ArrayList<JNode>()
            for (row in table.cells) {
                let cells = ArrayList<JNode>()
                for (cell in row) {
                    cells.add(JStr(cell))
                }
                rows.add(JArr(cells))
            }
            fields.add(("cells", JArr(rows)))
            fields.add(("page", JInt(table.page)))
            nodes.add(JObj(fields))
        }
    }
    return JArr(nodes)
}

/**
 * A colour value: `[gray]`, `[r, g, b]`, `[c, m, y, k]`, or the name itself.
 *
 * pdfplumber passes `stroking_color` through untouched, so a colour is either a
 * tuple (an array here) or a string; that is what the Python exporter emits.
 */
func colorNode(color: PdfColor): JNode {
    match (color) {
        case PdfColor.Gray(gray) =>
            return JArr(single([JFloat(gray)]))
        case PdfColor.Rgb(red, green, blue) =>
            return JArr(single([JFloat(red), JFloat(green), JFloat(blue)]))
        case PdfColor.Cmyk(cyan, magenta, yellow, black) =>
            return JArr(single([JFloat(cyan), JFloat(magenta), JFloat(yellow), JFloat(black)]))
        case PdfColor.Named(name) =>
            return JStr(name)
    }
}

// --- renderer --------------------------------------------------------------

func render(node: JNode): String {
    let builder = StringBuilder()
    appendNode(builder, node, 0)
    return builder.toString()
}

func appendIndent(builder: StringBuilder, depth: Int64) {
    for (_ in 0..depth) {
        builder.append("  ")
    }
}

func appendNode(builder: StringBuilder, node: JNode, depth: Int64): Unit {
    match (node) {
        case JObj(fields) =>
            if (fields.isEmpty()) {
                builder.append("{}")
                return
            }
            builder.append("{\n")
            var first = true
            for ((key, value) in fields) {
                if (!first) {
                    builder.append(",\n")
                }
                first = false
                appendIndent(builder, depth + 1)
                appendString(builder, key)
                builder.append(": ")
                appendNode(builder, value, depth + 1)
            }
            builder.append("\n")
            appendIndent(builder, depth)
            builder.append("}")
        case JArr(items) =>
            if (items.isEmpty()) {
                builder.append("[]")
                return
            }
            builder.append("[\n")
            var first = true
            for (item in items) {
                if (!first) {
                    builder.append(",\n")
                }
                first = false
                appendIndent(builder, depth + 1)
                appendNode(builder, item, depth + 1)
            }
            builder.append("\n")
            appendIndent(builder, depth)
            builder.append("]")
        case JStr(text) =>
            appendString(builder, text)
        case JInt(value) =>
            builder.append("${value}")
        case JFloat(value) =>
            builder.append(jsNumberText(value))
        case JBool(value) =>
            builder.append(if (value) { "true" } else { "false" })
        case JNull =>
            builder.append("null")
    }
}

/**
 * JSON string as `ensure_ascii=False` prints it: only `"`, `\` and the C0
 * control characters are escaped, everything else (including CJK text) is
 * written through unchanged.
 */
func appendString(builder: StringBuilder, value: String) {
    builder.append("\"")
    for (rune in value.runes()) {
        let code = Int64(UInt32(rune))
        if (code == 0x22) {
            builder.append("\\\"")
        } else if (code == 0x5C) {
            builder.append("\\\\")
        } else if (code == 0x08) {
            builder.append("\\b")
        } else if (code == 0x0C) {
            builder.append("\\f")
        } else if (code == 0x0A) {
            builder.append("\\n")
        } else if (code == 0x0D) {
            builder.append("\\r")
        } else if (code == 0x09) {
            builder.append("\\t")
        } else if (code < 0x20) {
            builder.append("\\u00")
            appendHexDigit(builder, code / 16)
            appendHexDigit(builder, code % 16)
        } else {
            builder.append(rune)
        }
    }
    builder.append("\"")
}

func appendHexDigit(builder: StringBuilder, value: Int64) {
    if (value < 10) {
        builder.append(Rune(UInt32(0x30 + value)))
    } else {
        builder.append(Rune(UInt32(0x61 + value - 10)))
    }
}

// --- number formatting -----------------------------------------------------

/**
 * Render a float the way JavaScript's `String()` would.
 *
 * `NaN`/`Infinity`/`-Infinity` stay textual (Python's `json.dumps` prints the
 * same tokens), `-0.0` becomes `0`, and everything else is the shortest
 * round-trip decimal rendered in the ranges JavaScript uses: fixed notation
 * for `1e-6 <= |v| < 1e21`, exponential above/below it (`1e-7`, `1e+21`).
 */
func jsNumberText(value: Float64): String {
    if (value != value) {
        return "NaN"
    }
    if (value == Float64.Inf) {
        return "Infinity"
    }
    if (value == -Float64.Inf) {
        return "-Infinity"
    }
    if (value == 0.0) {
        // String(-0) is '0'.
        return "0"
    }
    let negative = value < 0.0
    let magnitude = if (negative) {
        -value
    } else {
        value
    }
    if (magnitude < 1.0e18 && magnitude == Float64(Int64(magnitude))) {
        // Integral values are the common case (coordinates, sizes): `String()`
        // prints them without a fractional part, so skip the digit search.
        let text = "${Int64(magnitude)}"
        return if (negative) {
            "-" + text
        } else {
            text
        }
    }
    let (digits, exponent) = shortestDigits(magnitude)
    // `n` is the position of the decimal point: value == 0.<digits> x 10^n.
    let n = exponent + 1
    let count = digits.size
    let builder = StringBuilder()
    if (negative) {
        builder.append("-")
    }
    if (count <= n && n <= 21) {
        builder.append(digits)
        for (_ in 0..(n - count)) {
            builder.append("0")
        }
    } else if (0 < n && n <= 21) {
        builder.append(digits[0..n])
        builder.append(".")
        builder.append(digits[n..count])
    } else if (-6 < n && n <= 0) {
        builder.append("0.")
        for (_ in 0..(-n)) {
            builder.append("0")
        }
        builder.append(digits)
    } else {
        builder.append(digits[0..1])
        if (count > 1) {
            builder.append(".")
            builder.append(digits[1..count])
        }
        builder.append("e")
        let scientific = n - 1
        if (scientific < 0) {
            builder.append("-")
            builder.append("${-scientific}")
        } else {
            builder.append("+")
            builder.append("${scientific}")
        }
    }
    return builder.toString()
}

/**
 * Shortest decimal digits that round-trip to `magnitude`, plus the exponent of
 * the leading digit (`6.12e+02` -> `("612", 2)`).
 *
 * `std.convert` has no shortest-round-trip float formatter and `Float64`'s
 * `toString()` prints a fixed six decimals, so the digits are derived: one
 * 17-significant-digit rendering (exact for every `Float64`) is rounded down to
 * fewer digits until the value parses back unchanged. `format` is the expensive
 * call here, so it runs once and the shorter candidates are produced by decimal
 * rounding of that digit string.
 *
 * A k-digit rounding of the 17-digit form can differ from the true k-digit
 * rounding of the binary value only when the value sits on a decimal tie, which
 * cannot happen for the coordinates and sizes a PDF carries; were it to happen,
 * the search would simply settle on one extra digit (still exact, one digit
 * longer than JavaScript would print).
 */
func shortestDigits(magnitude: Float64): (String, Int64) {
    let text = magnitude.format(".16e")
    let mark = text.indexOf("e").getOrThrow()
    let exact = text[0..mark].replace(".", "")
    var exponentText = text[mark + 1..text.size]
    if (exponentText.startsWith("+")) {
        exponentText = exponentText[1..]
    }
    let exponent = Int64.parse(exponentText)
    for (count in 1..18) {
        let rounded = roundDigits(exact, count)
        // A carry out of the leading digit ("999" -> "1000") raises the exponent.
        let currentExponent = if (rounded.size > count) {
            exponent + 1
        } else {
            exponent
        }
        let digits = stripTrailingZeros(rounded)
        if (Float64.parse(scientificText(digits, currentExponent)) == magnitude) {
            return (digits, currentExponent)
        }
    }
    return (stripTrailingZeros(exact), exponent)
}

/** `<digits> x 10^<exponent-of-first-digit>` as a `Float64.parse` argument. */
func scientificText(digits: String, exponent: Int64): String {
    if (digits.size == 1) {
        return "${digits}e${exponent}"
    }
    return "${digits[0..1]}.${digits[1..digits.size]}e${exponent}"
}

/** Round a decimal digit string to `count` significant digits (half up). */
func roundDigits(digits: String, count: Int64): String {
    if (count >= digits.size) {
        return digits
    }
    var kept = Array<Int64>(count, repeat: 0)
    for (index in 0..count) {
        kept[index] = Int64(digits[index]) - 48
    }
    let builder = StringBuilder()
    if (Int64(digits[count]) - 48 >= 5) {
        var index = count - 1
        var carry = true
        while (index >= 0 && carry) {
            kept[index] += 1
            if (kept[index] == 10) {
                kept[index] = 0
                index -= 1
            } else {
                carry = false
            }
        }
        if (carry) {
            builder.append("1")
            for (_ in 0..count) {
                builder.append("0")
            }
            return builder.toString()
        }
    }
    for (digit in kept) {
        builder.append(Rune(UInt32(48 + digit)))
    }
    return builder.toString()
}

func stripTrailingZeros(digits: String): String {
    var end = digits.size
    while (end > 1 && digits[end - 1] == b'0') {
        end -= 1
    }
    return digits[0..end]
}

func single(items: Array<JNode>): ArrayList<JNode> {
    let values = ArrayList<JNode>()
    for (item in items) {
        values.add(item)
    }
    return values
}
