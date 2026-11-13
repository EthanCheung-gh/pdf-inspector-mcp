package pdf4cj.test

import std.collection.*
import std.fs.*
import std.random.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import pdf4cj.*

/**
 * Tests for the ruled-table finder.
 *
 * The inputs are synthetic [PageData]s that mirror the geometric facts the
 * content layer reports for `tests/pdf_fixtures.py::make_table_pdf`, so the
 * expectations here are the ones that fixture pins down: one 2x2 table with an
 * empty bottom-left cell and a bbox of `(50, 62, 350, 142)` in top coordinates.
 *
 * [extractTables] needs a [PdfPage] (for the page height it flips y with), which
 * is only reachable through a real document, so each test opens a tiny probe PDF
 * and feeds its own `PageData` in. The probe carries no drawing at all: every
 * coordinate under test comes from the synthesised objects.
 */

// ---------------------------------------------------------------------------
// The make_table_pdf fixture

@Test
func tableFindsRuledGridAndEmptyCell(): Unit {
    let document = tableProbeDocument()
    let page = document.page(1)
    let data = PageData(width: 612.0, height: 792.0)
    // reportlab: rect(50, 650, 300, 80) + line(200, 650, 200, 730) + line(50, 690, 350, 690)
    data.rects.add(RectObj(x0: 50.0, y0: 650.0, x1: 350.0, y1: 730.0, stroke: true, width: 1.0, page: 1))
    data.lines.add(LineObj(x0: 200.0, y0: 650.0, x1: 200.0, y1: 730.0, page: 1))
    data.lines.add(LineObj(x0: 50.0, y0: 690.0, x1: 350.0, y1: 690.0, page: 1))
    // drawString(60, 700, "Header A"), drawString(210, 700, "Header B"),
    // drawString(210, 660, "Row B1") at Helvetica 10.
    for (char in tableTextAt("Header A", 60.0, 700.0)) {
        data.chars.add(char)
    }
    for (char in tableTextAt("Header B", 210.0, 700.0)) {
        data.chars.add(char)
    }
    for (char in tableTextAt("Row B1", 210.0, 660.0)) {
        data.chars.add(char)
    }
    let tables = extractTables(page, data)
    document.close()

    @Expect(tables.size, 1)
    @Expect(tables[0].rows, 2)
    @Expect(tables[0].cols, 2)
    @Expect(tables[0].cells.size, 2)
    @Expect(tables[0].cells[0].size, 2)
    @Expect(tables[0].cells[0][0], "Header A")
    @Expect(tables[0].cells[0][1], "Header B")
    @Expect(tables[0].cells[1][0], "")
    @Expect(tables[0].cells[1][1], "Row B1")
    @Expect(tables[0].page, 1)
    // Python's pdfplumber bbox for the fixture, in top coordinates.
    @Assert(tableNear(tables[0].x0, 50.0, 0.5))
    @Assert(tableNear(tables[0].y0, 62.0, 0.5))
    @Assert(tableNear(tables[0].x1, 350.0, 0.5))
    @Assert(tableNear(tables[0].y1, 142.0, 0.5))
}

@Test
func tableCollectsCharsOnlyByTheirCentre(): Unit {
    let document = tableProbeDocument()
    let page = document.page(1)
    let data = PageData(width: 612.0, height: 792.0)
    // Two cells side by side: x 50..125 and x 125..200, both y 650..730.
    data.rects.add(RectObj(x0: 50.0, y0: 650.0, x1: 200.0, y1: 730.0, stroke: true, page: 1))
    data.lines.add(LineObj(x0: 125.0, y0: 650.0, x1: 125.0, y1: 730.0, page: 1))
    // Inside the left cell: its centre is (62, 705).
    data.chars.add(tableChar("in", 60.0, 700.0, 4.0))
    // Straddling the left border: x0 = 45, x1 = 55, centre 50 exactly on it.
    data.chars.add(tableChar("on", 45.0, 700.0, 10.0))
    // Outside: centre sits left of the grid.
    data.chars.add(tableChar("out", 0.0, 700.0, 20.0))
    let tables = extractTables(page, data)
    document.close()

    @Expect(tables.size, 1)
    @Expect(tables[0].rows, 1)
    @Expect(tables[0].cols, 2)
    // "on" straddles the edge but its centre is on the border, so it is included;
    // "out" ends at x = 20 and stays outside. Reading order is by x, not by
    // insertion order. The right cell has no text at all.
    @Expect(tables[0].cells[0][0], "on in")
    @Expect(tables[0].cells[0][1], "")
}

// ---------------------------------------------------------------------------
// Cell text layout

