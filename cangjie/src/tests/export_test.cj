package pdf_inspector_mcp.tests

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.encoding.json.*
import pdf_inspector_mcp.export.*
import pdf4cj.*

/**
 * Unit tests for the export layer (`json.cj`, `csv.cj`, `filename.cj`,
 * `types.cj`).
 *
 * Fixtures mirror `tests/test_export.py` (`make_page()` / `make_table_page()`)
 * so the golden substrings are the same ones the Python suite asserts. Numbers
 * differ from Python in one documented way: an integral float prints without the
 * `.0` (`612.0` -> `612`, `1e-07` -> `1e-7`), which is what the upstream
 * TypeScript exporter produces; assertions below are written against that
 * output.
 */

let FIXED_TIMESTAMP = "2026-01-01T12:00:00.123Z"

func makeMetadata(): PdfMetadata {
    return PdfMetadata(
        pages: 1,
        version: "1.7",
        encrypted: false,
        pageW: 612.0,
        pageH: 792.0,
        title: "Demo",
        author: "A",
        producer: "P",
        fonts: ArrayList<String>(["F1"])
    )
}

func makePage(): PageData {
    let page = PageData(width: 612.0, height: 792.0)
    page.chars.add(
        CharObj(
            text: "a,\"b\nc",
            x0: 1.0,
            y0: 2.0,
            x1: 3.0,
            y1: 4.0,
            fontname: "F1",
            size: 12.0,
            color: PdfColor.Gray(0.0),
            page: 1
        )
    )
    page.chars.add(
        CharObj(
            text: "中文 “quoted” — naïve",
            x0: 72.5,
            y0: 700.25,
            x1: 100.0,
            y1: 712.0,
            fontname: "F2",
            size: 10.5,
            color: PdfColor.Rgb(0.1, 0.2, 0.3),
            page: 1
        )
    )
    page.words.add(
        WordObj(text: "hello", x0: 1.0, y0: 2.0, x1: 9.0, y1: 4.0, fontname: "F1", size: 12.0, page: 1)
    )
    page.rects.add(
        RectObj(
            x0: 0.0,
            y0: 0.0,
            x1: 10.0,
            y1: 10.0,
            fill: true,
            stroke: false,
            color: PdfColor.Rgb(1.0, 0.0, 0.0),
            width: 1.0,
            page: 1
        )
    )
    page.lines.add(
        LineObj(
            x0: 0.0,
            y0: 0.0,
            x1: 10.0,
            y1: 0.0,
            stroke: true,
            color: PdfColor.Rgb(0.0, 1.0, 0.0),
            width: 0.5,
            page: 1
        )
    )
    page.curves.add(
        CurveObj(
            x0: 0.0,
            y0: 0.0,
            x1: 5.0,
            y1: 5.0,
            points: [[0.0, 0.0], [5.0, 5.0]],
            stroke: true,
            page: 1
        )
    )
    page.images.add(
        ImageObj(
            x0: 0.0,
            y0: 0.0,
            x1: 20.0,
            y1: 20.0,
            width: 20.0,
            height: 20.0,
            streamId: "p1_img_0",
            format: "png",
            page: 1
        )
    )
    page.tables.add(
        TableObj(
            x0: 0.0,
            y0: 0.0,
            x1: 50.0,
            y1: 50.0,
            rows: 2,
            cols: 2,
            cells: [["h1", "h2"], ["v1", "v2"]],
            page: 1
        )
    )
    return page
}

func makeTablePage(page: Int64, text: String): PageData {
    let pageData = PageData(width: 612.0, height: 792.0)
    pageData.tables.add(
        TableObj(
            x0: 0.0,
            y0: 0.0,
            x1: 10.0,
            y1: 10.0,
            rows: 1,
            cols: 1,
            cells: [[text]],
            page: page
        )
    )
    return pageData
}

/** One char with an integral size and a gray colour, for the scalar rules. */
func makeScalarPage(): PageData {
    let page = PageData(width: 612.0, height: 792.0)
    page.chars.add(
        CharObj(text: "x", x0: 0.0, y0: 0.0, x1: 1.0, y1: 1.0, fontname: "F1", size: 1.0, color: PdfColor.Gray(0.0), page: 1)
    )
    page.rects.add(
        RectObj(
            x0: 0.0,
            y0: 0.0,
            x1: 1.0,
            y1: 1.0,
            fill: true,
            stroke: true,
            color: PdfColor.Rgb(1.0, 0.5, 0.0),
            width: 0.0,
            page: 1
        )
    )
    return page
}

