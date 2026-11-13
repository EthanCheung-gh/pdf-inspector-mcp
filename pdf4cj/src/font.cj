package pdf4cj

import std.collection.*

/**
 * The font decoding layer used by the content-stream interpreter.
 *
 * One `PdfFont` answers the three questions a text-showing operator needs:
 *
 * - how many bytes the next character code occupies ([PdfFont.codeLength]);
 * - which Unicode text that code stands for ([PdfFont.decode]), empty when the
 *   code cannot be mapped;
 * - how wide the glyph is in 1/1000 em ([PdfFont.width]).
 *
 * Both halves of the PDF font model are covered:
 *
 * - simple fonts (`/Type1`, `/TrueType`, `/MMType1`, `/Type3`): one byte per
 *   code, `/Widths` or the standard-14 metrics, a base encoding plus
 *   `/Differences`, and an optional `/ToUnicode` CMap that takes precedence;
 * - composite fonts (`/Type0`): multi-byte codes from the code space of
 *   Identity-H/V or an embedded CMap stream, `/W`/`/DW` widths and a
 *   `/ToUnicode` CMap as the only source of Unicode text.
 *
 * `loadFont` needs a `PdfDocument` for reference resolution and stream
 * decoding, but the logic lives in [loadFontFromDict], which takes those two
 * operations as closures so the loader can be unit tested on synthetic
 * dictionaries with an identity resolver.
 *
 * Known limits, all of them "text/metrics degrade, nothing crashes":
 *
 * - vertical writing (`Identity-V`, `/W2`) is read as horizontal: codes and
 *   Unicode are right, the advance is the horizontal one;
 * - a `/Type0` font without `/ToUnicode` yields empty text, since there is no
 *   reliable way from a CID to Unicode without the embedded font program;
 * - `/CIDToGIDMap` is ignored: it matters for rendering, not for advances;
 * - a `/Type3` font maps codes only through its encoding and `/ToUnicode`; its
 *   glyph procedures are never executed;
 * - Symbol and ZapfDingbats report 0/0 for ascent/descent (the standard-14
 *   data has none) and use the built-in encoding from `encoding_data.cj`.
 */

/** One `/W` entry: CIDs `first..last` all advance by `widthValue` (1/1000 em). */
class CidWidthRange {
    let first: Int64
    let last: Int64
    let widthValue: Float64

    init(first: Int64, last: Int64, widthValue: Float64) {
        this.first = first
        this.last = last
        this.widthValue = widthValue
    }
}

public class PdfFont {
    var fontName: String = "unknown"
    var cidFont: Bool = false
    var ascentValue: Float64 = 0.8
    var descentValue: Float64 = -0.2

    // Simple fonts: widths indexed by (code - firstCharValue).
    var firstCharValue: Int64 = 0
    var widthValues: Array<Float64> = Array<Float64>()
    var missingWidthValue: Float64 = 0.0
    var base14: Option<Base14Metrics> = None
    /** code -> Unicode text for simple fonts (256 entries). */
    var encodingTable: Array<String> = Array<String>()
    /** `/FontMatrix` scale for Type3 widths (1.0 means "already 1/1000 em"). */
    var widthScale: Float64 = 1.0

    // Composite fonts.
    var cidDefaultWidth: Float64 = 1000.0
    var cidWidthRanges: ArrayList<CidWidthRange> = ArrayList<CidWidthRange>()
    var encodingCmap: Option<ToUnicodeCMap> = None
    var cidCodeBytes: Int64 = 2

    /** `/ToUnicode` mapping shared by both font kinds; takes precedence. */
    var toUnicodeMap: Option<ToUnicodeCMap> = None

    init() {}

    /**
     * Name as written in `/BaseFont`; `"unknown"` when the font has no name.
     * A subset prefix such as `ABCDEF+` is kept, because callers report this
     * string as-is.
     */
    public prop name: String {
        get() {
            fontName
        }
    }

    /** True for `/Type0` composite fonts, which use multi-byte character codes. */
    public prop isCid: Bool {
        get() {
            cidFont
        }
    }

    /** Ascender in em units, e.g. 0.718 for Helvetica. */
    public prop ascent: Float64 {
        get() {
            ascentValue
        }
    }

    /** Descender in em units, always negative (or zero), e.g. -0.207 for Helvetica. */
    public prop descent: Float64 {
        get() {
            descentValue
        }
    }