@Test
func tableCellTextKeepsBothLinesOfAMultiLineCell(): Unit {
    let document = tableProbeDocument()
    let page = document.page(1)
    let data = PageData(width: 612.0, height: 792.0)
    // Left cell x 50..150 keeps the two lines; the right cell closes the grid.
    data.rects.add(RectObj(x0: 50.0, y0: 650.0, x1: 300.0, y1: 730.0, stroke: true, page: 1))
    data.lines.add(LineObj(x0: 150.0, y0: 650.0, x1: 150.0, y1: 730.0, page: 1))
    for (char in tableTextAt("ab", 60.0, 700.0)) {
        data.chars.add(char)
    }
    for (char in tableTextAt("c", 60.0, 680.0)) {
        data.chars.add(char)
    }
    let tables = extractTables(page, data)
    document.close()

    @Expect(tables.size, 1)
    @Expect(tables[0].cells[0][0], "ab\nc")
}

@Test
func tableCellTextAddsASpaceForAWideGap(): Unit {
    let document = tableProbeDocument()
    let page = document.page(1)
    let data = PageData(width: 612.0, height: 792.0)
    data.rects.add(RectObj(x0: 50.0, y0: 650.0, x1: 300.0, y1: 730.0, stroke: true, page: 1))
    data.lines.add(LineObj(x0: 150.0, y0: 650.0, x1: 150.0, y1: 730.0, page: 1))
    // Two glyphs with an 8pt gap between them: one space, not one word.
    data.chars.add(tableChar("a", 60.0, 700.0, 6.0))
    data.chars.add(tableChar("b", 74.0, 700.0, 6.0))
    let tables = extractTables(page, data)
    document.close()

    @Expect(tables[0].cells[0][0], "a b")
}

// ---------------------------------------------------------------------------
// Geometry edge cases

@Test
func tableKeepsSeparateGridsApart(): Unit {
    let document = tableProbeDocument()
    let page = document.page(1)
    let data = PageData(width: 612.0, height: 792.0)
    // Two two-cell grids, far apart: splitting the rules into components must keep
    // them as separate tables instead of merging them into one big one.
    data.rects.add(RectObj(x0: 50.0, y0: 650.0, x1: 150.0, y1: 700.0, stroke: true, page: 1))
    data.lines.add(LineObj(x0: 100.0, y0: 650.0, x1: 100.0, y1: 700.0, page: 1))
    data.rects.add(RectObj(x0: 300.0, y0: 650.0, x1: 450.0, y1: 700.0, stroke: true, page: 1))
    data.lines.add(LineObj(x0: 375.0, y0: 650.0, x1: 375.0, y1: 700.0, page: 1))
    let tables = extractTables(page, data)
    document.close()

    @Expect(tables.size, 2)
    // Both share the same top, so the left one comes first.
    @Assert(tableNear(tables[0].x0, 50.0, 0.5))
    @Assert(tableNear(tables[0].x1, 150.0, 0.5))
    @Expect(tables[0].cols, 2)
    @Assert(tableNear(tables[1].x0, 300.0, 0.5))
    @Assert(tableNear(tables[1].x1, 450.0, 0.5))
    @Expect(tables[1].cols, 2)
}

@Test
func tableMergesAFrameWithItsInnerRules(): Unit {
    let document = tableProbeDocument()
    let page = document.page(1)
    let data = PageData(width: 612.0, height: 792.0)
    // Outer frame plus one vertical rule: a 1x2 table, not two tables.
    data.rects.add(RectObj(x0: 50.0, y0: 650.0, x1: 350.0, y1: 730.0, stroke: true, page: 1))
    data.lines.add(LineObj(x0: 200.0, y0: 650.0, x1: 200.0, y1: 730.0, page: 1))
    let tables = extractTables(page, data)
    document.close()

    @Expect(tables.size, 1)
    @Expect(tables[0].rows, 1)
    @Expect(tables[0].cols, 2)
}

@Test
func tableIgnoresRulesWithoutAGrid(): Unit {
    let document = tableProbeDocument()
    let page = document.page(1)
    let data = PageData(width: 612.0, height: 792.0)
    // A lone underline: one horizontal edge, no cell.
    data.lines.add(LineObj(x0: 50.0, y0: 690.0, x1: 350.0, y1: 690.0, page: 1))
    // A slanted line is not a grid edge either.
    data.lines.add(LineObj(x0: 60.0, y0: 600.0, x1: 300.0, y1: 640.0, page: 1))
    let tables = extractTables(page, data)
    document.close()

    @Expect(tables.size, 0)
}

@Test
func tableIgnoresUnruledTextBlocks(): Unit {
    let document = tableProbeDocument()
    let page = document.page(1)
    let data = PageData(width: 612.0, height: 792.0)
    // Text alone never makes a table: no whitespace/alignment strategy here.
    for (char in tableTextAt("Header A", 60.0, 700.0)) {
        data.chars.add(char)
    }
    let tables = extractTables(page, data)
    document.close()

    @Expect(tables.size, 0)
}