func pagesOf(page: PageData): ArrayList<PageData> {
    let pages = ArrayList<PageData>()
    pages.add(page)
    return pages
}

func pageJson(types: Option<Array<String>>): String {
    return pagesToJson(pagesOf(makePage()), makeMetadata(), types, Some(FIXED_TIMESTAMP))
}

func jsonOf(page: PageData, types: Option<Array<String>>): String {
    return pagesToJson(pagesOf(page), makeMetadata(), types, Some(FIXED_TIMESTAMP))
}

func csvOf(page: PageData, types: Option<Array<String>>): String {
    return pagesToCsv(pagesOf(page), types)
}

/** First offset of `needle`, failing the case when it is absent. */
func at(text: String, needle: String): Int64 {
    return text.indexOf(needle).getOrThrow()
}

func joinedTypes(types: Array<String>): String {
    let builder = StringBuilder()
    var first = true
    for (typeName in types) {
        if (!first) {
            builder.append(",")
        }
        first = false
        builder.append(typeName)
    }
    return builder.toString()
}

// --- JSON ------------------------------------------------------------------

@Test
class ExportJsonTest {
    @TestCase
    func producesParseableJsonWithMetadataPageCountAndPages() {
        let text = pageJson(None)
        let parsed = JsonValue.fromStr(text).asObject()
        @Expect(parsed["pageCount"].asInt().getValue(), 1)
        let metadata = parsed["metadata"].asObject()
        @Expect(metadata["pages"].asInt().getValue(), 1)
        @Expect(metadata["version"].asString().getValue(), "1.7")
        @Expect(metadata["encrypted"].asBool().getValue(), false)
        @Expect(metadata["page_w"].asInt().getValue(), 612)
        @Expect(metadata["page_h"].asInt().getValue(), 792)
        @Expect(metadata["title"].asString().getValue(), "Demo")
        @Expect(metadata["author"].asString().getValue(), "A")
        @Expect(metadata["producer"].asString().getValue(), "P")
        @Expect(metadata["fonts"].asArray().size(), 1)
        @Expect(metadata["fonts"].asArray().get(0).getOrThrow().asString().getValue(), "F1")
        @Expect(parsed["exportedAt"].asString().getValue(), FIXED_TIMESTAMP)
        let pages = parsed["pages"].asArray()
        @Expect(pages.size(), 1)
        let page = pages.get(0).getOrThrow().asObject()
        @Expect(page["width"].asInt().getValue(), 612)
        @Expect(page["height"].asInt().getValue(), 792)
        @Expect(page["chars"].asArray().size(), 2)
        @Expect(page["chars"].asArray().get(0).getOrThrow().asObject()["text"].asString().getValue(), "a,\"b\nc")
        @Expect(page["chars"].asArray().get(1).getOrThrow().asObject()["x0"].asFloat().getValue(), 72.5)
        @Expect(page["words"].asArray().size(), 1)
        @Expect(page["words"].asArray().get(0).getOrThrow().asObject()["text"].asString().getValue(), "hello")
        @Expect(page["tables"].asArray().get(0).getOrThrow().asObject()["cells"].asArray().size(), 2)
    }

    @TestCase
    func reportsEveryTypeInCanonicalOrderByDefault() {
        let implicit = JsonValue.fromStr(pageJson(None)).asObject()["objectTypes"].asArray()
        let explicitAll = JsonValue.fromStr(pageJson(Some(EXPORT_OBJECT_TYPES))).asObject()["objectTypes"].asArray()
        @Expect(implicit.size(), 7)
        @Expect(joinedTypes(EXPORT_OBJECT_TYPES), "char,word,rect,line,curve,image,table")
        let expected = ["char", "word", "rect", "line", "curve", "image", "table"]
        var index = 0
        for (typeName in expected) {
            @Expect(implicit.get(index).getOrThrow().asString().getValue(), typeName)
            @Expect(explicitAll.get(index).getOrThrow().asString().getValue(), typeName)
            index += 1
        }
    }