    /** Whether a `/ToUnicode` CMap was found and parsed. */
    public prop hasToUnicode: Bool {
        get() {
            match (toUnicodeMap) {
                case Some(_) => true
                case None => false
            }
        }
    }

    /**
     * Byte length of the character code at `offset`.
     *
     * Simple fonts always answer 1. Composite fonts match the CMap code space
     * (longest match first) and fall back to 2 bytes, the Identity-H/V width.
     */
    public func codeLength(bytes: Array<UInt8>, offset: Int64): Int64 {
        if (!cidFont) {
            return 1
        }
        cidCodeLength(bytes, offset)
    }

    /**
     * Decode the character code at `offset`: the code itself (for [width]) and
     * its Unicode text.
     *
     * The text is empty when the code is unmappable; the caller still advances
     * by [codeLength] and counts the width. An `offset` outside the buffer
     * yields `(0, "")` instead of an exception.
     */
    public func decode(bytes: Array<UInt8>, offset: Int64): (Int64, String) {
        if (offset < 0 || offset >= bytes.size) {
            return (0, "")
        }
        if (!cidFont) {
            let code = Int64(bytes[offset])
            return (code, simpleText(code))
        }
        var length = cidCodeLength(bytes, offset)
        let available = bytes.size - offset
        if (length > available) {
            length = available
        }
        if (length < 1) {
            length = 1
        }
        let code = cmapBigEndian(bytes, offset, length)
        var text = ""
        match (toUnicodeMap) {
            case Some(cmap) =>
                match (cmap.lookup(code)) {
                    case Some(value) => text = value
                    case None => ()
                }
            case None => ()
        }
        (code, text)
    }

    /**
     * Glyph advance in 1/1000 em.
     *
     * Unknown codes fall back to `/MissingWidth` (simple fonts) or `/DW`
     * (composite fonts, 1000 by default).
     */
    public func width(code: Int64): Float64 {
        if (cidFont) {
            return cidWidthOf(code)
        }
        if (code < 0) {
            return 0.0
        }
        if (!widthValues.isEmpty()) {
            let index = code - firstCharValue
            if (index >= 0 && index < widthValues.size) {
                return widthValues[index] * widthScale
            }
            if (missingWidthValue > 0.0) {
                return missingWidthValue
            }
            return base14Width(code)
        }
        let standard = base14Width(code)
        if (standard > 0.0) {
            return standard
        }
        if (missingWidthValue > 0.0) {
            return missingWidthValue
        }
        0.0
    }

    // ------------------------------------------------------------------
    // Internals

    private func simpleText(code: Int64): String {
        match (toUnicodeMap) {
            case Some(cmap) =>
                match (cmap.lookup(code)) {
                    case Some(value) =>
                        if (!value.isEmpty()) {
                            return value
                        }
                    case None => ()
                }
            case None => ()
        }
        if (code >= 0 && code < encodingTable.size) {
            return encodingTable[code]
        }
        ""
    }

    private func base14Width(code: Int64): Float64 {
        match (base14) {
            case Some(metrics) => Float64(metrics.width(code))
            case None => 0.0
        }
    }

    private func cidWidthOf(code: Int64): Float64 {
        var cid = code
        match (encodingCmap) {
            case Some(cmap) =>
                match (cmap.lookupCid(code)) {
                    case Some(value) => cid = value
                    case None => ()
                }
            case None => ()
        }
        for (range in cidWidthRanges) {
            if (cid >= range.first && cid <= range.last) {
                return range.widthValue
            }
        }
        cidDefaultWidth
    }

    private func cidCodeLength(bytes: Array<UInt8>, offset: Int64): Int64 {
        if (offset < 0 || offset >= bytes.size) {
            return cidCodeBytes
        }
        match (encodingCmap) {
            case Some(cmap) =>
                let length = cmap.codeByteLength(bytes, offset)
                if (length > 0) {
                    return length
                }
            case None => ()
        }
        match (toUnicodeMap) {
            case Some(cmap) =>
                let length = cmap.codeByteLength(bytes, offset)
                if (length > 0) {
                    return length
                }
            case None => ()
        }
        cidCodeBytes
    }
}

// ---------------------------------------------------------------------------
// Loading

/**
 * Build a font from an unresolved `/Font` dictionary.
 *
 * `resolver` follows indirect references and `decoder` inflates a stream; both
 * are usually the matching `PdfDocument` members, which is exactly what
 * [loadFont] passes in. Tests use an identity resolver.
 *
 * A dictionary that carries none of `/Subtype`, `/BaseFont`, `/Widths` or
 * `/DescendantFonts` is not a font and raises `PdfError`, so the caller can
 * fall back to a default font. Everything else is recovered on a best-effort
 * basis: a missing entry costs a default, never an exception.
 */
