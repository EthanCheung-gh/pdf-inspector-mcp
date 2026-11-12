package pdf_inspector_mcp.pdf

import std.collection.*
import std.fs.*

/**
 * A loaded PDF document: cross-reference/object access, page tree, metadata.
 *
 * The whole file is read into memory at `open`, so there is no OS file handle
 * to leak; `close` only marks the document unusable for callers that follow
 * the normal session lifecycle.
 *
 * Encryption is detected but not implemented: an `/Encrypt` entry makes `open`
 * fail with an actionable message instead of returning garbage.
 */
public class PdfDocument {
    let path: String
    let parser: PdfObjectParser
    var pageInfos: ArrayList<PageNodeInfo>
    var pageCache: HashMap<Int64, PdfPage>
    var infoEntries: HashMap<String, PdfValue>
    var closed: Bool

    private init(path: String, parser: PdfObjectParser) {
        this.path = path
        this.parser = parser
        this.pageInfos = ArrayList<PageNodeInfo>()
        this.pageCache = HashMap<Int64, PdfPage>()
        this.infoEntries = parser.infoEntries()
        this.closed = false
        loadPageTree()
    }

    public static func open(path: String, password: Option<String>): PdfDocument {
        if (path.isEmpty()) {
            throw PdfError("cannot open PDF: the path is empty")
        }
        let data = try {
            File.readFrom(path)
        } catch (e: Exception) {
            throw PdfError("cannot open PDF '${path}': ${e.message}")
        }
        if (data.size == 0) {
            throw PdfError("cannot open PDF '${path}': the file is empty")
        }
        let parser = try {
            PdfObjectParser(data)
        } catch (e: Exception) {
            throw PdfError("cannot open PDF '${path}': ${e.message}")
        }
        if (parser.version == "unknown") {
            match (parser.rootValue()) {
                case Some(_) => ()
                case None =>
                    throw PdfError(
                        "cannot open PDF '${path}': no %PDF- header and no readable cross-reference table"
                    )
            }
        }
        if (parser.trailer.contains("Encrypt")) {
            let note = match (password) {
                case Some(_) => "a password was supplied, but the Cangjie engine does not support PDF decryption yet"
                case None => "the Cangjie engine does not support PDF decryption yet"
            }
            throw PdfError("password required or incorrect (pass the 'password' argument for encrypted PDFs): '${path}' is encrypted and ${note}")
        }
        try {
            PdfDocument(path, parser)
        } catch (e: PdfError) {
            throw PdfError("cannot open PDF '${path}': ${e.message}")
        } catch (e: Exception) {
            throw PdfError("cannot open PDF '${path}': ${e.message}")
        }
    }

    public prop pageCount: Int64 {
        get() {
            pageInfos.size
        }
    }

    public prop version: String {
        get() {
            parser.version
        }
    }

    public prop encrypted: Bool {
        get() {
            parser.trailer.contains("Encrypt")
        }
    }

    public prop info: HashMap<String, PdfValue> {
        get() {
            infoEntries
        }
    }

    /** 1-based page lookup; out-of-range numbers raise a `PdfError`. */
    public func page(number: Int64): PdfPage {
        if (number < 1 || number > pageInfos.size) {
            throw PdfError(
                "page ${number} is out of range (this document has ${pageInfos.size} pages)"
            )
        }
        match (pageCache.get(number)) {
            case Some(page) => return page
            case None => ()
        }
        let page = PdfPage(this, number, pageInfos[number - 1])
        pageCache.add(number, page)
        page
    }

    public func metadata(): PdfMetadata {
        let pages = pageInfos.size
        var pageW: Float64 = 0.0
        var pageH: Float64 = 0.0
        if (pages > 0) {
            let first = page(1)
            pageW = first.width
            pageH = first.height
        }
        let title = match (asTextFromInfo("Title")) {
            case Some(value) => value
            case None => ""
        }
        let author = match (asTextFromInfo("Author")) {
            case Some(value) => value
            case None => ""
        }
        let producer = match (asTextFromInfo("Producer")) {
            case Some(value) => value
            case None => ""
        }
        let fonts = collectFontNames()
        PdfMetadata(
            pages: pages,
            version: version,
            encrypted: encrypted,
            pageW: pageW,
            pageH: pageH,
            title: title,
            author: author,
            producer: producer,
            fonts: fonts
        )
    }

    private func asTextFromInfo(key: String): Option<String> {
        match (infoEntries.get(key)) {
            case Some(value) => asText(value)
            case None => None
        }
    }