@Test
func tableIgnoresASingleClosedBox(): Unit {
    let document = tableProbeDocument()
    let page = document.page(1)
    let data = PageData(width: 612.0, height: 792.0)
    // A lone rectangle (a highlight, a coloured header, an image frame) encloses
    // exactly one cell. pdfplumber keeps only groups with more than one cell, and
    // so do we: otherwise every filled box in a document would become a table.
    data.rects.add(RectObj(x0: 50.0, y0: 650.0, x1: 350.0, y1: 730.0, fill: true, page: 1))
    for (char in tableTextAt("inside", 60.0, 700.0)) {
        data.chars.add(char)
    }
    let tables = extractTables(page, data)
    document.close()

    @Expect(tables.size, 0)
}

@Test
func tableSnapsNearlyCollinearRules(): Unit {
    let document = tableProbeDocument()
    let page = document.page(1)
    let data = PageData(width: 612.0, height: 792.0)
    // Same grid as the fixture, but the drawn rules are 1.5pt off their nominal
    // positions - inside pdfplumber's 2.5pt snap tolerance.
    data.rects.add(RectObj(x0: 50.0, y0: 650.0, x1: 350.0, y1: 730.0, stroke: true, page: 1))
    data.lines.add(LineObj(x0: 201.5, y0: 651.0, x1: 201.5, y1: 731.0, page: 1))
    data.lines.add(LineObj(x0: 51.0, y0: 691.5, x1: 351.0, y1: 691.5, page: 1))
    let tables = extractTables(page, data)
    document.close()

    @Expect(tables.size, 1)
    @Expect(tables[0].rows, 2)
    @Expect(tables[0].cols, 2)
}

// ---------------------------------------------------------------------------
// Helpers

func tableNear(actual: Float64, expected: Float64, tolerance: Float64): Bool {
    let difference = if (actual > expected) { actual - expected } else { expected - actual }
    difference <= tolerance
}

/** One synthetic glyph: `width` wide, 10pt tall, starting at (`x`, `y`). */
func tableChar(text: String, x: Float64, y: Float64, width: Float64): CharObj {
    CharObj(text: text, x0: x, y0: y, x1: x + width, y1: y + 10.0, size: 10.0, page: 1)
}

/**
 * Lay `text` out as individual glyphs from (`x`, `y`), advancing 7pt per glyph
 * and 3pt per space, which is close enough to Helvetica 10 for grid tests.
 */
func tableTextAt(text: String, x: Float64, y: Float64): ArrayList<CharObj> {
    let chars = ArrayList<CharObj>()
    var cursor = x
    for (rune in text.runes()) {
        let glyph = rune.toString()
        let advance = if (glyph == " ") { 3.0 } else { 7.0 }
        chars.add(tableChar(glyph, cursor, y, advance))
        cursor += advance
    }
    chars
}

/**
 * Write a one-page, drawing-free probe PDF and open it.
 *
 * The path is unique per call (random token + sub-second nanoseconds) so two
 * concurrent `cjpm test` runs cannot read each other's file, and it is deleted
 * in the `finally` - `PdfDocument.open` reads the whole file into memory, so the
 * document stays usable.
 */
func tableProbeDocument(): PdfDocument {
    let token = Random().nextUInt32().toString() + "-" + DateTime.nowUTC().nanosecond.toString()
    let path = "/tmp/cangjie-table-probe-" + token + ".pdf"
    tableWriteProbePdf(path)
    try {
        return PdfDocument.open(path, None)
    } finally {
        removeIfExists(path)
    }
}

/**
 * Minimal single-page PDF: no fonts, an empty `q Q` content stream, US Letter.
 *
 * Only the page box matters here; every object under test is synthesised by the
 * test itself. The layout mirrors `tests/pdf_fixtures.py::_write_pdf` so the
 * parser takes its normal path (classic xref table, numbered objects).
 */
func tableWriteProbePdf(path: String): Unit {
    let content = "q Q"
    var text = "%PDF-1.4\n"
    let offsets = ArrayList<Int64>()
    offsets.add(Int64(text.size))
    text = text + "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
    offsets.add(Int64(text.size))
    text = text + "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n"
    offsets.add(Int64(text.size))
    text = text + "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << >> /Contents 4 0 R >>\nendobj\n"
    offsets.add(Int64(text.size))
    text = text + "4 0 obj\n<< /Length ${content.size} >>\nstream\n${content}\nendstream\nendobj\n"
    let xrefPosition = Int64(text.size)
    text = text + "xref\n0 5\n0000000000 65535 f \n"
    for (offset in offsets) {
        text = text + "${tablePadOffset(offset)} 00000 n \n"
    }
    text = text + "trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n${xrefPosition}\n%%EOF\n"
    File.writeTo(path, text.toArray())
}

func tablePadOffset(value: Int64): String {
    var text = value.toString()
    while (text.size < 10) {
        text = "0" + text
    }
    text
}