public func loadFontFromDict(
    fontDict: HashMap<String, PdfValue>,
    resolver: (PdfValue) -> PdfValue,
    decoder: (PdfStream) -> Array<UInt8>
): PdfFont {
    if (!looksLikeFont(fontDict)) {
        throw PdfError("font dictionary has no /Subtype, /BaseFont, /Widths or /DescendantFonts")
    }
    let font = PdfFont()
    let subtype = entryName(fontDict, "Subtype", resolver)
    if (subtype == "Type0") {
        buildCompositeFont(font, fontDict, resolver, decoder)
    } else {
        buildSimpleFont(font, fontDict, resolver, decoder)
    }
    font
}

/**
 * A `/Font` dictionary always carries `/Subtype`; `/BaseFont` or the width
 * entries are the other markers of a usable font. Anything else is not a font
 * and the caller should fall back to a default one.
 */
private func looksLikeFont(fontDict: HashMap<String, PdfValue>): Bool {
    fontDict.contains("Subtype") || fontDict.contains("BaseFont") ||
        fontDict.contains("Widths") || fontDict.contains("DescendantFonts")
}

/** Build a font from a `/Font` dictionary; raises `PdfError` when unusable. */
public func loadFont(doc: PdfDocument, fontDict: HashMap<String, PdfValue>): PdfFont {
    let resolver = { value: PdfValue => doc.resolve(value) }
    let decoder = { stream: PdfStream => doc.streamData(stream) }
    loadFontFromDict(fontDict, resolver, decoder)
}

// ---------------------------------------------------------------------------
// Dictionary helpers

private func resolveEntry(
    dict: HashMap<String, PdfValue>,
    key: String,
    resolver: (PdfValue) -> PdfValue
): Option<PdfValue> {
    match (dict.get(key)) {
        case Some(value) => Some(resolver(value))
        case None => None
    }
}

private func entryName(
    dict: HashMap<String, PdfValue>,
    key: String,
    resolver: (PdfValue) -> PdfValue
): String {
    match (resolveEntry(dict, key, resolver)) {
        case Some(PdfName(name)) => name
        case _ => ""
    }
}

private func entryInt(
    dict: HashMap<String, PdfValue>,
    key: String,
    resolver: (PdfValue) -> PdfValue
): Option<Int64> {
    match (resolveEntry(dict, key, resolver)) {
        case Some(value) => intFromValue(value)
        case None => None
    }
}

private func entryNumber(
    dict: HashMap<String, PdfValue>,
    key: String,
    resolver: (PdfValue) -> PdfValue
): Option<Float64> {
    match (resolveEntry(dict, key, resolver)) {
        case Some(PdfInt(number)) => Some(Float64(number))
        case Some(PdfReal(real)) => Some(real)
        case _ => None
    }
}

private func entryDict(
    dict: HashMap<String, PdfValue>,
    key: String,
    resolver: (PdfValue) -> PdfValue
): Option<HashMap<String, PdfValue>> {
    match (resolveEntry(dict, key, resolver)) {
        case Some(PdfDict(entries)) => Some(entries)
        case _ => None
    }
}

private func entryArray(
    dict: HashMap<String, PdfValue>,
    key: String,
    resolver: (PdfValue) -> PdfValue
): Option<ArrayList<PdfValue>> {
    match (resolveEntry(dict, key, resolver)) {
        case Some(PdfArray(items)) => Some(items)
        case _ => None
    }
}

private func intFromValue(value: PdfValue): Option<Int64> {
    match (value) {
        case PdfInt(number) => Some(number)
        case PdfReal(real) => Some(Int64(real))
        case _ => None
    }
}

private func numberFromValue(value: PdfValue): Float64 {
    match (value) {
        case PdfInt(number) => Float64(number)
        case PdfReal(real) => real
        case _ => 0.0
    }
}

private func fontAbs(value: Float64): Float64 {
    if (value < 0.0) {
        -value
    } else {
        value
    }
}

// ---------------------------------------------------------------------------
// Shared pieces

/**
 * Standard-14 metrics for a font name, honouring a six-letter subset prefix:
 * `ABCDEF+Helvetica` looks up `Helvetica` while [PdfFont.name] keeps the
 * original spelling.
 */