    /**
     * Collect `/BaseFont` names from every page's `/Font` resource dictionary.
     * This never interprets a content stream; it only follows resources.
     */
    private func collectFontNames(): ArrayList<String> {
        let seen = HashSet<String>()
        for (info in pageInfos) {
            let fontValue = match (info.resources.get("Font")) {
                case Some(value) => value
                case None => continue
            }
            let fonts = match (asDict(fontValue)) {
                case Some(entries) => entries
                case None => continue
            }
            for ((_, fontEntry) in fonts) {
                let fontDict = match (asDict(fontEntry)) {
                    case Some(entries) => entries
                    case None => continue
                }
                let baseFont: Option<String> = match (fontDict.get("BaseFont")) {
                    case Some(value) => asName(value)
                    case None => None
                }
                match (baseFont) {
                    case Some(name) =>
                        if (!name.isEmpty()) {
                            seen.add(name)
                        }
                    case None => ()
                }
            }
        }
        let names = ArrayList<String>()
        for (name in seen) {
            names.add(name)
        }
        sortStrings(names)
        names
    }

    private func sortStrings(values: ArrayList<String>): Unit {
        // Small lists only (font names); plain insertion sort avoids the
        // deprecated ArrayList sort APIs.
        for (i in 1..values.size) {
            let current = values[i]
            var j = i - 1
            while (j >= 0 && values[j] > current) {
                values[j + 1] = values[j]
                j -= 1
            }
            values[j + 1] = current
        }
    }

    // ------------------------------------------------------------------
    // Page tree

    private func loadPageTree(): Unit {
        pageInfos.clear()
        let rootValue = match (parser.trailer.get("Root")) {
            case Some(value) => value
            case None => throw pageTreeError("/Root is missing")
        }
        let catalog = match (parser.resolve(rootValue)) {
            case PdfValue.PdfDict(entries) => entries
            case PdfValue.PdfNull =>
                throw pageTreeError("/Root is missing or unreadable" + resolutionDetail(rootValue))
            case _ => throw pageTreeError("/Root is not a dictionary")
        }
        let pagesValue = match (catalog.get("Pages")) {
            case Some(value) => value
            case None => throw pageTreeError("/Pages is missing from the catalog")
        }
        let active = HashSet<Int64>()
        walkPages(
            pagesValue,
            HashMap<String, PdfValue>(),
            None,
            None,
            0,
            active,
            0
        )
    }

    /**
     * Walk one page-tree node.
     *
     * A node with `/Kids` is an intermediate Pages node; an empty `/Kids`
     * array is a legitimate empty tree. A node without `/Kids` is a page,
     * unless its `/Type` is `/Pages`, in which case it is only legal when it
     * also declares `/Count 0`. Any unresolvable child, non-dictionary node or
     * reference cycle is corruption and raises `PdfError` instead of silently
     * shortening the page list.
     */
    private func walkPages(
        nodeValue: PdfValue,
        parentResources: HashMap<String, PdfValue>,
        parentMedia: Option<PdfValue>,
        parentCrop: Option<PdfValue>,
        parentRotate: Int64,
        active: HashSet<Int64>,
        depth: Int64
    ): Unit {
        if (depth > 256) {
            throw pageTreeError("page-tree nesting exceeds 256 levels")
        }
        var activeRef: Option<Int64> = None
        let resolved = match (nodeValue) {
            case PdfValue.PdfRef(num, gen) =>
                if (active.contains(num)) {
                    throw pageTreeError("reference cycle at ${num} ${gen} R")
                }
                active.add(num)
                activeRef = Some(num)
                parser.resolveRef(num, gen)
            case _ => nodeValue
        }
        try {
            let dict = match (resolved) {
                case PdfValue.PdfDict(entries) => entries
                case PdfValue.PdfNull =>
                    throw pageTreeError(
                        "page-tree object ${describeValue(nodeValue)} is missing or unreadable" +
                        resolutionDetail(nodeValue)
                    )
                case _ =>
                    throw pageTreeError("page-tree object ${describeValue(nodeValue)} is not a dictionary")
            }
            let resources = match (dict.get("Resources")) {
                case Some(value) =>
                    match (asDict(value)) {
                        case Some(entries) => entries
                        case None => parentResources
                    }
                case None => parentResources
            }
            let media = match (dict.get("MediaBox")) {
                case Some(value) => Some(parser.resolve(value))
                case None => parentMedia
            }
            let crop = match (dict.get("CropBox")) {
                case Some(value) => Some(parser.resolve(value))
                case None => parentCrop
            }
            let rotate = match (dict.get("Rotate")) {
                case Some(value) =>
                    match (asInt(value)) {
                        case Some(angle) => normalizeRotate(angle)
                        case None => parentRotate
                    }
                case None => parentRotate
            }
            match (dict.get("Kids")) {
                case Some(kidsValue) =>
                    for (kid in pageTreeKids(nodeValue, kidsValue)) {
                        walkPages(kid, resources, media, crop, rotate, active, depth + 1)
                    }
                case None =>
                    let typeName = match (dict.get("Type")) {
                        case Some(PdfValue.PdfName(name)) => name
                        case _ => ""
                    }
                    let countValue = dict.get("Count")
                    let count = match (countValue) {
                        case Some(value) =>
                            match (asInt(value)) {
                                case Some(number) => number
                                case None => -1
                            }
                        case None => -1
                    }
                    if (typeName == "Pages" || (countValue.isSome() && count == 0)) {
                        if (count == 0) {
                            // `/Count 0` without `/Kids` is the other spelling
                            // of a legitimate empty page tree (some writers
                            // omit `/Type /Pages` on such nodes).
                            return
                        }
                        throw pageTreeError(
                            "/Pages node ${describeValue(nodeValue)} has no /Kids array"
                        )
                    }
                    pageInfos.add(PageNodeInfo(dict, resources, media, crop, rotate))
            }
        } finally {
            match (activeRef) {
                case Some(number) => active.remove(number)
                case None => ()
            }
        }
    }