    @TestCase
    func keepsOnlySelectedArraysAndReportsCanonicalOrder() {
        let text = pageJson(Some(["table", "word"]))
        let parsed = JsonValue.fromStr(text).asObject()
        let objectTypes = parsed["objectTypes"].asArray()
        @Expect(objectTypes.size(), 2)
        @Expect(objectTypes.get(0).getOrThrow().asString().getValue(), "word")
        @Expect(objectTypes.get(1).getOrThrow().asString().getValue(), "table")
        let page = parsed["pages"].asArray().get(0).getOrThrow().asObject()
        @Expect(page["words"].asArray().size(), 1)
        @Expect(page["words"].asArray().get(0).getOrThrow().asObject()["text"].asString().getValue(), "hello")
        @Expect(page["tables"].asArray().size(), 1)
        @Expect(
            page["tables"].asArray().get(0).getOrThrow().asObject()["cells"].asArray().get(1).getOrThrow().asArray().get(1).getOrThrow().asString().getValue(),
            "v2"
        )
        @Expect(page["chars"].asArray().size(), 0)
        @Expect(page["rects"].asArray().size(), 0)
        @Expect(page["lines"].asArray().size(), 0)
        @Expect(page["curves"].asArray().size(), 0)
        @Expect(page["images"].asArray().size(), 0)
        @Expect(page["height"].asInt().getValue(), 792)
    }

    @TestCase
    func treatsExplicitEmptySelectionAsNoObjectData() {
        let parsed = JsonValue.fromStr(pageJson(Some(Array<String>()))).asObject()
        @Expect(parsed["objectTypes"].asArray().size(), 0)
        @Expect(parsed["pageCount"].asInt().getValue(), 1)
        let page = parsed["pages"].asArray().get(0).getOrThrow().asObject()
        @Expect(page["width"].asInt().getValue(), 612)
        @Expect(page["chars"].asArray().size(), 0)
        @Expect(page["words"].asArray().size(), 0)
        @Expect(page["rects"].asArray().size(), 0)
        @Expect(page["lines"].asArray().size(), 0)
        @Expect(page["curves"].asArray().size(), 0)
        @Expect(page["images"].asArray().size(), 0)
        @Expect(page["tables"].asArray().size(), 0)
    }

    @TestCase
    func ignoresUnknownTypesAndDeduplicates() {
        let parsed = JsonValue.fromStr(pageJson(Some(["char", "bogus", "char"]))).asObject()
        @Expect(parsed["objectTypes"].asArray().size(), 1)
        @Expect(parsed["objectTypes"].asArray().get(0).getOrThrow().asString().getValue(), "char")
        let page = parsed["pages"].asArray().get(0).getOrThrow().asObject()
        @Expect(page["chars"].asArray().size(), 2)
        @Expect(page["words"].asArray().size(), 0)
    }

    @TestCase
    func keepsThePythonKeyOrder() {
        let text = pageJson(Some(["char", "word", "rect", "line", "curve", "image", "table"]))
        @Assert(at(text, "\n  \"metadata\": {") < at(text, "\n  \"exportedAt\""))
        @Assert(at(text, "\n  \"exportedAt\"") < at(text, "\n  \"pageCount\":"))
        @Assert(at(text, "\n  \"pageCount\":") < at(text, "\n  \"objectTypes\": ["))
        @Assert(at(text, "\n  \"objectTypes\": [") < at(text, "\n  \"pages\": ["))
        @Assert(at(text, "\n  \"pages\": [") < at(text, "      \"width\":"))
        @Assert(at(text, "\"width\"") < at(text, "\"height\""))
        @Assert(at(text, "\"height\"") < at(text, "\"chars\""))
        @Assert(at(text, "\"chars\"") < at(text, "\"words\""))
        @Assert(at(text, "\"words\"") < at(text, "\"rects\""))
        @Assert(at(text, "\"rects\"") < at(text, "\"lines\""))
        @Assert(at(text, "\"lines\"") < at(text, "\"curves\""))
        @Assert(at(text, "\"curves\"") < at(text, "\"images\""))
        @Assert(at(text, "\"images\"") < at(text, "\"tables\""))
        // Object keys: `type` first, `page` last.
        @Assert(at(text, "\"type\": \"char\"") < at(text, "\"text\""))
        @Assert(at(text, "\"text\"") < at(text, "\"fontname\""))
        @Expect(
            text.contains(
                "\"type\": \"word\",\n" +
                "          \"x0\": 1,\n" +
                "          \"y0\": 2,\n" +
                "          \"x1\": 9,\n" +
                "          \"y1\": 4,\n" +
                "          \"text\": \"hello\",\n" +
                "          \"fontname\": \"F1\",\n" +
                "          \"size\": 12,\n" +
                "          \"page\": 1"
            ),
            true
        )
    }

