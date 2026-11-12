package pdf_inspector_mcp.tests

import std.collection.*
import std.fs.*
import std.random.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import pdf_inspector_mcp.pdf.*

/**
 * Tests for the content layer: word grouping over synthetic characters, the
 * formatting helpers, and one end-to-end run of [extractPage] over a hand-built
 * PDF whose content stream exercises text, fill, stroke and Bézier operators.
 *
 * The content-stream lexer itself is package-private, so it is covered through
 * `extractPage`; the cross-check against pdfplumber lives in the extract-dump
 * self-check described in the work report.
 */

// ---------------------------------------------------------------------------
// buildWords

@Test
func wordsSplitAtWhitespaceAndKeepReadingOrder(): Unit {
    let chars = ArrayList<CharObj>()
    // Line 1 baseline 700: "Hello World", the space being its own glyph.
    chars.add(makeChar("H", 10.0, 16.0, 700.0, 712.0))
    chars.add(makeChar("e", 16.0, 22.0, 700.0, 712.0))
    chars.add(makeChar("l", 22.0, 28.0, 700.0, 712.0))
    chars.add(makeChar("l", 28.0, 34.0, 700.0, 712.0))
    chars.add(makeChar("o", 34.0, 40.0, 700.0, 712.0))
    chars.add(makeChar(" ", 40.0, 43.0, 700.0, 712.0))
    chars.add(makeChar("W", 43.0, 49.0, 700.0, 712.0))
    // Line 2, lower on the page: must come second.
    chars.add(makeChar("low", 10.0, 28.0, 680.0, 692.0))
    let words = buildWords(chars)
    @Expect(words.size, 3)
    @Expect(words[0].text, "Hello")
    @Expect(words[1].text, "W")
    @Expect(words[2].text, "low")
    @Assert(near(words[0].x0, 10.0, 0.001))
    @Assert(near(words[0].x1, 40.0, 0.001))
    @Assert(near(words[0].y0, 700.0, 0.001))
    @Assert(near(words[0].y1, 712.0, 0.001))
    @Expect(words[0].fontname, "Helvetica")
}

@Test
func wordsMergeSmallGapsAndSplitWideGaps(): Unit {
    let chars = ArrayList<CharObj>()
    chars.add(makeChar("a", 0.0, 10.0, 100.0, 110.0))
    chars.add(makeChar("b", 12.0, 22.0, 100.0, 110.0))
    chars.add(makeChar("c", 40.0, 50.0, 100.0, 110.0))
    let words = buildWords(chars)
    @Expect(words.size, 2)
    @Expect(words[0].text, "ab")
    @Expect(words[1].text, "c")
    @Assert(near(words[0].x1, 22.0, 0.001))
    @Assert(near(words[1].x0, 40.0, 0.001))
}

@Test
func wordsIgnoreEmptyAndBlankGlyphs(): Unit {
    let chars = ArrayList<CharObj>()
    chars.add(makeChar("", 0.0, 0.0, 100.0, 110.0))
    chars.add(makeChar("x", 5.0, 15.0, 100.0, 110.0))
    chars.add(makeChar("\t", 15.0, 20.0, 100.0, 110.0))
    chars.add(makeChar("y", 20.0, 30.0, 100.0, 110.0))
    let words = buildWords(chars)
    @Expect(words.size, 2)
    @Expect(words[0].text, "x")
    @Expect(words[1].text, "y")
}

@Test
func wordsOfEmptyInputAreEmpty(): Unit {
    let words = buildWords(ArrayList<CharObj>())
    @Expect(words.size, 0)
}

// ---------------------------------------------------------------------------
// Formatting helpers

@Test
func numbersFormatWithFixedDecimals(): Unit {
    @Expect(formatDecimal(127.3559, 3), "127.356")
    @Expect(formatDecimal(1.23456, 2), "1.23")
    @Expect(formatDecimal(12.0, 1), "12.0")
    @Expect(formatDecimal(-2.5, 0), "-3")
    @Expect(formatDecimal(0.0, 2), "0.00")
}

@Test
func colorsDescribeAllVariants(): Unit {
    @Expect(describeColor(PdfColor.Gray(0.0)), "Gray(0.000)")
    @Expect(describeColor(PdfColor.Rgb(1.0, 0.0, 0.0)), "Rgb(1.000,0.000,0.000)")
    @Expect(describeColor(PdfColor.Cmyk(0.0, 0.0, 0.0, 1.0)), "Cmyk(0.000,0.000,0.000,1.000)")
    @Expect(describeColor(PdfColor.Named("P0")), "Named(P0)")
}

