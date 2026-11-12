package pdf_inspector_mcp.tests

import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.random.*
import std.unittest.*
import std.unittest.testmacro.*
import pdf_inspector_mcp.mcp.*
import pdf_inspector_mcp.pdf.*

/**
 * Unit tests for the MCP layer's pure parts: JSON/number/colour formatting
 * (`jsonutil.cj`), path validation and the open-document cache (`session.cj`).
 *
 * The tool bodies themselves need real PDFs and are covered end to end by
 * `cangjie/scripts/e2e-smoke.sh`; what can be pinned down without a fixture is
 * pinned down here, because these are the pieces whose output a client asserts
 * on character by character.
 *
 * The expected strings are the Python server's: `repr(float)` for the font
 * statistics (`10.0`, `1e-07`) and `json.dumps` escaping for the JSON
 * fragments. `colorStatString`'s gray rule is the one documented deviation (the
 * Cangjie colour model has no integer components, see `jsonutil.cj`).
 */

// --- JSON quoting ----------------------------------------------------------

@Test
class JsonUtilTest {
    @TestCase
    func quotesOnlyTheCharactersJsonRequires() {
        @Expect(jsonQuote("plain"), "\"plain\"")
        @Expect(jsonQuote("a\"b"), "\"a\\\"b\"")
        @Expect(jsonQuote("a\\b"), "\"a\\\\b\"")
        @Expect(jsonQuote("a\nb\tc\rd"), "\"a\\nb\\tc\\rd\"")
        @Expect(jsonQuote("bell\u{7}"), "\"bell\\u0007\"")
        // Non-ASCII text is written through, like `ensure_ascii=False`.
        @Expect(jsonQuote("中文 “quoted” — naïve"), "\"中文 “quoted” — naïve\"")
    }

    @TestCase
    func buildsStringAndIntegerArrays() {
        @Expect(jsonStringArray(["a", "b\"c"]), "[\"a\",\"b\\\"c\"]")
        @Expect(jsonStringArray(Array<String>()), "[]")
        @Expect(jsonIntArray(ArrayList<Int64>()), "[]")
        @Expect(jsonIntArray(ArrayList<Int64>([1, 2, 3])), "[1,2,3]")
    }
}

// --- number and colour formatting -----------------------------------------

@Test
class FloatFormattingTest {
    @TestCase
    func printsTheShortestRoundTripWithAPythonTrailingZero() {
        @Expect(formatFloatPy(0.0), "0.0")
        @Expect(formatFloatPy(1.0), "1.0")
        @Expect(formatFloatPy(0.5), "0.5")
        @Expect(formatFloatPy(12.0), "12.0")
        @Expect(formatFloatPy(10.5), "10.5")
        @Expect(formatFloatPy(100.0), "100.0")
        @Expect(formatFloatPy(612.5), "612.5")
        @Expect(formatFloatPy(-3.25), "-3.25")
        @Expect(formatFloatPy(1.0 / 3.0), "0.3333333333333333")
        @Expect(formatFloatPy(0.30000000000000004), "0.30000000000000004")
    }

    @TestCase
    func switchesToScientificNotationWherePythonDoes() {
        @Expect(formatFloatPy(0.0001), "0.0001")
        @Expect(formatFloatPy(0.00001), "1e-05")
        @Expect(formatFloatPy(1.0e-7), "1e-07")
        @Expect(formatFloatPy(2.5e-10), "2.5e-10")
        @Expect(formatFloatPy(1.0e15), "1000000000000000.0")
        @Expect(formatFloatPy(1.0e16), "1e+16")
    }

    @TestCase
    func rendersColorsTheWayStrOfATupleDoes() {
        @Expect(colorStatString(PdfColor.Gray(0.0)), "(0,)")
        @Expect(colorStatString(PdfColor.Gray(0.5)), "(0.5,)")
        @Expect(colorStatString(PdfColor.Rgb(1.0, 0.0, 0.0)), "(1.0, 0.0, 0.0)")
        @Expect(colorStatString(PdfColor.Rgb(0.1, 0.2, 0.3)), "(0.1, 0.2, 0.3)")
        @Expect(colorStatString(PdfColor.Cmyk(0.0, 0.0, 0.0, 1.0)), "(0.0, 0.0, 0.0, 1.0)")
        @Expect(colorStatString(PdfColor.Named("black")), "black")
    }