    @TestCase
    func rendersIndentedJsonLikeJsonDumps() {
        let text = jsonOf(PageData(width: 612.0, height: 792.0), None)
        @Expect(text.startsWith("{\n  \"metadata\": {\n    \"pages\": 1,"), true)
        // Empty arrays and objects stay on one line.
        @Expect(text.contains("\"chars\": [],"), true)
        @Expect(text.contains("      \"width\": 612,\n      \"height\": 792,\n"), true)
        @Assert(text.endsWith("\n  ]\n}"))
    }

    @TestCase
    func doesNotEscapeNonAsciiText() {
        let text = pageJson(None)
        @Expect(text.contains("中文 “quoted” — naïve"), true)
        @Expect(text.contains("\\u"), false)
    }

    @TestCase
    func escapesQuotesAndControlCharacters() {
        let page = PageData(width: 1.0, height: 1.0)
        page.chars.add(CharObj(text: "quote \" tab \t back \\ end", page: 1))
        let text = jsonOf(page, None)
        @Expect(text.contains("\"text\": \"quote \\\" tab \\t back \\\\ end\""), true)
        // The escaped JSON must parse back to the original text.
        let parsed = JsonValue.fromStr(text).asObject()
        @Expect(
            parsed["pages"].asArray().get(0).getOrThrow().asObject()["chars"].asArray().get(0).getOrThrow().asObject()["text"].asString().getValue(),
            "quote \" tab \t back \\ end"
        )
    }

    @TestCase
    func rendersColoursAsArraysOrNames() {
        let page = PageData(width: 1.0, height: 1.0)
        page.chars.add(CharObj(text: "g", size: 0.5, color: PdfColor.Gray(0.5), page: 1))
        page.chars.add(CharObj(text: "c", size: 0.5, color: PdfColor.Cmyk(0.1, 0.2, 0.3, 0.4), page: 1))
        page.chars.add(CharObj(text: "n", size: 0.5, color: PdfColor.Named("#ff0000"), page: 1))
        let text = jsonOf(page, Some(["char"]))
        @Expect(text.contains("\"color\": [\n            0.5\n          ]"), true)
        @Expect(text.contains("\"color\": [\n            0.1,\n            0.2,\n            0.3,\n            0.4\n          ]"), true)
        @Expect(text.contains("\"color\": \"#ff0000\""), true)
    }

    @TestCase
    func defaultsExportedAtToIsoUtcWithMilliseconds() {
        let text = pagesToJson(pagesOf(makePage()), makeMetadata(), None, None)
        let parsed = JsonValue.fromStr(text).asObject()
        let exportedAt = parsed["exportedAt"].asString().getValue()
        // yyyy-MM-ddTHH:mm:ss.SSSZ
        @Expect(exportedAt.size, 24)
        @Expect(exportedAt[4], b'-')
        @Expect(exportedAt[7], b'-')
        @Expect(exportedAt[10], b'T')
        @Expect(exportedAt[13], b':')
        @Expect(exportedAt[16], b':')
        @Expect(exportedAt[19], b'.')
        @Expect(exportedAt[23], b'Z')
    }

    @TestCase
    func countsEveryExportedPage() {
        let pages = ArrayList<PageData>()
        pages.add(makePage())
        pages.add(makePage())
        let parsed = JsonValue.fromStr(pagesToJson(pages, makeMetadata(), None, Some(FIXED_TIMESTAMP))).asObject()
        @Expect(parsed["pageCount"].asInt().getValue(), 2)
        @Expect(parsed["pages"].asArray().size(), 2)
    }

