package pdf4cj.test

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.encoding.base64.*
import pdf4cj.*

/**
 * Corpus-to-case coverage for every PDF committed under `tests/fixtures/`.
 *
 * The per-layer tests (`content_test.cj`, `table_test.cj`, `image_test.cj`)
 * mostly build their inputs in memory, which keeps them fast but means a corpus
 * file could rot unnoticed. Each case here reads one fixture from disk and
 * asserts a fact only that file can prove - page counts, extracted words,
 * table cells, image payload formats, damaged-file error messages - so a
 * regenerated or accidentally replaced fixture fails a test instead of silently
 * changing behaviour.
 *
 * The expectations are the library's own observable results, not external
 * golden files: they were recorded from these exact bytes and are phrased with
 * explicit tolerances where the value comes from font metrics or float math.
 * Every failure message names the fixture and the field, because "expected 3,
 * got 2" is useless when fifteen files are under test.
 */

// ---------------------------------------------------------------------------
// Fixture names

let FIXTURE_TEXT = "tests/fixtures/text.pdf"
let FIXTURE_MULTIPAGE = "tests/fixtures/multipage.pdf"
let FIXTURE_TABLE = "tests/fixtures/table.pdf"
let FIXTURE_QUOTED_TABLE = "tests/fixtures/quoted-table.pdf"
let FIXTURE_STYLED = "tests/fixtures/styled.pdf"
let FIXTURE_IMAGE = "tests/fixtures/image.pdf"
let FIXTURE_JPEG = "tests/fixtures/jpeg.pdf"
let FIXTURE_BLANK = "tests/fixtures/blank.pdf"
let FIXTURE_MEDIABOX = "tests/fixtures/mediabox.pdf"
let FIXTURE_XREF_STREAM = "tests/fixtures/xref-stream.pdf"
let FIXTURE_XREF_STREAM_FLATE = "tests/fixtures/xref-stream-flate.pdf"
let FIXTURE_ENCRYPTED = "tests/fixtures/encrypted.pdf"
let FIXTURE_CORRUPT_STREAM = "tests/fixtures/corrupt-stream.pdf"
let FIXTURE_GARBAGE = "tests/fixtures/garbage.pdf"
let FIXTURE_ZERO = "tests/fixtures/zero.pdf"

// ---------------------------------------------------------------------------
// Assertions that carry the fixture name and the field into the failure

/** Fail with a message that names both the fixture and the field under test. */
func fixturesFail(name: String, field: String, detail: String): Unit {
    @Fail("${name}: ${field}: ${detail}")
}

func fixturesCheck(name: String, field: String, condition: Bool, detail: String): Unit {
    if (!condition) {
        fixturesFail(name, field, detail)
    }
}

func fixturesCheckInt(name: String, field: String, actual: Int64, expected: Int64): Unit {
    fixturesCheck(name, field, actual == expected, "expected ${expected}, got ${actual}")
}

func fixturesCheckText(name: String, field: String, actual: String, expected: String): Unit {
    fixturesCheck(name, field, actual == expected, "expected '${expected}', got '${actual}'")
}

func fixturesCheckNear(
    name: String,
    field: String,
    actual: Float64,
    expected: Float64,
    tolerance: Float64
): Unit {
    fixturesCheck(
        name,
        field,
        fixturesWithin(actual, expected, tolerance),
        "expected ${expected} +/- ${tolerance}, got ${actual}"
    )
}

func fixturesCheckContains(name: String, field: String, actual: String, fragment: String): Unit {
    fixturesCheck(
        name,
        field,
        actual.indexOf(fragment).isSome(),
        "expected '${fragment}' in '${actual}'"
    )
}

func fixturesWithin(actual: Float64, expected: Float64, tolerance: Float64): Bool {
    let difference = actual - expected
    let magnitude = if (difference < 0.0) { 0.0 - difference } else { difference }
    magnitude <= tolerance
}

/** Whether `color` is exactly (within 0.001) the given RGB triple. */
func fixturesIsRgb(color: PdfColor, red: Float64, green: Float64, blue: Float64): Bool {
    match (color) {
        case PdfColor.Rgb(r, g, b) =>
            fixturesWithin(r, red, 0.001) && fixturesWithin(g, green, 0.001) &&
                fixturesWithin(b, blue, 0.001)
        case _ => false
    }
}