func lookupBase14(name: String): Option<Base14Metrics> {
    if (name.isEmpty()) {
        return None
    }
    match (base14Metrics(normalizeBase14Name(name))) {
        case Some(metrics) => return Some(metrics)
        case None => ()
    }
    var tail = ""
    for (part in name.split("+")) {
        tail = part
    }
    if (tail.isEmpty() || tail == name) {
        return None
    }
    base14Metrics(normalizeBase14Name(tail))
}

private func copyEncoding(source: Array<String>): Array<String> {
    let table = Array<String>(source.size, repeat: "")
    var i: Int64 = 0
    while (i < source.size) {
        table[i] = source[i]
        i += 1
    }
    table
}

private func tableForEncodingName(name: String, fallback: Array<String>): Array<String> {
    if (name.isEmpty()) {
        return fallback
    }
    if (name == "WinAnsiEncoding") {
        return WIN_ANSI_ENCODING
    }
    if (name == "MacRomanEncoding") {
        return MAC_ROMAN_ENCODING
    }
    if (name == "PDFDocEncoding") {
        return PDF_DOC_ENCODING
    }
    if (name == "StandardEncoding") {
        return STANDARD_ENCODING
    }
    fallback
}

/** Apply `/Differences` on top of a base encoding table. */
private func differencesEncoding(
    base: Array<String>,
    entries: HashMap<String, PdfValue>,
    resolver: (PdfValue) -> PdfValue
): Array<String> {
    let table = copyEncoding(base)
    var items: Option<ArrayList<PdfValue>> = None
    match (entryArray(entries, "Differences", resolver)) {
        case Some(list) => items = Some(list)
        case None => ()
    }
    match (items) {
        case Some(list) =>
            var code: Int64 = -1
            for (item in list) {
                match (resolver(item)) {
                    case PdfInt(number) => code = number
                    case PdfReal(real) => code = Int64(real)
                    case PdfName(glyph) =>
                        if (code >= 0 && code < 256) {
                            match (glyphNameToUnicode(glyph)) {
                                case Some(text) => table[code] = text
                                case None => ()
                            }
                            code += 1
                        }
                    case _ => ()
                }
            }
        case None => ()
    }
    table
}

private func decodeStreamSafe(
    stream: PdfStream,
    decoder: (PdfStream) -> Array<UInt8>
): Array<UInt8> {
    try {
        decoder(stream)
    } catch (e: Exception) {
        stream.raw
    }
}

private func parseCmapSafe(bytes: Array<UInt8>): Option<ToUnicodeCMap> {
    try {
        Some(parseToUnicode(bytes))
    } catch (e: Exception) {
        None
    }
}

private func loadToUnicodeMap(
    dict: HashMap<String, PdfValue>,
    resolver: (PdfValue) -> PdfValue,
    decoder: (PdfStream) -> Array<UInt8>
): Option<ToUnicodeCMap> {
    var result: Option<ToUnicodeCMap> = None
    match (resolveEntry(dict, "ToUnicode", resolver)) {
        case Some(PdfStream(stream)) => result = parseCmapSafe(decodeStreamSafe(stream, decoder))
        case Some(PdfString(bytes)) => result = parseCmapSafe(bytes)
        case _ => ()
    }
    result
}

private func hasCmap(value: Option<ToUnicodeCMap>): Bool {
    match (value) {
        case Some(_) => true
        case None => false
    }
}

/**
 * Fill ascent/descent in em units.
 *
 * Order: `/FontDescriptor`, then (only when `useBBox`) `/FontBBox`, then the
 * standard-14 metrics, then the 0.8 / -0.2 default. A positive `/Descent` is
 * flipped so `descent` is always negative.
 */