    @TestCase
    func writesIntegralFloatsWithoutTrailingZero() {
        let text = jsonOf(makePage(), Some(["char"]))
        // 612.0 -> 612 and 12.0 -> 12; fractional values keep their digits.
        @Expect(text.contains("\"size\": 12,"), true)
        @Expect(text.contains("\"x0\": 72.5,"), true)
        @Expect(text.contains("612.0"), false)
    }
}

// --- narrower MCP payloads -------------------------------------------------

@Test
class ExportJsonPayloadTest {
    @TestCase
    func metadataToJsonKeepsItsKeyOrderAndNumberFormat() {
        let text = metadataToJson(makeMetadata())
        let parsed = JsonValue.fromStr(text).asObject()
        @Expect(parsed["pages"].asInt().getValue(), 1)
        @Expect(parsed["version"].asString().getValue(), "1.7")
        @Expect(parsed["encrypted"].asBool().getValue(), false)
        @Expect(parsed["title"].asString().getValue(), "Demo")
        @Expect(parsed["fonts"].asArray().size(), 1)
        // `stdx.encoding.json.JsonFloat` would print 612.000000 here.
        @Expect(text.contains("\"page_w\": 612,"), true)
        @Expect(text.contains("\"page_h\": 792,"), true)
        @Expect(text.contains("612.000000"), false)
        @Expect(text.startsWith("{\n  \"pages\": 1,\n  \"version\": \"1.7\","), true)
        @Assert(at(text, "\"pages\"") < at(text, "\"version\""))
        @Assert(at(text, "\"version\"") < at(text, "\"encrypted\""))
        @Assert(at(text, "\"encrypted\"") < at(text, "\"page_w\""))
        @Assert(at(text, "\"page_w\"") < at(text, "\"page_h\""))
        @Assert(at(text, "\"page_h\"") < at(text, "\"title\""))
        @Assert(at(text, "\"title\"") < at(text, "\"author\""))
        @Assert(at(text, "\"author\"") < at(text, "\"producer\""))
        @Assert(at(text, "\"producer\"") < at(text, "\"fonts\""))
    }

    @TestCase
    func pageToJsonEmitsTheBarePageObject() {
        let text = pageToJson(makePage())
        let parsed = JsonValue.fromStr(text).asObject()
        @Expect(parsed["width"].asInt().getValue(), 612)
        @Expect(parsed["height"].asInt().getValue(), 792)
        @Expect(parsed["chars"].asArray().size(), 2)
        @Expect(parsed["tables"].asArray().get(0).getOrThrow().asObject()["cells"].asArray().size(), 2)
        // No export wrapper around the page.
        @Expect(text.contains("\"metadata\""), false)
        @Expect(text.contains("\"exportedAt\""), false)
        @Expect(text.contains("\"pageCount\""), false)
        @Expect(text.contains("\"objectTypes\""), false)
        @Expect(text.startsWith("{\n  \"width\": 612,\n  \"height\": 792,\n  \"chars\": ["), true)
        @Assert(at(text, "\"width\"") < at(text, "\"height\""))
        @Assert(at(text, "\"height\"") < at(text, "\"chars\""))
        @Assert(at(text, "\"chars\"") < at(text, "\"words\""))
        @Assert(at(text, "\"words\"") < at(text, "\"rects\""))
        @Assert(at(text, "\"rects\"") < at(text, "\"lines\""))
        @Assert(at(text, "\"lines\"") < at(text, "\"curves\""))
        @Assert(at(text, "\"curves\"") < at(text, "\"images\""))
        @Assert(at(text, "\"images\"") < at(text, "\"tables\""))
    }

    @TestCase
    func pageToJsonKeepsEveryTypeUnfiltered() {
        let parsed = JsonValue.fromStr(pageToJson(makePage())).asObject()
        @Expect(parsed["chars"].asArray().size(), 2)
        @Expect(parsed["words"].asArray().size(), 1)
        @Expect(parsed["rects"].asArray().size(), 1)
        @Expect(parsed["lines"].asArray().size(), 1)
        @Expect(parsed["curves"].asArray().size(), 1)
        @Expect(parsed["images"].asArray().size(), 1)
        @Expect(parsed["tables"].asArray().size(), 1)
    }