/** Join the texts of `words` with single spaces, for readable expectations. */
func fixturesWordLine(words: ArrayList<WordObj>): String {
    let texts = ArrayList<String>()
    for (word in words) {
        texts.add(word.text)
    }
    let builder = StringBuilder()
    for (index in 0..texts.size) {
        if (index > 0) {
            builder.append(" ")
        }
        builder.append(texts[index])
    }
    builder.toString()
}

/** The `error` of a payload, or the empty string when it succeeded. */
func fixturesPayloadError(payload: ImagePayload): String {
    match (payload.error) {
        case Some(message) => message
        case None => ""
    }
}

/** Base64-decoded payload bytes, empty when the payload carries none. */
func fixturesPayloadBytes(payload: ImagePayload): Array<UInt8> {
    match (fromBase64String(payload.base64)) {
        case Some(bytes) => bytes
        case None => Array<UInt8>()
    }
}

/**
 * The `PdfError` message `PdfDocument.open` raises for the fixture at `path`,
 * failing the case when the file unexpectedly opens.
 */
func fixturesOpenErrorMessage(path: String): String {
    var message = ""
    var rejected = false
    try {
        let document = PdfDocument.open(path, None)
        document.close()
    } catch (error: PdfError) {
        rejected = true
        message = error.message
    } catch (error: Exception) {
        fixturesFail(path, "open", "expected PdfError, got ${error.message}")
    }
    if (!rejected) {
        fixturesFail(path, "open", "expected PdfDocument.open to reject '${path}'")
    }
    message
}

// ---------------------------------------------------------------------------
// Text fixtures

/** `text.pdf`: the smallest happy path, summarised end to end. */
@Test
class TextCorpusTests {
    @TestCase
    func textPdfYieldsOnePageOneWordAndNineChars(): Unit {
        let name = FIXTURE_TEXT
        let document = PdfDocument.open(name, None)
        try {
            fixturesCheckInt(name, "pageCount", document.pageCount, 1)
            let metadata = document.metadata()
            fixturesCheckInt(name, "metadata.pages", metadata.pages, 1)
            fixturesCheckText(name, "metadata.version", metadata.version, "1.3")
            fixturesCheckNear(name, "metadata.pageW", metadata.pageW, 612.0, 0.01)
            fixturesCheckNear(name, "metadata.pageH", metadata.pageH, 792.0, 0.01)
            fixturesCheckInt(name, "metadata.fonts.size", Int64(metadata.fonts.size), 1)
            if (metadata.fonts.size != 1) {
                return
            }
            fixturesCheckText(name, "metadata.fonts[0]", metadata.fonts[0], "Helvetica")

            let data = extractPage(document, document.page(1))
            fixturesCheckInt(name, "chars.size", Int64(data.chars.size), 9)
            fixturesCheckInt(name, "words.size", Int64(data.words.size), 1)
            if (data.words.size != 1) {
                return
            }
            fixturesCheckText(name, "words[0].text", data.words[0].text, "alphaword")
            fixturesCheckText(name, "words[0].fontname", data.words[0].fontname, "Helvetica")
            fixturesCheckNear(name, "words[0].size", data.words[0].size, 12.0, 0.01)
            var allHelvetica = true
            for (char in data.chars) {
                if (char.fontname != "Helvetica") {
                    allHelvetica = false
                }
            }
            fixturesCheck(name, "chars.fontname", allHelvetica, "every glyph must use Helvetica")
        } finally {
            document.close()
        }
    }

    /** `multipage.pdf`: three pages, each with its own "page N content" line. */
    @TestCase
    func multipagePdfKeepsPageOrder(): Unit {
        let name = FIXTURE_MULTIPAGE
        let document = PdfDocument.open(name, None)
        try {
            fixturesCheckInt(name, "pageCount", document.pageCount, 3)
            fixturesCheckInt(name, "metadata.pages", document.metadata().pages, 3)
            for (number in 1..=3) {
                let page = document.page(number)
                fixturesCheckInt(name, "page(${number}).number", page.number, number)
                let data = extractPage(document, page)
                fixturesCheckText(
                    name,
                    "page ${number} words",
                    fixturesWordLine(data.words),
                    "page ${number} content"
                )
                fixturesCheckInt(name, "page ${number} chars.size", Int64(data.chars.size), 14)
            }
        } finally {
            document.close()
        }
    }

