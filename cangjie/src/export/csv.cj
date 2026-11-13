package pdf_inspector_mcp.export

import std.collection.*
import pdf4cj.*

/**
 * CSV rendering of extracted pages, mirroring `export.pages_to_csv` in
 * `src/pdf_inspector_mcp/export.py`.
 *
 * One document holds one `# <type>` section per selected type, in canonical
 * `EXPORT_OBJECT_TYPES` order; an explicitly empty (or fully unknown) selection
 * produces just the BOM. The document starts with a UTF-8 BOM so Excel decodes
 * it as UTF-8, rows are separated by `\n`, the text ends with `\n`, and cells
 * are quoted per RFC 4180 (only `,`, `"`, CR and LF force quotes, inner quotes
 * double).
 *
 * Cell values emulate JavaScript's `String()`, because the upstream TypeScript
 * exporter formats every cell that way: booleans are `true`/`false`, integral
 * floats lose their `.0` (`12.0` -> `12`, `1.0` -> `1`), other floats use the
 * shortest round-trip representation in the fixed/exponential ranges JavaScript
 * uses (`0.5` -> `0.5`, `1e-7` rather than `1e-07`, `NaN`/`Infinity` stay
 * textual). Number text comes from `jsNumberText` in `json.cj` so both outputs
 * agree.
 *
 * Colour cells flatten like `Array.prototype.toString` (comma-joined), which is
 * what the TypeScript exporter sees for pdfplumber's tuple-valued
 * `stroking_color`: `Gray(0)` -> `0`, `Rgb(1, 0.5, 0)` -> `1,0.5,0` (then
 * quoted, since it contains commas), and `Named("black")` -> `black`. Curve
 * points never take that path; they are pre-serialised as compact JSON
 * (`[[0,0],[5,5]]`) and therefore always quoted.
 */

private let BOM = "\u{FEFF}"

/** CSV of every selected type across all pages. */
public func pagesToCsv(pages: ArrayList<PageData>, types: Option<Array<String>>): String {
    let selected = resolveTypes(types)
    if (selected.size == 0) {
        return BOM
    }
    let lines = ArrayList<String>()
    for (typeName in selected) {
        appendSection(lines, typeName, pages)
    }
    let builder = StringBuilder()
    builder.append(BOM)
    for (line in lines) {
        builder.append(line)
        builder.append("\n")
    }
    return builder.toString()
}