    @TestCase
    func documentToJsonReportsPageCountAndHasNoExportBookkeeping() {
        let pages = ArrayList<PageData>()
        pages.add(makePage())
        pages.add(makePage())
        let text = documentToJson(makeMetadata(), pages, None)
        let parsed = JsonValue.fromStr(text).asObject()
        @Expect(parsed["pageCount"].asInt().getValue(), 2)
        @Expect(parsed["pages"].asArray().size(), 2)
        @Expect(parsed["metadata"].asObject()["title"].asString().getValue(), "Demo")
        @Expect(text.contains("\"exportedAt\""), false)
        @Expect(text.contains("\"objectTypes\""), false)
        @Expect(text.startsWith("{\n  \"metadata\": {"), true)
        @Assert(at(text, "\n  \"metadata\": {") < at(text, "\n  \"pageCount\":"))
        @Assert(at(text, "\n  \"pageCount\":") < at(text, "\n  \"pages\": ["))
    }

    @TestCase
    func documentToJsonBlanksUnselectedArrays() {
        let parsed = JsonValue.fromStr(documentToJson(makeMetadata(), pagesOf(makePage()), Some(["table", "word"]))).asObject()
        let page = parsed["pages"].asArray().get(0).getOrThrow().asObject()
        @Expect(page["words"].asArray().size(), 1)
        @Expect(page["tables"].asArray().size(), 1)
        @Expect(page["chars"].asArray().size(), 0)
        @Expect(page["rects"].asArray().size(), 0)
        @Expect(page["lines"].asArray().size(), 0)
        @Expect(page["curves"].asArray().size(), 0)
        @Expect(page["images"].asArray().size(), 0)
        // Unselected keys still exist.
        @Expect(page.containsKey("chars"), true)
    }

    @TestCase
    func documentToJsonTreatsExplicitEmptySelectionAsNoObjectData() {
        let text = documentToJson(makeMetadata(), pagesOf(makePage()), Some(Array<String>()))
        let page = JsonValue.fromStr(text).asObject()["pages"].asArray().get(0).getOrThrow().asObject()
        @Expect(page["chars"].asArray().size(), 0)
        @Expect(page["words"].asArray().size(), 0)
        @Expect(page["rects"].asArray().size(), 0)
        @Expect(page["lines"].asArray().size(), 0)
        @Expect(page["curves"].asArray().size(), 0)
        @Expect(page["images"].asArray().size(), 0)
        @Expect(page["tables"].asArray().size(), 0)
        @Expect(page["width"].asInt().getValue(), 612)
    }

    @TestCase
    func documentToJsonKeepsEveryTypeWhenTypesAreOmitted() {
        let page = JsonValue.fromStr(documentToJson(makeMetadata(), pagesOf(makePage()), None))
            .asObject()["pages"].asArray().get(0).getOrThrow().asObject()
        @Expect(page["chars"].asArray().size(), 2)
        @Expect(page["words"].asArray().size(), 1)
        @Expect(page["rects"].asArray().size(), 1)
        @Expect(page["tables"].asArray().size(), 1)
    }
}

// --- CSV -------------------------------------------------------------------

@Test
class ExportCsvTest {
    @TestCase
    func startsWithTheUtf8Bom() {
        let csv = csvOf(makePage(), None)
        @Expect(csv.startsWith("\u{FEFF}"), true)
        @Expect(csv[0], 0xEF)
        @Expect(csv[1], 0xBB)
        @Expect(csv[2], 0xBF)
    }

    @TestCase
    func containsOneSectionPerTypeInCanonicalOrder() {
        let csv = csvOf(makePage(), None)
        let titles = ["# chars", "# words", "# rects", "# lines", "# curves", "# images", "# tables"]
        var previous = -1
        for (title in titles) {
            let position = at(csv, title)
            @Assert(position > previous)
            previous = position
        }
        @Expect(csv.endsWith("\n"), true)
    }

    @TestCase
    func escapesCommaQuoteAndNewlinePerRfc4180() {
        let csv = csvOf(makePage(), Some(["char"]))
        // `a,"b\nc` -> `"a,""b\nc"`, keeping the literal newline inside the cell.
        @Expect(csv.contains("\"a,\"\"b\nc\""), true)
        @Expect(csv.contains("page,x0,y0,x1,y1,text,fontname,size,color"), true)
        @Expect(csv.contains("1,1,2,3,4,\"a,\"\"b"), true)
    }