    /** `blank.pdf`: a legal page whose content stream is empty. */
    @TestCase
    func blankPdfHasNoObjectsAtAll(): Unit {
        let name = FIXTURE_BLANK
        let document = PdfDocument.open(name, None)
        try {
            fixturesCheckInt(name, "pageCount", document.pageCount, 1)
            let page = document.page(1)
            fixturesCheckInt(name, "page(1).contents.size", Int64(page.contents.size), 0)
            let data = extractPage(document, page)
            fixturesCheckInt(name, "chars.size", Int64(data.chars.size), 0)
            fixturesCheckInt(name, "words.size", Int64(data.words.size), 0)
            fixturesCheckInt(name, "rects.size", Int64(data.rects.size), 0)
            fixturesCheckInt(name, "lines.size", Int64(data.lines.size), 0)
            fixturesCheckInt(name, "images.size", Int64(data.images.size), 0)
        } finally {
            document.close()
        }
    }

    /** `zero.pdf`: an empty page tree is a document, not an error. */
    @TestCase
    func zeroPdfIsAnOpenableEmptyDocument(): Unit {
        let name = FIXTURE_ZERO
        let document = PdfDocument.open(name, None)
        try {
            fixturesCheckInt(name, "pageCount", document.pageCount, 0)
            let metadata = document.metadata()
            fixturesCheckInt(name, "metadata.pages", metadata.pages, 0)
            fixturesCheckText(name, "metadata.version", metadata.version, "1.4")
            fixturesCheckInt(name, "metadata.fonts.size", Int64(metadata.fonts.size), 0)
            fixturesCheckNear(name, "metadata.pageW", metadata.pageW, 0.0, 0.01)
            fixturesCheckNear(name, "metadata.pageH", metadata.pageH, 0.0, 0.01)
        } finally {
            document.close()
        }
    }
}

// ---------------------------------------------------------------------------
// Table fixtures

/** `table.pdf` and `quoted-table.pdf`: the ruled-grid detector on real bytes. */
@Test
class TableCorpusTests {
    @TestCase
    func tablePdfDetectsRuledGridAndEmptyCell(): Unit {
        let name = FIXTURE_TABLE
        let document = PdfDocument.open(name, None)
        try {
            let page = document.page(1)
            let data = extractPage(document, page)
            // The fixture draws rect(50, 650, 300, 80) plus two inner rules.
            fixturesCheckInt(name, "rects.size", Int64(data.rects.size), 1)
            fixturesCheckInt(name, "lines.size", Int64(data.lines.size), 2)

            let tables = extractTables(page, data)
            fixturesCheckInt(name, "tables.size", Int64(tables.size), 1)
            if (tables.size != 1) {
                return
            }
            let table = tables[0]
            fixturesCheckInt(name, "tables[0].rows", table.rows, 2)
            fixturesCheckInt(name, "tables[0].cols", table.cols, 2)
            fixturesCheckInt(name, "tables[0].cells.size", Int64(table.cells.size), 2)
            fixturesCheckInt(name, "tables[0].cells[0].size", Int64(table.cells[0].size), 2)
            fixturesCheckText(name, "cells[0][0]", table.cells[0][0], "Header A")
            fixturesCheckText(name, "cells[0][1]", table.cells[0][1], "Header B")
            fixturesCheckText(name, "cells[1][0]", table.cells[1][0], "")
            fixturesCheckText(name, "cells[1][1]", table.cells[1][1], "Row B1")
            // TableObj uses top-based y, so the 650..730 PDF rect becomes 62..142.
            fixturesCheckNear(name, "tables[0].x0", table.x0, 50.0, 1.0)
            fixturesCheckNear(name, "tables[0].y0", table.y0, 62.0, 1.0)
            fixturesCheckNear(name, "tables[0].x1", table.x1, 350.0, 1.0)
            fixturesCheckNear(name, "tables[0].y1", table.y1, 142.0, 1.0)
        } finally {
            document.close()
        }
    }

    /** The top-left cell holds `a,"b` + newline + `c`, the CSV worst case. */
    @TestCase
    func quotedTablePdfKeepsQuoteAndNewlineInsideTheCell(): Unit {
        let name = FIXTURE_QUOTED_TABLE
        let document = PdfDocument.open(name, None)
        try {
            let page = document.page(1)
            let data = extractPage(document, page)
            let tables = extractTables(page, data)
            fixturesCheckInt(name, "tables.size", Int64(tables.size), 1)
            if (tables.size != 1) {
                return
            }
            let table = tables[0]
            fixturesCheckInt(name, "tables[0].rows", table.rows, 2)
            fixturesCheckInt(name, "tables[0].cols", table.cols, 2)
            let cell = table.cells[0][0]
            fixturesCheckContains(name, "cells[0][0]", cell, "a,\"b")
            fixturesCheckContains(name, "cells[0][0]", cell, "c")
            fixturesCheckContains(name, "cells[0][0]", cell, "\n")
            fixturesCheckText(name, "cells[0][0]", cell, "a,\"b\nc")
            fixturesCheckText(name, "cells[0][1]", table.cells[0][1], "plain")
        } finally {
            document.close()
        }
    }
}