    private func pageTreeKids(nodeValue: PdfValue, kidsValue: PdfValue): ArrayList<PdfValue> {
        match (parser.resolve(kidsValue)) {
            case PdfValue.PdfArray(values) => values
            case PdfValue.PdfNull =>
                throw pageTreeError(
                    "/Kids of ${describeValue(nodeValue)} is missing or unreadable" +
                    resolutionDetail(kidsValue)
                )
            case _ => throw pageTreeError("/Kids of ${describeValue(nodeValue)} is not an array")
        }
    }

    private func pageTreeError(reason: String): PdfError {
        PdfError("cannot read the page tree: " + reason)
    }

    private func resolutionDetail(value: PdfValue): String {
        match (parser.resolutionError(value)) {
            case Some(reason) => ": " + reason
            case None => ""
        }
    }

    private func normalizeRotate(angle: Int64): Int64 {
        var value = angle % 360
        if (value < 0) {
            value += 360
        }
        value
    }

    // ------------------------------------------------------------------
    // Value helpers

    public func resolve(value: PdfValue): PdfValue {
        parser.resolve(value)
    }

    /** Underlying parse error for a value that resolved to `PdfNull`, if any. */
    public func resolutionError(value: PdfValue): Option<String> {
        parser.resolutionError(value)
    }

    public func asDict(value: PdfValue): Option<HashMap<String, PdfValue>> {
        match (resolve(value)) {
            case PdfValue.PdfDict(entries) => Some(entries)
            case _ => None
        }
    }

    public func asArray(value: PdfValue): Option<ArrayList<PdfValue>> {
        match (resolve(value)) {
            case PdfValue.PdfArray(items) => Some(items)
            case _ => None
        }
    }

    public func asName(value: PdfValue): Option<String> {
        match (resolve(value)) {
            case PdfValue.PdfName(name) => Some(name)
            case _ => None
        }
    }

    public func asInt(value: PdfValue): Option<Int64> {
        match (resolve(value)) {
            case PdfValue.PdfInt(number) => Some(number)
            case PdfValue.PdfReal(real) => Some(Int64(real))
            case _ => None
        }
    }

    public func asNumber(value: PdfValue): Option<Float64> {
        match (resolve(value)) {
            case PdfValue.PdfInt(number) => Some(Float64(number))
            case PdfValue.PdfReal(real) => Some(real)
            case _ => None
        }
    }

    /** Decode a PDF string: UTF-16BE BOM, UTF-16LE BOM, otherwise PDFDocEncoding. */
    public func asText(value: PdfValue): Option<String> {
        let resolved = resolve(value)
        match (resolved) {
            case PdfValue.PdfString(bytes) => Some(decodeTextString(bytes))
            case _ => None
        }
    }

    public func streamData(stream: PdfStream): Array<UInt8> {
        parser.decodeResolved(stream)
    }

    public func close(): Unit {
        closed = true
    }

    public func isClosed(): Bool {
        closed
    }