func appendSection(lines: ArrayList<String>, typeName: String, pages: ArrayList<PageData>) {
    if (typeName == "char") {
        lines.add("# chars")
        lines.add(csvRow(["page", "x0", "y0", "x1", "y1", "text", "fontname", "size", "color"]))
        for (page in pages) {
            for (char in page.chars) {
                lines.add(
                    csvRow([
                        "${char.page}", jsNumberText(char.x0), jsNumberText(char.y0), jsNumberText(char.x1),
                        jsNumberText(char.y1), char.text, char.fontname, jsNumberText(char.size),
                        colorText(char.color)
                    ])
                )
            }
        }
    } else if (typeName == "word") {
        lines.add("# words")
        lines.add(csvRow(["page", "x0", "y0", "x1", "y1", "text", "fontname", "size"]))
        for (page in pages) {
            for (word in page.words) {
                lines.add(
                    csvRow([
                        "${word.page}", jsNumberText(word.x0), jsNumberText(word.y0), jsNumberText(word.x1),
                        jsNumberText(word.y1), word.text, word.fontname, jsNumberText(word.size)
                    ])
                )
            }
        }
    } else if (typeName == "rect") {
        lines.add("# rects")
        lines.add(csvRow(["page", "x0", "y0", "x1", "y1", "fill", "stroke", "color", "width"]))
        for (page in pages) {
            for (rect in page.rects) {
                lines.add(
                    csvRow([
                        "${rect.page}", jsNumberText(rect.x0), jsNumberText(rect.y0), jsNumberText(rect.x1),
                        jsNumberText(rect.y1), booleanText(rect.fill), booleanText(rect.stroke),
                        colorText(rect.color), jsNumberText(rect.width)
                    ])
                )
            }
        }
    } else if (typeName == "line") {
        lines.add("# lines")
        lines.add(csvRow(["page", "x0", "y0", "x1", "y1", "stroke", "color", "width"]))
        for (page in pages) {
            for (line in page.lines) {
                lines.add(
                    csvRow([
                        "${line.page}", jsNumberText(line.x0), jsNumberText(line.y0), jsNumberText(line.x1),
                        jsNumberText(line.y1), booleanText(line.stroke), colorText(line.color),
                        jsNumberText(line.width)
                    ])
                )
            }
        }
    } else if (typeName == "curve") {
        lines.add("# curves")
        lines.add(csvRow(["page", "x0", "y0", "x1", "y1", "points", "stroke"]))
        for (page in pages) {
            for (curve in page.curves) {
                lines.add(
                    csvRow([
                        "${curve.page}", jsNumberText(curve.x0), jsNumberText(curve.y0),
                        jsNumberText(curve.x1), jsNumberText(curve.y1), pointsJson(curve.points),
                        booleanText(curve.stroke)
                    ])
                )
            }
        }
    } else if (typeName == "image") {
        lines.add("# images")
        lines.add(csvRow(["page", "x0", "y0", "x1", "y1", "width", "height", "stream_id", "format"]))
        for (page in pages) {
            for (image in page.images) {
                lines.add(
                    csvRow([
                        "${image.page}", jsNumberText(image.x0), jsNumberText(image.y0),
                        jsNumberText(image.x1), jsNumberText(image.y1), jsNumberText(image.width),
                        jsNumberText(image.height), image.streamId, image.format
                    ])
                )
            }
        }
    } else if (typeName == "table") {
        lines.add("# tables")
        lines.add(csvRow(["page", "table_index", "row", "col", "text"]))
        for (page in pages) {
            // Table indexes restart per page, like `enumerate(page['tables'])`.
            var tableIndex = 0
            for (table in page.tables) {
                var rowIndex = 0
                for (row in table.cells) {
                    var colIndex = 0
                    for (cell in row) {
                        lines.add(
                            csvRow(["${table.page}", "${tableIndex}", "${rowIndex}", "${colIndex}", cell])
                        )
                        colIndex += 1
                    }
                    rowIndex += 1
                }
                tableIndex += 1
            }
        }
    }
}

/** One row: RFC 4180 quoting per cell, `,` between cells. */
func csvRow(cells: Array<String>): String {
    let builder = StringBuilder()
    var first = true
    for (cell in cells) {
        if (!first) {
            builder.append(",")
        }
        first = false
        builder.append(csvEscape(cell))
    }
    return builder.toString()
}

func csvEscape(value: String): String {
    var needsQuotes = false
    for (rune in value.runes()) {
        let code = Int64(UInt32(rune))
        if (code == 0x2C || code == 0x22 || code == 0x0A || code == 0x0D) {
            needsQuotes = true
            break
        }
    }
    if (!needsQuotes) {
        return value
    }
    let builder = StringBuilder()
    builder.append("\"")
    for (rune in value.runes()) {
        if (Int64(UInt32(rune)) == 0x22) {
            builder.append("\"\"")
        } else {
            builder.append(rune)
        }
    }
    builder.append("\"")
    return builder.toString()
}

func booleanText(value: Bool): String {
    return if (value) {
        "true"
    } else {
        "false"
    }
}

/** `Array.prototype.toString` over the colour components. */
func colorText(color: PdfColor): String {
    match (color) {
        case PdfColor.Gray(gray) => return jsNumberText(gray)
        case PdfColor.Rgb(red, green, blue) =>
            return "${jsNumberText(red)},${jsNumberText(green)},${jsNumberText(blue)}"
        case PdfColor.Cmyk(cyan, magenta, yellow, black) =>
            return "${jsNumberText(cyan)},${jsNumberText(magenta)},${jsNumberText(yellow)},${jsNumberText(black)}"
        case PdfColor.Named(name) => return name
    }
}

/** `JSON.stringify(points)` without indentation: `[[0,0],[5,5]]`. */
func pointsJson(points: Array<Array<Float64>>): String {
    let builder = StringBuilder()
    builder.append("[")
    var firstPoint = true
    for (point in points) {
        if (!firstPoint) {
            builder.append(",")
        }
        firstPoint = false
        builder.append("[")
        var firstCoordinate = true
        for (coordinate in point) {
            if (!firstCoordinate) {
                builder.append(",")
            }
            firstCoordinate = false
            builder.append(jsNumberText(coordinate))
        }
        builder.append("]")
    }
    builder.append("]")
    return builder.toString()
}