    @TestCase
    func writesCharsWordsAndRectRows() {
        let csv = csvOf(makePage(), None)
        @Expect(csv.contains("page,x0,y0,x1,y1,text,fontname,size"), true)
        @Expect(csv.contains("1,1,2,9,4,hello,F1,12"), true)
        @Expect(csv.contains("page,x0,y0,x1,y1,fill,stroke,color,width"), true)
        @Expect(csv.contains("1,0,0,10,10,true,false,\"1,0,0\",1"), true)
        @Expect(csv.contains("1,0,0,10,0,true,\"0,1,0\",0.5"), true)
        @Expect(csv.contains("page,x0,y0,x1,y1,stroke,color,width"), true)
    }

    @TestCase
    func writesImageRows() {
        let csv = csvOf(makePage(), Some(["image"]))
        @Expect(csv.contains("page,x0,y0,x1,y1,width,height,stream_id,format"), true)
        @Expect(csv.contains("1,0,0,20,20,20,20,p1_img_0,png"), true)
    }

    @TestCase
    func flattensTableCellsAsPageTableIndexRowColText() {
        let csv = csvOf(makePage(), Some(["table"]))
        @Expect(csv.contains("page,table_index,row,col,text"), true)
        @Expect(csv.contains("1,0,0,0,h1"), true)
        @Expect(csv.contains("1,0,1,1,v2"), true)
    }

    @TestCase
    func restartsTableIndexForEachPage() {
        let pages = ArrayList<PageData>()
        pages.add(makeTablePage(1, "a"))
        pages.add(makeTablePage(2, "b"))
        let csv = pagesToCsv(pages, Some(["table"]))
        @Expect(csv.contains("1,0,0,0,a"), true)
        @Expect(csv.contains("2,0,0,0,b"), true)
    }

    @TestCase
    func serializesCurvePointsAsCompactJson() {
        let csv = csvOf(makePage(), Some(["curve"]))
        @Expect(csv.contains("page,x0,y0,x1,y1,points,stroke"), true)
        @Expect(csv.contains("\"[[0,0],[5,5]]\""), true)
    }

    @TestCase
    func formatsColoursAndFloatsLikeJavaScriptString() {
        let csv = csvOf(makeScalarPage(), Some(["char", "rect"]))
        // Gray(0) -> 0, size 1.0 -> 1.
        @Expect(csv.contains("1,0,0,1,1,x,F1,1,0"), true)
        // Rgb(1, 0.5, 0) -> 1,0.5,0 (quoted, it holds commas); width 0.0 -> 0.
        @Expect(csv.contains("1,0,0,1,1,true,true,\"1,0.5,0\",0"), true)
    }

    @TestCase
    func formatsFloatsLikeJavaScriptString() {
        // Same table as the Python `_csv_cell` parametrisation, plus two extras.
        let cases: Array<(Float64, String)> = [
            (0.0, "0"),
            (12.0, "12"),
            (1.0, "1"),
            (-0.0, "0"),
            (0.5, "0.5"),
            (-0.5, "-0.5"),
            (1.25, "1.25"),
            (1.0e-6, "0.000001"),
            (1.0e-7, "1e-7"),
            (1.0e21, "1e+21"),
            (1.0e20, "100000000000000000000"),
            (0.1 + 0.2, "0.30000000000000004"),
            (1234.5678, "1234.5678")
        ]
        let page = PageData(width: 1.0, height: 1.0)
        for ((value, _) in cases) {
            page.chars.add(CharObj(text: "t", size: value, page: 1))
        }
        let csv = csvOf(page, Some(["char"]))
        for ((_, expected) in cases) {
            @Expect(csv.contains("t,,${expected},black"), true)
        }
    }

    @TestCase
    func quotesOnlyCellsThatNeedIt() {
        let page = PageData(width: 1.0, height: 1.0)
        page.chars.add(CharObj(text: "plain", fontname: "F1", size: 1.0, page: 1))
        page.chars.add(CharObj(text: "say \"hi\"", fontname: "F1", size: 1.0, page: 1))
        page.chars.add(CharObj(text: "cr\rlf", fontname: "F1", size: 1.0, page: 1))
        let csv = csvOf(page, Some(["char"]))
        @Expect(csv.contains(",plain,F1,1,"), true)
        @Expect(csv.contains(",\"say \"\"hi\"\"\",F1,1,"), true)
        @Expect(csv.contains(",\"cr\rlf\",F1,1,"), true)
    }