    @TestCase
    func rendersColorsAsJsonComponents() {
        @Expect(colorJson(PdfColor.Gray(0.0)), "[0.0]")
        @Expect(colorJson(PdfColor.Rgb(1.0, 0.0, 0.5)), "[1.0,0.0,0.5]")
        @Expect(colorJson(PdfColor.Cmyk(0.0, 1.0, 0.0, 1.0)), "[0.0,1.0,0.0,1.0]")
        @Expect(colorJson(PdfColor.Named("red")), "\"red\"")
    }
}

// --- path validation -------------------------------------------------------

@Test
class PathResolutionTest {
    @TestCase
    func rejectsAnEmptyPath() {
        assertToolError({=> resolveDocumentPath("")}, "Invalid PDF path: '' (the path is empty)")
        assertToolError({=> resolveDocumentPath("   ")}, "Invalid PDF path: '   ' (the path is empty)")
    }

    @TestCase
    func reportsAMissingFileWithItsResolvedPath() {
        let missing = "/tmp/pdf-inspector-missing-" + randomToken() + ".pdf"
        let expected = "Invalid PDF path: '" + missing + "' (resolved to '" + missing + "', which does not exist)"
        assertToolError({=> resolveDocumentPath(missing)}, expected)
    }

    @TestCase
    func reportsADirectoryAsNotARegularFile() {
        let directory = "/tmp"
        let expected = "Invalid PDF path: '/tmp' (resolved to '/tmp', which is not a regular file)"
        assertToolError({=> resolveDocumentPath(directory)}, expected)
    }

    @TestCase
    func returnsTheCanonicalPathOfAnExistingFile() {
        let path = tempPath("resolve")
        File.writeTo(path, "x".toArray())
        try {
            @Expect(resolveDocumentPath(path), canonicalize(path).toString())
            // A relative path resolves against the working directory too.
            @Expect(resolveDocumentPath(relativeFromWorkingDirectory(path)), canonicalize(path).toString())
        } finally {
            removeIfExists(path)
        }
    }

    @TestCase
    func expandsALeadingTilde() {
        match (getVariable("HOME")) {
            case Some(home) =>
                if (!home.isEmpty()) {
                    let token = randomToken()
                    let expected = "Invalid PDF path: '~/missing-" + token + "' (resolved to '" +
                        home + "/missing-" + token + "', which does not exist)"
                    assertToolError({=> resolveDocumentPath("~/missing-" + token)}, expected)
                }
            case None => ()
        }
    }
}

// --- document cache --------------------------------------------------------

@Test
class DocumentManagerTest {
    @TestCase
    func reusesAnUnchangedDocumentAndReopensAChangedOne() {
        let path = tempPath("cache")
        writeMinimalPdf(path, "one")
        let manager = DocumentManager(maxDocuments: 4)
        try {
            let (resolved, first) = manager.session(path, None)
            @Expect(resolved, canonicalize(path).toString())
            @Expect(first.pageCount, 1)
            @Expect(first.isClosed(), false)

            // Same revision: the cached document comes back untouched.
            let (_, second) = manager.session(path, None)
            @Expect(second.pageCount, 1)
            @Expect(manager.size, 1)
            @Expect(first.isClosed(), false)

            // New bytes: the stale document is closed and replaced in place.
            writeMinimalPdf(path, "two-longer-content")
            let (_, third) = manager.session(path, None)
            @Expect(third.pageCount, 1)
            @Expect(first.isClosed(), true)
            @Expect(third.isClosed(), false)
            @Expect(manager.size, 1)
        } finally {
            manager.closeAll()
            removeIfExists(path)
        }
    }

    @TestCase
    func keepsAPasswordSpecificSessionPerDocument() {
        let path = tempPath("password")
        writeMinimalPdf(path, "same")
        let manager = DocumentManager(maxDocuments: 4)
        try {
            // The password is part of the cache key, even for a document that does
            // not need one: two passwords are two sessions, and asking again with
            // the first password reuses it instead of opening a third.
            manager.session(path, None)
            manager.session(path, Some("secret"))
            @Expect(manager.size, 2)
            let (_, plain) = manager.session(path, None)
            @Expect(plain.isClosed(), false)
            @Expect(manager.size, 2)
        } finally {
            manager.closeAll()
            removeIfExists(path)
        }
    }

    @TestCase
    func evictsTheLeastRecentlyUsedDocument() {
        let firstPath = tempPath("lru-a")
        let secondPath = tempPath("lru-b")
        writeMinimalPdf(firstPath, "a")
        writeMinimalPdf(secondPath, "b")
        let manager = DocumentManager(maxDocuments: 1)
        try {
            let (_, first) = manager.session(firstPath, None)
            let (_, second) = manager.session(secondPath, None)
            @Expect(manager.size, 1)
            @Expect(first.isClosed(), true)
            @Expect(second.isClosed(), false)
        } finally {
            manager.closeAll()
            removeIfExists(firstPath)
            removeIfExists(secondPath)
        }
    }