// ---------------------------------------------------------------------------
// Font and colour fixture

/** `styled.pdf`: three pages, two fonts, stroked red and blue text. */
@Test
class StyleCorpusTests {
    @TestCase
    func styledPdfReportsFontsAndStrokeColours(): Unit {
        let name = FIXTURE_STYLED
        let document = PdfDocument.open(name, None)
        try {
            fixturesCheckInt(name, "pageCount", document.pageCount, 3)
            let metadata = document.metadata()
            fixturesCheck(
                name,
                "metadata.fonts",
                metadata.fonts.contains("Helvetica"),
                "expected Helvetica"
            )
            fixturesCheck(
                name,
                "metadata.fonts",
                metadata.fonts.contains("Courier"),
                "expected Courier"
            )

            let data = extractPage(document, document.page(1))
            fixturesCheckText(name, "page 1 words", fixturesWordLine(data.words), "alpha beta")
            fixturesCheckInt(name, "page 1 chars.size", Int64(data.chars.size), 9)
            var red = 0
            var blue = 0
            for (char in data.chars) {
                if (fixturesIsRgb(char.color, 1.0, 0.0, 0.0)) {
                    red += 1
                }
                if (fixturesIsRgb(char.color, 0.0, 0.0, 1.0)) {
                    blue += 1
                }
            }
            // "alpha" is red at Helvetica 10, "beta" blue at Helvetica 14.
            fixturesCheckInt(name, "page 1 red glyphs", Int64(red), 5)
            fixturesCheckInt(name, "page 1 blue glyphs", Int64(blue), 4)

            // Courier only appears on page 3, so the per-page split must hold.
            let courierPage = extractPage(document, document.page(3))
            fixturesCheckText(name, "page 3 words", fixturesWordLine(courierPage.words), "delta")
            var courierOnly = true
            for (char in courierPage.chars) {
                if (char.fontname != "Courier") {
                    courierOnly = false
                }
            }
            fixturesCheck(name, "page 3 fontname", courierOnly, "every glyph must use Courier")
        } finally {
            document.close()
        }
    }
}

// ---------------------------------------------------------------------------
// Image fixtures

/** `image.pdf` and `jpeg.pdf`: XObject discovery plus the payload bytes. */
@Test
class ImageCorpusTests {
    /** A PNG drawn by reportlab comes back as a displayable PNG payload. */
    @TestCase
    func imagePdfProducesADisplayablePayload(): Unit {
        let name = FIXTURE_IMAGE
        let document = PdfDocument.open(name, None)
        try {
            let data = extractPage(document, document.page(1))
            fixturesCheckInt(name, "chars.size", Int64(data.chars.size), 0)
            fixturesCheckInt(name, "images.size", Int64(data.images.size), 1)
            if (data.images.size != 1) {
                return
            }
            let image = data.images[0]
            fixturesCheckText(name, "images[0].streamId", image.streamId, "p1_img_0")
            fixturesCheckNear(name, "images[0].x0", image.x0, 50.0, 0.01)
            fixturesCheckNear(name, "images[0].y0", image.y0, 50.0, 0.01)
            fixturesCheckNear(name, "images[0].x1", image.x1, 150.0, 0.01)
            fixturesCheckNear(name, "images[0].y1", image.y1, 150.0, 0.01)
            fixturesCheckNear(name, "images[0].width", image.width, 100.0, 0.01)
            fixturesCheckNear(name, "images[0].height", image.height, 100.0, 0.01)

            let payload = imagePayload(document, image)
            let error = fixturesPayloadError(payload)
            fixturesCheck(name, "payload.error", error.isEmpty(), "unexpected error '${error}'")
            fixturesCheckText(name, "payload.format", payload.format, "png")
            fixturesCheckText(name, "payload.mimeType", payload.mimeType, "image/png")
            fixturesCheck(
                name,
                "payload.byteLength",
                payload.byteLength > 0,
                "expected a non-empty payload"
            )
            fixturesCheck(name, "payload.base64", !payload.base64.isEmpty(), "expected base64 data")
            let bytes = fixturesPayloadBytes(payload)
            fixturesCheckInt(name, "payload bytes", Int64(bytes.size), payload.byteLength)
            match (detectImageFormat(bytes)) {
                case Some(format) =>
                    fixturesCheckText(name, "payload magic", format, "png")
                case None =>
                    fixturesFail(
                        name,
                        "payload magic",
                        "expected PNG signature in the payload bytes"
                    )
            }
        } finally {
            document.close()
        }
    }