    @TestCase
    func emitsOnlySelectedSections() {
        let csv = csvOf(makePage(), Some(["table", "word"]))
        @Expect(csv.startsWith("\u{FEFF}# words\n"), true)
        @Assert(at(csv, "# words") < at(csv, "# tables"))
        for (omitted in ["# chars", "# rects", "# lines", "# curves", "# images"]) {
            @Expect(csv.contains(omitted), false)
        }
    }

    @TestCase
    func returnsOnlyTheBomForAnEmptyOrUnknownSelection() {
        @Expect(csvOf(makePage(), Some(Array<String>())), "\u{FEFF}")
        @Expect(csvOf(makePage(), Some(["bogus"])), "\u{FEFF}")
    }

    @TestCase
    func keepsFullOutputForNoneAndExplicitAllTypes() {
        let page = makePage()
        let implicit = csvOf(page, None)
        @Expect(csvOf(page, Some(EXPORT_OBJECT_TYPES)), implicit)
    }
}

// --- file names ------------------------------------------------------------

@Test
class ExportFilenameTest {
    @TestCase
    func buildsPageScopedAndDocumentScopedNames() {
        @Expect(suggestFilename("/tmp/report.pdf", "page", 2, "json"), "report-p2.json")
        @Expect(suggestFilename("/tmp/report.pdf", "document", 1, "json"), "report-all.json")
        @Expect(suggestFilename("/docs/report.pdf", "page", 3, "json"), "report-p3.json")
        @Expect(suggestFilename("C:\\docs\\report.pdf", "document", 1, "csv"), "report-all.csv")
    }

    @TestCase
    func stripsAnUpperCasePdfSuffix() {
        @Expect(suggestFilename("/tmp/report.PDF", "page", 2, "json"), "report-p2.json")
        @Expect(suggestFilename("/tmp/Report.Pdf", "document", 1, "csv"), "Report-all.csv")
        // Not a PDF suffix: kept as-is.
        @Expect(suggestFilename("/a/b.txt", "document", 1, "csv"), "b.txt-all.csv")
    }

    @TestCase
    func keepsNonAsciiFileNamesIntact() {
        @Expect(suggestFilename("/tmp/报告.pdf", "page", 2, "json"), "报告-p2.json")
        @Expect(suggestFilename("/tmp/报告.PDF", "document", 1, "csv"), "报告-all.csv")
    }

    @TestCase
    func fallsBackToDocumentWhenThePathIsEmpty() {
        @Expect(suggestFilename("", "page", 1, "json"), "document-p1.json")
        @Expect(suggestFilename("", "document", 1, "csv"), "document-all.csv")
        @Expect(suggestFilename("/tmp/", "page", 1, "json"), "document-p1.json")
    }

    @TestCase
    func treatsAnyOtherScopeAsTheDocument() {
        @Expect(suggestFilename("/tmp/report.pdf", "weird", 5, "json"), "report-all.json")
    }
}

// --- type selection --------------------------------------------------------

@Test
class ExportTypesTest {
    @TestCase
    func noneMeansEveryTypeInCanonicalOrder() {
        @Expect(joinedTypes(resolveTypes(None)), "char,word,rect,line,curve,image,table")
        @Expect(resolveTypes(None).size, 7)
    }

    @TestCase
    func explicitEmptyStaysEmpty() {
        @Expect(resolveTypes(Some(Array<String>())).size, 0)
    }

    @TestCase
    func reportsCanonicalOrderRegardlessOfInputOrder() {
        @Expect(joinedTypes(resolveTypes(Some(["table", "char", "image"]))), "char,image,table")
    }

    @TestCase
    func deduplicatesAndDropsUnknownValues() {
        @Expect(joinedTypes(resolveTypes(Some(["rect", "rect", "bogus", "line", "???"]))), "rect,line")
        @Expect(joinedTypes(resolveTypes(Some(["table", "word", "bogus", "word"]))), "word,table")
    }

    @TestCase
    func canonicalOrderConstantIsStable() {
        @Expect(joinedTypes(EXPORT_OBJECT_TYPES), "char,word,rect,line,curve,image,table")
    }
}