    @TestCase
    func closingTheManagerClosesEveryCachedDocument() {
        let path = tempPath("close")
        writeMinimalPdf(path, "x")
        let manager = DocumentManager(maxDocuments: 4)
        try {
            let (_, doc) = manager.session(path, None)
            manager.closeAll()
            @Expect(doc.isClosed(), true)
            @Expect(manager.size, 0)
        } finally {
            removeIfExists(path)
        }
    }

    @TestCase
    func fallsBackToTheDefaultBoundForUnusableLimits() {
        @Expect(DocumentManager(maxDocuments: 0).maxDocuments, DEFAULT_MAX_DOCUMENTS)
        @Expect(DocumentManager(maxDocuments: -3).maxDocuments, DEFAULT_MAX_DOCUMENTS)
        @Expect(DocumentManager(maxDocuments: 3).maxDocuments, 3)
    }

    @TestCase
    func readsTheCacheBoundFromTheEnvironment() {
        let previous = getVariable(MAX_DOCUMENTS_ENV_VAR)
        try {
            checkEnvironmentBound("2", 2)
            checkEnvironmentBound(" 5 ", 5)
            checkEnvironmentBound("0", DEFAULT_MAX_DOCUMENTS)
            checkEnvironmentBound("abc", DEFAULT_MAX_DOCUMENTS)
            removeVariable(MAX_DOCUMENTS_ENV_VAR)
            @Expect(DocumentManager.fromEnvironment().maxDocuments, DEFAULT_MAX_DOCUMENTS)
        } finally {
            match (previous) {
                case Some(value) => setVariable(MAX_DOCUMENTS_ENV_VAR, value)
                case None => ()
            }
        }
    }
}

// --- helpers ---------------------------------------------------------------

func checkEnvironmentBound(raw: String, expected: Int64): Unit {
    setVariable(MAX_DOCUMENTS_ENV_VAR, raw)
    @Expect(DocumentManager.fromEnvironment().maxDocuments, expected)
}

/** Assert that `body` raises a `PdfToolError` whose message is `expected`. */
func assertToolError(body: () -> Unit, expected: String): Unit {
    try {
        body()
        @Fail("expected a PdfToolError: " + expected)
    } catch (error: PdfToolError) {
        @Expect(error.message, expected)
    }
}

func randomToken(): String {
    return Random().nextUInt32().toString()
}

func tempPath(label: String): String {
    return "/tmp/pdf-inspector-cj-test-" + label + "-" + randomToken() + ".pdf"
}

/** The path of `path` relative to the working directory, to test both forms. */
func relativeFromWorkingDirectory(path: String): String {
    let workingDirectory = getWorkingDirectory().toString()
    if (path.startsWith(workingDirectory + "/")) {
        return path[workingDirectory.size + 1..path.size]
    }
    return path
}

/**
 * Write a minimal one-page PDF so the cache tests have something real to open.
 *
 * The object bodies and the cross-reference offsets are computed here (offsets
 * are byte positions, and every object is ASCII) so the document parses exactly
 * like a fixture written by `tests/pdf_fixtures.py`. `text` is the payload of
 * the page's single text run, which is how the tests produce a second revision
 * with different bytes.
 */
func writeMinimalPdf(path: String, text: String): Unit {
    let objects = ArrayList<String>()
    objects.add("<< /Type /Catalog /Pages 2 0 R >>")
    objects.add("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
    objects.add(
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " +
        "/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>"
    )
    let content = "BT /F1 12 Tf 72 700 Td (" + text + ") Tj ET"
    objects.add("<< /Length ${content.size} >>\nstream\n" + content + "\nendstream")
    objects.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")

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
        builder.append(paddedOffset(value) + " 00000 n \n")
    }
    builder.append(
        "trailer\n<< /Size ${number} /Root 1 0 R >>\nstartxref\n${xrefPosition}\n%%EOF\n"
    )
    File.writeTo(path, builder.toString().toArray())
}

func paddedOffset(value: Int64): String {
    let text = "${value}"
    let builder = StringBuilder()
    for (_ in 0..(10 - text.size)) {
        builder.append("0")
    }
    builder.append(text)
    return builder.toString()
}
