package pdf_inspector_mcp.tests

import std.collection.*
import std.fs.*
import std.random.*
import std.unittest.*
import std.unittest.testmacro.*
import pdf_inspector_mcp.pdf.*

/**
 * Document-opening regression tests for damaged-file handling.
 *
 * The surrounding extraction tests use golden fixtures for happy paths. These
 * cases pin down the distinction that matters when a file is broken: a legal
 * empty page tree must still open with zero pages, while a truncated document
 * or a stream whose `/Length` runs past EOF must raise `PdfError` instead of
 * masquerading as an empty document.
 */

@Test
func zeroPageTreeIsALegalDocument(): Unit {
    let document = PdfDocument.open("tests/fixtures/zero.pdf", None)
    try {
        @Expect(document.pageCount, 0)
        let metadata = document.metadata()
        @Expect(metadata.pages, 0)
        @Expect(metadata.pageW, 0.0)
        @Expect(metadata.pageH, 0.0)
        @Expect(metadata.fonts.size, 0)
    } finally {
        document.close()
    }
}

@Test
func truncatedDocumentIsRejected(): Unit {
    let path = documentTempPath("truncated")
    let original = File.readFrom("tests/fixtures/text.pdf")
    let half = original.size / 2
    File.writeTo(path, original[0..half].toArray())
    try {
        let message = documentExpectOpenFailure(path)
        @Assert(!message.isEmpty())
        @Assert(message.indexOf(path).isSome())
    } finally {
        removeIfExists(path)
    }
}

@Test
func readableTextFixtureStillOpensAndReportsItsFont(): Unit {
    let document = PdfDocument.open("tests/fixtures/text.pdf", None)
    try {
        @Expect(document.pageCount, 1)
        let metadata = document.metadata()
        @Expect(metadata.pages, 1)
        @Expect(metadata.version, "1.3")
        @Expect(metadata.pageW, 612.0)
        @Expect(metadata.pageH, 792.0)
        @Expect(metadata.fonts.size, 1)
        @Expect(metadata.fonts[0], "Helvetica")
        @Assert(document.page(1).contents.size > 0)
    } finally {
        document.close()
    }
}

@Test
func pageTreeReferenceCycleIsRejected(): Unit {
    let path = documentTempPath("page-tree-cycle")
    documentWriteCyclicPageTreePdf(path)
    try {
        let message = documentExpectOpenFailure(path)
        @Assert(message.indexOf("page tree").isSome())
        @Assert(message.indexOf("cycle").isSome())
    } finally {
        removeIfExists(path)
    }
}

@Test
func danglingContentsReferenceIsNotAnEmptyPage(): Unit {
    let path = documentTempPath("dangling-contents")
    documentWriteDanglingContentsPdf(path)
    let document = PdfDocument.open(path, None)
    try {
        @Expect(document.pageCount, 1)
        var contentsRead = false
        var contentsError = ""
        try {
            document.page(1).contents
            contentsRead = true
        } catch (error: PdfError) {
            contentsError = error.message
        }
        if (contentsRead) {
            @Fail("expected a dangling /Contents reference to raise PdfError")
        }
        @Assert(contentsError.indexOf("/Contents").isSome())
        @Assert(contentsError.indexOf("missing or unreadable").isSome())
    } finally {
        document.close()
        removeIfExists(path)
    }
}

@Test
func pageWithoutContentsKeyHasEmptyContents(): Unit {
    let path = documentTempPath("no-contents")
    documentWriteNoContentsPdf(path)
    let document = PdfDocument.open(path, None)
    try {
        @Expect(document.pageCount, 1)
        @Expect(document.page(1).contents.size, 0)
    } finally {
        document.close()
        removeIfExists(path)
    }
}

@Test
func wrongButRecoverableLengthStillUsesEndstreamFallback(): Unit {
    let path = documentTempPath("wrong-length")
    documentWriteWrongLengthPdf(path)
    let document = PdfDocument.open(path, None)
    try {
        @Expect(document.pageCount, 1)
        let contents = String.fromUtf8(document.page(1).contents)
        @Assert(contents.indexOf("wronglength").isSome())
    } finally {
        document.close()
        removeIfExists(path)
    }
}

@Test
func streamLengthPastEofIsAParseErrorNotAnEmptyPage(): Unit {
    let path = documentTempPath("bad-length")
    documentWriteBadLengthPdf(path)
    let document = PdfDocument.open(path, None)
    try {
        @Expect(document.pageCount, 1)
        var contentsError = ""
        var contentsRead = false
        try {
            document.page(1).contents
            contentsRead = true
        } catch (error: PdfError) {
            contentsError = error.message
        }
        if (contentsRead) {
            @Fail("expected /Contents with an impossible /Length to raise PdfError")
        }
        @Assert(!contentsError.isEmpty())
        @Assert(contentsError.indexOf("endstream").isSome())
    } finally {
        document.close()
        removeIfExists(path)
    }
}