    /** A DCTDecode XObject must be passed through as the original JPEG. */
    @TestCase
    func jpegPdfPassesTheJpegThrough(): Unit {
        let name = FIXTURE_JPEG
        let document = PdfDocument.open(name, None)
        try {
            let data = extractPage(document, document.page(1))
            fixturesCheckInt(name, "images.size", Int64(data.images.size), 1)
            if (data.images.size != 1) {
                return
            }
            let image = data.images[0]
            fixturesCheckText(name, "images[0].streamId", image.streamId, "p1_img_0")
            let payload = imagePayload(document, image)
            let error = fixturesPayloadError(payload)
            fixturesCheck(name, "payload.error", error.isEmpty(), "unexpected error '${error}'")
            fixturesCheckText(name, "payload.format", payload.format, "jpeg")
            fixturesCheckText(name, "payload.mimeType", payload.mimeType, "image/jpeg")
            fixturesCheck(
                name,
                "payload.byteLength",
                payload.byteLength > 0,
                "expected a non-empty payload"
            )
            let bytes = fixturesPayloadBytes(payload)
            fixturesCheckInt(name, "payload bytes", Int64(bytes.size), payload.byteLength)
            match (detectImageFormat(bytes)) {
                case Some(format) =>
                    fixturesCheckText(name, "payload magic", format, "jpeg")
                case None =>
                    fixturesFail(name, "payload magic", "expected JPEG SOI in the payload bytes")
            }
        } finally {
            document.close()
        }
    }
}

// ---------------------------------------------------------------------------
// Page geometry fixture

/** `mediabox.pdf`: a non-zero box origin must be subtracted from coordinates. */
@Test
class GeometryCorpusTests {
    @TestCase
    func mediaboxPdfReportsTheSameVisualPositionAsTextPdf(): Unit {
        let name = FIXTURE_MEDIABOX
        let document = PdfDocument.open(name, None)
        try {
            let page = document.page(1)
            let box = page.box()
            fixturesCheckInt(name, "page(1).box().size", Int64(box.size), 4)
            if (box.size != 4) {
                return
            }
            fixturesCheckNear(name, "box[0]", box[0], 0.0, 0.01)
            fixturesCheckNear(name, "box[1]", box[1], 100.0, 0.01)
            fixturesCheckNear(name, "box[2]", box[2], 612.0, 0.01)
            fixturesCheckNear(name, "box[3]", box[3], 892.0, 0.01)
            fixturesCheckNear(name, "page(1).width", page.width, 612.0, 0.01)
            fixturesCheckNear(name, "page(1).height", page.height, 792.0, 0.01)

            let data = extractPage(document, page)
            fixturesCheckText(name, "words", fixturesWordLine(data.words), "mediaboxword")
            fixturesCheckInt(name, "words.size", Int64(data.words.size), 1)
            fixturesCheckInt(name, "chars.size", Int64(data.chars.size), 12)
            if (data.words.size != 1 || data.chars.size < 1) {
                return
            }
            // The text baseline is 620 and the page box starts at y = 100, so
            // extractPage's origin shift reports y0 = 620 - 2.484 - 100 =
            // 517.516 (2.484 is the 12pt Helvetica descent text.pdf shows too).
            fixturesCheckNear(name, "words[0].y0", data.words[0].y0, 517.516, 1.0)
            fixturesCheckNear(name, "words[0].x0", data.words[0].x0, 72.0, 0.01)
            fixturesCheckNear(name, "chars[0].y0", data.chars[0].y0, 517.516, 1.0)
        } finally {
            document.close()
        }
    }
}

// ---------------------------------------------------------------------------
// Cross-reference stream fixtures