// ---------------------------------------------------------------------------
// extractPage over hand-written content streams

@Test
func extractPageReadsTextPathsAndCurves(): Unit {
    let content = "BT /F1 12 Tf 72 700 Td (Hi) Tj ET\n" +
        "0 0 1 rg 50 50 100 40 re f\n" +
        "1 0 0 RG 2 w 10 10 m 110 10 l S\n" +
        "20 20 m 30 40 40 40 50 20 c S\n"
    let path = contentTempPath("main")
    writeTestPdf(path, content)
    let document = PdfDocument.open(path, None)
    removeIfExists(path)
    let data = extractPage(document, document.page(1))
    document.close()

    @Expect(data.chars.size, 2)
    @Expect(data.chars[0].text, "H")
    @Expect(data.chars[1].text, "i")
    @Expect(data.words.size, 1)
    @Expect(data.words[0].text, "Hi")
    @Expect(data.words[0].fontname, "Helvetica")
    @Assert(near(data.chars[0].x0, 72.0, 0.01))
    // pdfminer's box: baseline + descent*size .. + size (Helvetica descent -0.207).
    @Assert(near(data.chars[0].y0, 700.0 - 0.207 * 12.0, 0.05))
    @Assert(near(data.chars[0].y1, data.chars[0].y0 + 12.0, 0.001))

    @Expect(data.rects.size, 1)
    @Assert(near(data.rects[0].x0, 50.0, 0.001))
    @Assert(near(data.rects[0].y0, 50.0, 0.001))
    @Assert(near(data.rects[0].x1, 150.0, 0.001))
    @Assert(near(data.rects[0].y1, 90.0, 0.001))
    @Assert(data.rects[0].fill)
    @Assert(!data.rects[0].stroke)

    @Expect(data.lines.size, 1)
    @Assert(near(data.lines[0].x0, 10.0, 0.001))
    @Assert(near(data.lines[0].x1, 110.0, 0.001))
    @Assert(near(data.lines[0].y0, 10.0, 0.001))
    @Assert(near(data.lines[0].width, 2.0, 0.001))
    @Expect(describeColor(data.lines[0].color), "Rgb(1.000,0.000,0.000)")

    @Expect(data.curves.size, 1)
    @Expect(data.curves[0].points.size, 4)
    @Assert(near(data.curves[0].x0, 20.0, 0.001))
    @Assert(near(data.curves[0].y0, 20.0, 0.001))
    @Assert(near(data.curves[0].x1, 50.0, 0.001))
    @Assert(near(data.curves[0].y1, 40.0, 0.001))
    @Expect(data.tables.size, 0)
}

@Test
func extractPageIgnoresUnknownOperators(): Unit {
    let content = "1 2 zzz 3 4 qq Q /S1 gs sh BT /F1 10 Tf 100 100 Td (ok) Tj ET"
    let path = contentTempPath("unknown")
    writeTestPdf(path, content)
    let document = PdfDocument.open(path, None)
    removeIfExists(path)
    let data = extractPage(document, document.page(1))
    document.close()
    @Expect(data.chars.size, 2)
    @Expect(data.words.size, 1)
    @Expect(data.words[0].text, "ok")
}

@Test
func extractPageReportsUnterminatedString(): Unit {
    let path = contentTempPath("broken")
    writeTestPdf(path, "BT /F1 12 Tf 72 700 Td (unclosed Tj ET")
    let document = PdfDocument.open(path, None)
    removeIfExists(path)
    var failed = false
    try {
        let data = extractPage(document, document.page(1))
        @Expect(data.chars.size, 0)
    } catch (e: PdfError) {
        failed = true
    }
    document.close()
    @Assert(failed)
}

/**
 * A page box that does not start at (0, 0) must not displace anything: every
 * coordinate is reported relative to the box origin, exactly like pdfplumber.
 *
 * MediaBox `[0 100 612 892]`, text on baseline 620 at x=72: the glyph box becomes
 * 517.516..529.516 (620 - 2.484 descent - 100) and the rect at (50, 150) keeps
 * its size but moves to y0 = 50.
 */