    /** Number of cached indirect objects; exposed for diagnostics/tests. */
    public func objectCacheSize(): Int64 {
        parser.cacheSize()
    }

    public func xrefSize(): Int64 {
        parser.xrefSize()
    }
}

// ---------------------------------------------------------------------------
// String decoding

private func appendCodepoint(out: ArrayList<UInt8>, codepoint: Int64): Unit {
    var cp = codepoint
    if (cp < 0) {
        cp = 0xFFFD
    }
    if (cp <= 0x7F) {
        out.add(UInt8(cp))
    } else if (cp <= 0x7FF) {
        out.add(UInt8(0xC0 | (cp >> 6)))
        out.add(UInt8(0x80 | (cp & 0x3F)))
    } else if (cp <= 0xFFFF) {
        out.add(UInt8(0xE0 | (cp >> 12)))
        out.add(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.add(UInt8(0x80 | (cp & 0x3F)))
    } else if (cp <= 0x10FFFF) {
        out.add(UInt8(0xF0 | (cp >> 18)))
        out.add(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        out.add(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.add(UInt8(0x80 | (cp & 0x3F)))
    } else {
        appendCodepoint(out, 0xFFFD)
    }
}

private func decodeTextString(bytes: Array<UInt8>): String {
    if (bytes.size >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
        return decodeUtf16(bytes, 2, false)
    }
    if (bytes.size >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
        return decodeUtf16(bytes, 2, true)
    }
    let out = ArrayList<UInt8>(bytes.size + 8)
    for (b in bytes) {
        appendCodepoint(out, pdfDocCodepoint(Int64(b)))
    }
    String.fromUtf8(out.toArray())
}

private func decodeUtf16(bytes: Array<UInt8>, start: Int64, littleEndian: Bool): String {
    let out = ArrayList<UInt8>(bytes.size + 8)
    var i = start
    while (i + 1 < bytes.size) {
        let first = if (littleEndian) {
            Int64(bytes[i]) | (Int64(bytes[i + 1]) << 8)
        } else {
            (Int64(bytes[i]) << 8) | Int64(bytes[i + 1])
        }
        i += 2
        if (first >= 0xD800 && first <= 0xDBFF && i + 1 < bytes.size) {
            let second = if (littleEndian) {
                Int64(bytes[i]) | (Int64(bytes[i + 1]) << 8)
            } else {
                (Int64(bytes[i]) << 8) | Int64(bytes[i + 1])
            }
            if (second >= 0xDC00 && second <= 0xDFFF) {
                i += 2
                let codepoint = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                appendCodepoint(out, codepoint)
                continue
            }
        }
        appendCodepoint(out, first)
    }
    String.fromUtf8(out.toArray())
}

/**
 * PDFDocEncoding: Latin-1 except for the 0x18..0x1F and 0x80..0xA0 blocks.
 * Codes 0x7F and 0x9F are undefined and become U+FFFD.
 */
private func pdfDocCodepoint(code: Int64): Int64 {
    match (code) {
        case 0x18 => 0x02D8
        case 0x19 => 0x02C7
        case 0x1A => 0x02C6
        case 0x1B => 0x02D9
        case 0x1C => 0x02DD
        case 0x1D => 0x02DB
        case 0x1E => 0x02DA
        case 0x1F => 0x02DC
        case 0x7F => 0xFFFD
        case 0x80 => 0x2022
        case 0x81 => 0x2020
        case 0x82 => 0x2021
        case 0x83 => 0x2026
        case 0x84 => 0x2014
        case 0x85 => 0x2013
        case 0x86 => 0x0192
        case 0x87 => 0x2044
        case 0x88 => 0x2039
        case 0x89 => 0x203A
        case 0x8A => 0x2212
        case 0x8B => 0x2030
        case 0x8C => 0x201E
        case 0x8D => 0x201C
        case 0x8E => 0x201D
        case 0x8F => 0x2018
        case 0x90 => 0x2019
        case 0x91 => 0x201A
        case 0x92 => 0x2122
        case 0x93 => 0xFB01
        case 0x94 => 0xFB02
        case 0x95 => 0x0141
        case 0x96 => 0x0152
        case 0x97 => 0x0160
        case 0x98 => 0x0178
        case 0x99 => 0x017D
        case 0x9A => 0x0131
        case 0x9B => 0x0142
        case 0x9C => 0x0153
        case 0x9D => 0x0161
        case 0x9E => 0x017E
        case 0x9F => 0xFFFD
        case 0xA0 => 0x20AC
        case _ => code
    }
}