private func applyVerticalMetrics(
    font: PdfFont,
    descriptor: Option<HashMap<String, PdfValue>>,
    bbox: Option<ArrayList<PdfValue>>,
    useBBox: Bool,
    resolver: (PdfValue) -> PdfValue
): Unit {
    var ascentReady = false
    var descentReady = false
    match (descriptor) {
        case Some(desc) =>
            match (entryNumber(desc, "Ascent", resolver)) {
                case Some(value) =>
                    font.ascentValue = fontAbs(value / 1000.0)
                    ascentReady = true
                case None => ()
            }
            match (entryNumber(desc, "Descent", resolver)) {
                case Some(value) =>
                    font.descentValue = -fontAbs(value / 1000.0)
                    descentReady = true
                case None => ()
            }
        case None => ()
    }
    if (useBBox && (!ascentReady || !descentReady)) {
        match (bbox) {
            case Some(items) =>
                if (items.size >= 4) {
                    if (!ascentReady) {
                        let value = numberFromValue(resolver(items[3])) / 1000.0 * font.widthScale
                        if (value > 0.0) {
                            font.ascentValue = value
                            ascentReady = true
                        }
                    }
                    if (!descentReady) {
                        let value = numberFromValue(resolver(items[1])) / 1000.0 * font.widthScale
                        if (value < 0.0) {
                            font.descentValue = value
                            descentReady = true
                        }
                    }
                }
            case None => ()
        }
    }
    if (!ascentReady || !descentReady) {
        match (font.base14) {
            case Some(metrics) =>
                if (!ascentReady && metrics.ascent > 0.0) {
                    font.ascentValue = metrics.ascent
                    ascentReady = true
                }
                if (!descentReady && metrics.descent < 0.0) {
                    font.descentValue = metrics.descent
                    descentReady = true
                }
            case None => ()
        }
    }
}

// ---------------------------------------------------------------------------
// Simple fonts

private func buildSimpleFont(
    font: PdfFont,
    dict: HashMap<String, PdfValue>,
    resolver: (PdfValue) -> PdfValue,
    decoder: (PdfStream) -> Array<UInt8>
): Unit {
    let subtype = entryName(dict, "Subtype", resolver)
    let baseFont = entryName(dict, "BaseFont", resolver)
    font.fontName = if (baseFont.isEmpty()) { "unknown" } else { baseFont }
    font.base14 = lookupBase14(font.fontName)

    let descriptor = entryDict(dict, "FontDescriptor", resolver)

    if (subtype == "Type3") {
        match (entryArray(dict, "FontMatrix", resolver)) {
            case Some(matrix) =>
                if (matrix.size > 0) {
                    let scale = numberFromValue(resolver(matrix[0])) * 1000.0
                    if (scale > 0.0) {
                        font.widthScale = scale
                    }
                }
            case None => ()
        }
    }

    match (entryArray(dict, "Widths", resolver)) {
        case Some(items) =>
            if (items.size > 0) {
                let values = Array<Float64>(items.size, repeat: 0.0)
                var i: Int64 = 0
                while (i < items.size) {
                    values[i] = numberFromValue(resolver(items[i]))
                    i += 1
                }
                font.widthValues = values
                match (entryInt(dict, "FirstChar", resolver)) {
                    case Some(value) => font.firstCharValue = value
                    case None => font.firstCharValue = 0
                }
            }
        case None => ()
    }

    match (descriptor) {
        case Some(desc) =>
            match (entryNumber(desc, "MissingWidth", resolver)) {
                case Some(value) => font.missingWidthValue = value
                case None => ()
            }
        case None => ()
    }

    var defaultTable = STANDARD_ENCODING
    if (subtype == "TrueType" || subtype == "MMType1") {
        defaultTable = WIN_ANSI_ENCODING
    }
    var encodingDone = false
    match (resolveEntry(dict, "Encoding", resolver)) {
        case Some(value) =>
            match (value) {
                case PdfName(encName) =>
                    font.encodingTable = copyEncoding(tableForEncodingName(encName, defaultTable))
                    encodingDone = true
                case PdfDict(entries) =>
                    let baseName = entryName(entries, "BaseEncoding", resolver)
                    font.encodingTable = differencesEncoding(
                        tableForEncodingName(baseName, defaultTable),
                        entries,
                        resolver
                    )
                    encodingDone = true
                case _ => ()
            }
        case None => ()
    }
    if (!encodingDone) {
        font.encodingTable = copyEncoding(defaultTable)
    }

    font.toUnicodeMap = loadToUnicodeMap(dict, resolver, decoder)
    applyVerticalMetrics(
        font,
        descriptor,
        entryArray(dict, "FontBBox", resolver),
        subtype == "Type3",
        resolver
    )
}

// ---------------------------------------------------------------------------
// Composite (Type0) fonts