/**
 * `xref-stream.pdf` / `xref-stream-flate.pdf`: hand-written files whose
 * catalog, page tree, page and font live inside an `/ObjStm`, reached through a
 * `/Type /XRef` stream. The uncompressed and Flate+predictor variants must be
 * indistinguishable to the reader.
 */
@Test
class CrossReferenceCorpusTests {
    @TestCase
    func uncompressedXrefStreamResolvesObjectsInTheObjectStream(): Unit {
        xrefStreamFixtureStillReads(FIXTURE_XREF_STREAM)
    }

    @TestCase
    func flateXrefStreamWithPredictorResolvesObjectsInTheObjectStream(): Unit {
        xrefStreamFixtureStillReads(FIXTURE_XREF_STREAM_FLATE)
    }
}

/** The shared expectations: both xref-stream variants carry the same page. */
func xrefStreamFixtureStillReads(name: String): Unit {
    let document = PdfDocument.open(name, None)
    try {
        fixturesCheckInt(name, "pageCount", document.pageCount, 1)
        let metadata = document.metadata()
        fixturesCheckText(name, "metadata.version", metadata.version, "1.5")
        fixturesCheckNear(name, "metadata.pageW", metadata.pageW, 300.0, 0.01)
        fixturesCheckNear(name, "metadata.pageH", metadata.pageH, 400.0, 0.01)
        fixturesCheck(
            name,
            "metadata.fonts",
            metadata.fonts.contains("Courier"),
            "expected Courier"
        )

        let page = document.page(1)
        fixturesCheck(name, "page(1).contents", page.contents.size > 0, "expected a content stream")
        let data = extractPage(document, page)
        fixturesCheckInt(name, "words.size", Int64(data.words.size), 1)
        if (data.words.size != 1) {
            return
        }
        fixturesCheckText(name, "words[0].text", data.words[0].text, "objstmword")
        fixturesCheckInt(name, "chars.size", Int64(data.chars.size), 10)
    } finally {
        document.close()
    }
}

// ---------------------------------------------------------------------------
// Damaged-file fixtures

/**
 * Damaged inputs: each one must fail loudly and specifically - either at `open`
 * time or as soon as the damaged part is actually read.
 */
@Test
class DamagedCorpusTests {
    /** `encrypted.pdf` is reported as "wrong password", never as garbage. */
    @TestCase
    func encryptedPdfIsRejectedWithAnActionableMessage(): Unit {
        let name = FIXTURE_ENCRYPTED
        let message = fixturesOpenErrorMessage(name)
        fixturesCheckContains(name, "open message", message, "password required or incorrect")
        fixturesCheckContains(name, "open message", message, "encrypted")
        fixturesCheckContains(name, "open message", message, name)
    }

    /**
     * `garbage.pdf` is plain text: there is no `%PDF-` header and no readable
     * cross-reference table, so the file must be rejected at `open` time -
     * including the path in the message is what makes that actionable.
     */
    @TestCase
    func garbageFileIsRejectedAsNotAPdf(): Unit {
        let name = FIXTURE_GARBAGE
        let message = fixturesOpenErrorMessage(name)
        fixturesCheckContains(name, "open message", message, "cannot open PDF")
        fixturesCheckContains(name, "open message", message, name)
        fixturesCheckContains(name, "open message", message, "cross-reference table")
    }

    /**
     * `corrupt-stream.pdf` keeps a valid object graph but its page content
     * stream was overwritten with `0xFF` bytes, so the decoder - reportlab
     * writes `/ASCII85Decode` first - must reject the data.
     */
    @TestCase
    func corruptContentStreamOpensButFailsToExtract(): Unit {
        let name = FIXTURE_CORRUPT_STREAM
        let document = PdfDocument.open(name, None)
        try {
            fixturesCheckInt(name, "pageCount", document.pageCount, 1)
            fixturesCheckInt(name, "metadata.pages", document.metadata().pages, 1)
            var message = ""
            var rejected = false
            try {
                extractPage(document, document.page(1))
            } catch (error: PdfError) {
                rejected = true
                message = error.message
            } catch (error: Exception) {
                fixturesFail(name, "extractPage(1)", "expected PdfError, got ${error.message}")
            }
            if (!rejected) {
                fixturesFail(name, "extractPage(1)", "expected a PdfError, but the page extracted")
            }
            fixturesCheckContains(name, "extractPage(1) message", message, "Decode")
            fixturesCheckContains(name, "extractPage(1) message", message, "ASCII")
        } finally {
            document.close()
        }
    }
}