@Test
func extractPageReportsCoordinatesRelativeToBoxOrigin(): Unit {
    let content = "BT /F1 12 Tf 72 620 Td (mb) Tj ET\n50 150 100 40 re f\n"
    let path = contentTempPath("mediabox")
    writeTestPdf(path, content, mediaBox: "[0 100 612 892]")
    let document = PdfDocument.open(path, None)
    removeIfExists(path)
    let page = document.page(1)
    let data = extractPage(document, page)
    document.close()
    // The reported page size is the box extent, independent of its origin.
    @Assert(near(data.width, 612.0, 0.001))
    @Assert(near(data.height, 792.0, 0.001))
    @Expect(data.chars.size, 2)
    @Assert(near(data.chars[0].x0, 72.0, 0.01))
    @Assert(near(data.chars[0].y0, 620.0 - 0.207 * 12.0 - 100.0, 0.05))
    @Assert(near(data.chars[0].y1, data.chars[0].y0 + 12.0, 0.001))
    @Expect(data.words.size, 1)
    @Expect(data.words[0].text, "mb")
    @Assert(near(data.words[0].y0, data.chars[0].y0, 0.001))
    @Assert(near(data.words[0].y1, data.chars[1].y1, 0.001))
    @Expect(data.rects.size, 1)
    @Assert(near(data.rects[0].y0, 50.0, 0.001))
    @Assert(near(data.rects[0].y1, 90.0, 0.001))
    @Assert(near(data.rects[0].x0, 50.0, 0.001))
    @Assert(near(data.rects[0].x1, 150.0, 0.001))
}

// ---------------------------------------------------------------------------
// Helpers

/**
 * A PDF path unique to this test run.
 *
 * The fixtures these tests write used to be fixed `/tmp/cangjie-content-test-*.pdf`
 * names, so two concurrent `cjpm test` runs (or a leftover file from an earlier
 * run) could read each other's bytes. A random 32-bit token plus the sub-second
 * nanoseconds makes the name unique per call; each test deletes its file right
 * after `PdfDocument.open` has read the bytes, so nothing is left behind.
 */
func contentTempPath(label: String): String {
    let token = Random().nextUInt32().toString() + "-" + DateTime.nowUTC().nanosecond.toString()
    return "/tmp/cangjie-content-" + label + "-" + token + ".pdf"
}

func near(actual: Float64, expected: Float64, tolerance: Float64): Bool {
    let difference = if (actual > expected) { actual - expected } else { expected - actual }
    difference <= tolerance
}

func makeChar(text: String, x0: Float64, x1: Float64, y0: Float64, y1: Float64): CharObj {
    CharObj(
        text: text,
        x0: x0,
        y0: y0,
        x1: x1,
        y1: y1,
        fontname: "Helvetica",
        size: y1 - y0,
        color: PdfColor.Gray(0.0),
        page: 1
    )
}

/**
 * Write a single-page PDF whose content stream is `content`.
 *
 * The layout mirrors `tests/pdf_fixtures.py::_write_pdf`: numbered objects, a
 * classic xref table and one Helvetica font resource, so the core parser is
 * exercised through its normal path instead of a stub. `mediaBox` lets a test
 * pin a non-zero page-box origin.
 */
func writeTestPdf(path: String, content: String, mediaBox!: String = "[0 0 612 792]"): Unit {
    let builder = FixtureBuilder()
    let offsets = ArrayList<Int64>()
    builder.add("%PDF-1.4\n")
    offsets.add(builder.size())
    builder.add("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
    offsets.add(builder.size())
    builder.add("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n")
    offsets.add(builder.size())
    builder.add(
        "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox ${mediaBox} /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>\nendobj\n"
    )
    offsets.add(builder.size())
    builder.add("4 0 obj\n<< /Length ${content.size} >>\nstream\n${content}\nendstream\nendobj\n")
    offsets.add(builder.size())
    builder.add("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n")
    let xrefPosition = builder.size()
    builder.add("xref\n0 6\n0000000000 65535 f \n")
    for (offset in offsets) {
        builder.add("${padOffset(offset)} 00000 n \n")
    }
    builder.add("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n${xrefPosition}\n%%EOF\n")
    File.writeTo(path, builder.build().toArray())
}

class FixtureBuilder {
    let chunks = ArrayList<String>()
    var length: Int64 = 0

    func add(value: String): Unit {
        this.chunks.add(value)
        this.length += value.size
    }

    func size(): Int64 {
        this.length
    }

    func build(): String {
        let out = StringBuilder()
        for (chunk in this.chunks) {
            out.append(chunk)
        }
        out.toString()
    }
}

func padOffset(value: Int64): String {
    var text = value.toString()
    while (text.size < 10) {
        text = "0" + text
    }
    text
}