private func buildCompositeFont(
    font: PdfFont,
    dict: HashMap<String, PdfValue>,
    resolver: (PdfValue) -> PdfValue,
    decoder: (PdfStream) -> Array<UInt8>
): Unit {
    font.cidFont = true
    font.cidCodeBytes = 2
    let baseFont = entryName(dict, "BaseFont", resolver)
    font.fontName = if (baseFont.isEmpty()) { "unknown" } else { baseFont }
    font.base14 = lookupBase14(font.fontName)

    var descendant: Option<HashMap<String, PdfValue>> = None
    match (entryArray(dict, "DescendantFonts", resolver)) {
        case Some(items) =>
            if (items.size > 0) {
                match (resolver(items[0])) {
                    case PdfDict(entries) => descendant = Some(entries)
                    case _ => ()
                }
            }
        case None => ()
    }

    // Encoding: Identity-H/V keeps two-byte codes; an embedded CMap stream
    // supplies its own code space (and code -> CID map, when present).
    match (resolveEntry(dict, "Encoding", resolver)) {
        case Some(PdfStream(stream)) =>
            match (parseCmapSafe(decodeStreamSafe(stream, decoder))) {
                case Some(cmap) =>
                    font.encodingCmap = Some(cmap)
                    let preferred = cmap.defaultByteLength()
                    if (preferred > 0) {
                        font.cidCodeBytes = preferred
                    }
                case None => ()
            }
        case _ => ()
    }

    match (descendant) {
        case Some(desc) =>
            match (entryNumber(desc, "DW", resolver)) {
                case Some(value) =>
                    if (value > 0.0) {
                        font.cidDefaultWidth = value
                    }
                case None => ()
            }
            match (entryArray(desc, "W", resolver)) {
                case Some(items) => readCidWidths(items, resolver, font.cidWidthRanges)
                case None => ()
            }
        case None => ()
    }
    if (font.cidWidthRanges.isEmpty()) {
        match (entryNumber(dict, "DW", resolver)) {
            case Some(value) =>
                if (value > 0.0) {
                    font.cidDefaultWidth = value
                }
            case None => ()
        }
        match (entryArray(dict, "W", resolver)) {
            case Some(items) => readCidWidths(items, resolver, font.cidWidthRanges)
            case None => ()
        }
    }

    font.toUnicodeMap = loadToUnicodeMap(dict, resolver, decoder)
    if (!hasCmap(font.toUnicodeMap)) {
        match (descendant) {
            case Some(desc) => font.toUnicodeMap = loadToUnicodeMap(desc, resolver, decoder)
            case None => ()
        }
    }
    // Some producers carry the Unicode mappings inside the /Encoding CMap
    // instead of a /ToUnicode stream; they are the same `beginbfchar` data, so
    // an encoding CMap that mapped codes to text doubles as the text source.
    if (!hasCmap(font.toUnicodeMap)) {
        match (font.encodingCmap) {
            case Some(cmap) =>
                if (cmap.mappedCount > 0) {
                    font.toUnicodeMap = Some(cmap)
                }
            case None => ()
        }
    }

    var descriptor = entryDict(dict, "FontDescriptor", resolver)
    var bbox = entryArray(dict, "FontBBox", resolver)
    match (descendant) {
        case Some(desc) =>
            match (entryDict(desc, "FontDescriptor", resolver)) {
                case Some(value) => descriptor = Some(value)
                case None => ()
            }
            match (entryArray(desc, "FontBBox", resolver)) {
                case Some(value) => bbox = Some(value)
                case None => ()
            }
        case None => ()
    }
    applyVerticalMetrics(font, descriptor, bbox, true, resolver)
}

/**
 * Read `/W`: either `c [w1 w2 ...]` (consecutive CIDs from `c`) or
 * `cFirst cLast w`.
 */
private func readCidWidths(
    items: ArrayList<PdfValue>,
    resolver: (PdfValue) -> PdfValue,
    ranges: ArrayList<CidWidthRange>
): Unit {
    var i: Int64 = 0
    while (i < items.size) {
        var first: Int64 = -1
        match (intFromValue(resolver(items[i]))) {
            case Some(value) => first = value
            case None => first = -1
        }
        if (first < 0) {
            i += 1
        } else if (i + 1 >= items.size) {
            return
        } else {
            let next = resolver(items[i + 1])
            match (next) {
                case PdfArray(list) =>
                    var k: Int64 = 0
                    while (k < list.size) {
                        let width = numberFromValue(resolver(list[k]))
                        ranges.add(CidWidthRange(first + k, first + k, width))
                        k += 1
                    }
                    i += 2
                case _ =>
                    var last: Int64 = -1
                    match (intFromValue(next)) {
                        case Some(value) => last = value
                        case None => last = -1
                    }
                    if (last < 0 || i + 2 >= items.size) {
                        return
                    }
                    if (last >= first) {
                        let width = numberFromValue(resolver(items[i + 2]))
                        ranges.add(CidWidthRange(first, last, width))
                    }
                    i += 3
            }
        }
    }
}