// ---------------------------------------------------------------------------
// Fixture helpers

func documentTempPath(label: String): String {
    return "/tmp/pdf-inspector-document-" + label + "-" + Random().nextUInt32().toString() + ".pdf"
}

/**
 * A structurally readable one-page PDF whose content stream declares an
 * impossible `/Length` and has no `endstream` marker at all.
 *
 * The catalog/pages/page objects and the cross-reference table are valid, so
 * opening succeeds; only resolving `/Contents` exposes the damage. That is the
 * exact shape the old fallback silently turned into an empty page.
 */
func documentWriteBadLengthPdf(path: String): Unit {
    let objects = ArrayList<String>()
    objects.add("<< /Type /Catalog /Pages 2 0 R >>")
    objects.add("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
    objects.add("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>")
    objects.add("<< /Length 9223372036854775807 >>\nstream\nBT /F1 12 Tf 72 700 Td (broken) Tj ET")
    documentWritePdfObjects(path, objects)
}

/** A catalog whose Pages node lists itself as its only kid. */
func documentWriteCyclicPageTreePdf(path: String): Unit {
    let objects = ArrayList<String>()
    objects.add("<< /Type /Catalog /Pages 2 0 R >>")
    objects.add("<< /Type /Pages /Kids [2 0 R] /Count 1 >>")
    documentWritePdfObjects(path, objects)
}

/** One valid page whose `/Contents` points at an object that does not exist. */
func documentWriteDanglingContentsPdf(path: String): Unit {
    let objects = ArrayList<String>()
    objects.add("<< /Type /Catalog /Pages 2 0 R >>")
    objects.add("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
    objects.add("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 9 0 R >>")
    documentWritePdfObjects(path, objects)
}

/** One valid page with no `/Contents` key at all: legally empty content. */
func documentWriteNoContentsPdf(path: String): Unit {
    let objects = ArrayList<String>()
    objects.add("<< /Type /Catalog /Pages 2 0 R >>")
    objects.add("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
    objects.add("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>")
    documentWritePdfObjects(path, objects)
}

func documentWritePdfObjects(path: String, objects: ArrayList<String>): Unit {
    let builder = StringBuilder()
    builder.append("%PDF-1.4\n")
    let offsets = ArrayList<Int64>()
    var offset: Int64 = 9
    var number: Int64 = 1
    for (body in objects) {
        offsets.add(offset)
        let chunk = "${number} 0 obj\n" + body + "\nendobj\n"
        builder.append(chunk)
        offset += chunk.size
        number += 1
    }
    let xrefPosition = offset
    builder.append("xref\n0 ${number}\n")
    builder.append("0000000000 65535 f \n")
    for (value in offsets) {
        builder.append(documentPaddedOffset(value) + " 00000 n \n")
    }
    builder.append(
        "trailer\n<< /Size ${number} /Root 1 0 R >>\nstartxref\n${xrefPosition}\n%%EOF\n"
    )
    File.writeTo(path, builder.toString().toArray())
}

/**
 * The same structure with a wrong (too large) `/Length`, but the real
 * `endstream` is present: the compatibility fallback must still decode it.
 */
func documentWriteWrongLengthPdf(path: String): Unit {
    let objects = ArrayList<String>()
    objects.add("<< /Type /Catalog /Pages 2 0 R >>")
    objects.add("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
    objects.add("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>")
    objects.add(
        "<< /Length 9999 >>\nstream\nBT /F1 12 Tf 72 700 Td (wronglength) Tj ET\nendstream"
    )
    documentWritePdfObjects(path, objects)
}

func documentPaddedOffset(value: Int64): String {
    let text = "${value}"
    let builder = StringBuilder()
    for (_ in 0..(10 - text.size)) {
        builder.append("0")
    }
    builder.append(text)
    return builder.toString()
}

func documentExpectOpenFailure(path: String): String {
    var message = ""
    var sawPdfError = false
    try {
        let document = PdfDocument.open(path, None)
        document.close()
    } catch (error: PdfError) {
        sawPdfError = true
        message = error.message
    } catch (error: Exception) {
        @Fail("expected PdfError for " + path + ", got " + error.message)
    }
    if (!sawPdfError) {
        @Fail("expected PdfDocument.open to reject " + path)
    }
    message
}
