package pdf4cj

import std.collection.*

/**
 * CMap reader for `/ToUnicode` streams and embedded encoding CMaps.
 *
 * A CMap is PostScript-like text, not PDF syntax, so it cannot go through
 * `PdfLexer`: here `<...>` is a hex string of 1..4 bytes (a character code, not
 * a PDF string), names are plain keywords, and the interesting payload sits
 * between `beginbfchar`/`beginbfrange`/`begincodespacerange` and their `end`
 * counterparts. The lexer below only knows the handful of token shapes a CMap
 * uses, which keeps it small and independent of the object parser.
 *
 * Two independent tables are built:
 *
 * - code -> Unicode text, from `beginbfchar`/`beginbfrange` (`/ToUnicode`);
 * - code -> CID, from `begincidchar`/`begincidrange` (embedded encoding CMaps).
 *
 * and the `begincodespacerange` sections are kept so that the font layer can
 * find the byte length of the next character code (longest match first). A
 * CMap without any codespace section reports `0` from
 * [ToUnicodeCMap.codeByteLength] and from [ToUnicodeCMap.defaultByteLength]:
 * "no opinion", so the caller's default applies (1 byte for simple fonts,
 * 2 for Identity-H).
 */

private let CMAP_NUL: UInt8 = 0
private let CMAP_TAB: UInt8 = 9
private let CMAP_LF: UInt8 = 10
private let CMAP_FF: UInt8 = 12
private let CMAP_CR: UInt8 = 13
private let CMAP_SPACE: UInt8 = 32

/** Upper bound on map entries built from a single CMap (ranges can be huge). */
private let CMAP_MAX_MAPPINGS: Int64 = 131072

private func cmapIsWhitespace(b: UInt8): Bool {
    b == CMAP_NUL || b == CMAP_TAB || b == CMAP_LF || b == CMAP_FF || b == CMAP_CR ||
        b == CMAP_SPACE
}

private func cmapIsDelimiter(b: UInt8): Bool {
    match (b) {
        case 0x3C | 0x3E | 0x5B | 0x5D | 0x28 | 0x29 | 0x7B | 0x7D | 0x2F | 0x25 => true
        case _ => false
    }
}

private func cmapHexValue(b: UInt8): Int64 {
    if (b >= 0x30 && b <= 0x39) {
        return Int64(b - 0x30)
    }
    if (b >= 0x41 && b <= 0x46) {
        return Int64(b - 0x37)
    }
    if (b >= 0x61 && b <= 0x66) {
        return Int64(b - 0x57)
    }
    -1
}

private func cmapOctalValue(b: UInt8): Int64 {
    if (b >= 0x30 && b <= 0x37) {
        return Int64(b - 0x30)
    }
    -1
}

/** Big-endian unsigned value of `length` bytes, clamped to the available bytes. */
func cmapBigEndian(bytes: Array<UInt8>, offset: Int64, length: Int64): Int64 {
    var value: Int64 = 0
    var i: Int64 = 0
    while (i < length) {
        let index = offset + i
        if (index >= 0 && index < bytes.size) {
            value = (value << 8) | Int64(bytes[index])
        }
        i += 1
    }
    value
}

private func cmapAppendCodepoint(out: ArrayList<UInt8>, codepoint: Int64): Unit {
    var cp = codepoint
    if (cp < 0 || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) {
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
    } else {
        out.add(UInt8(0xF0 | (cp >> 18)))
        out.add(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        out.add(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.add(UInt8(0x80 | (cp & 0x3F)))
    }
}

/**
 * Decode UTF-16BE bytes into a Cangjie (UTF-8) string.
 *
 * Surrogate pairs are combined; lone surrogates and a trailing odd byte become
 * U+FFFD. A single-byte payload is read as one code point, because some
 * producers write `<41>` instead of `<0041>`.
 */
public func utf16beToString(bytes: Array<UInt8>): String {
    utf16beToString(bytes, 0, bytes.size)
}

func utf16beToString(bytes: Array<UInt8>, offset: Int64, length: Int64): String {
    let out = ArrayList<UInt8>(length + 8)
    if (length == 1) {
        if (offset >= 0 && offset < bytes.size) {
            cmapAppendCodepoint(out, Int64(bytes[offset]))
        }
        return String.fromUtf8(out.toArray())
    }
    var i = offset
    let end = offset + length
    while (i + 1 < end) {
        let unit = (Int64(bytes[i]) << 8) | Int64(bytes[i + 1])
        i += 2
        if (unit >= 0xD800 && unit <= 0xDBFF) {
            if (i + 1 < end) {
                let second = (Int64(bytes[i]) << 8) | Int64(bytes[i + 1])
                if (second >= 0xDC00 && second <= 0xDFFF) {
                    i += 2
                    cmapAppendCodepoint(out, 0x10000 + ((unit - 0xD800) << 10) + (second - 0xDC00))
                    continue
                }
            }
            cmapAppendCodepoint(out, 0xFFFD)
        } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
            cmapAppendCodepoint(out, 0xFFFD)
        } else {
            cmapAppendCodepoint(out, unit)
        }
    }
    if (i < end) {
        cmapAppendCodepoint(out, 0xFFFD)
    }
    String.fromUtf8(out.toArray())
}

/** UTF-16BE bytes for one code point (surrogate pair when needed). */
private func cmapFromCodepoint(codepoint: Int64): String {
    var cp = codepoint
    if (cp < 0 || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) {
        cp = 0xFFFD
    }
    let out = ArrayList<UInt8>(4)
    if (cp < 0x10000) {
        out.add(UInt8((cp >> 8) & 0xFF))
        out.add(UInt8(cp & 0xFF))
    } else {
        let v = cp - 0x10000
        let high = 0xD800 + (v >> 10)
        let low = 0xDC00 + (v & 0x3FF)
        out.add(UInt8((high >> 8) & 0xFF))
        out.add(UInt8(high & 0xFF))
        out.add(UInt8((low >> 8) & 0xFF))
        out.add(UInt8(low & 0xFF))
    }
    utf16beToString(out.toArray())
}

/** First code point of a UTF-16BE destination, or None for a broken payload. */
private func cmapFirstCodepoint(bytes: Array<UInt8>): Option<Int64> {
    if (bytes.size == 0) {
        return None
    }
    if (bytes.size == 1) {
        return Some(Int64(bytes[0]))
    }
    if (bytes.size >= 4) {
        let high = (Int64(bytes[0]) << 8) | Int64(bytes[1])
        let low = (Int64(bytes[2]) << 8) | Int64(bytes[3])
        if (high >= 0xD800 && high <= 0xDBFF && low >= 0xDC00 && low <= 0xDFFF) {
            return Some(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00))
        }
    }
    let unit = (Int64(bytes[0]) << 8) | Int64(bytes[1])
    if (unit >= 0xD800 && unit <= 0xDFFF) {
        return None
    }
    Some(unit)
}

// ---------------------------------------------------------------------------
// Tokens

private enum CmapToken {
    | CmapHex(Array<UInt8>)
    | CmapName(String)
    | CmapNumber(Int64)
    | CmapArrayOpen
    | CmapArrayClose
    | CmapDictOpen
    | CmapDictClose
    | CmapKeyword(String)
    | CmapEnd
}

private func cmapLatin1(bytes: ArrayList<UInt8>): String {
    let out = ArrayList<UInt8>(bytes.size + 8)
    for (b in bytes) {
        if (b < 0x80) {
            out.add(b)
        } else {
            out.add(UInt8(0xC0 | (Int64(b) >> 6)))
            out.add(UInt8(0x80 | (Int64(b) & 0x3F)))
        }
    }
    String.fromUtf8(out.toArray())
}

private func cmapIsRegular(b: UInt8): Bool {
    !cmapIsWhitespace(b) && !cmapIsDelimiter(b)
}

/** Byte-level CMap tokenizer; `PdfError` on an unterminated string. */
private class CmapLexer {
    private let data: Array<UInt8>
    private var pos: Int64

    init(data: Array<UInt8>) {
        this.data = data
        this.pos = 0
    }

    func next(): CmapToken {
        skipSpace()
        if (pos >= data.size) {
            return CmapEnd
        }
        let b = data[pos]
        if (b == 0x3C) {
            if (pos + 1 < data.size && data[pos + 1] == 0x3C) {
                pos += 2
                return CmapDictOpen
            }
            return readHexString()
        }
        if (b == 0x3E) {
            if (pos + 1 < data.size && data[pos + 1] == 0x3E) {
                pos += 2
            } else {
                pos += 1
            }
            return CmapDictClose
        }
        if (b == 0x5B) {
            pos += 1
            return CmapArrayOpen
        }
        if (b == 0x5D) {
            pos += 1
            return CmapArrayClose
        }
        if (b == 0x2F) {
            pos += 1
            return CmapName(readRegular())
        }
        if (b == 0x28) {
            return readLiteralString()
        }
        if (b == 0x7B || b == 0x7D) {
            pos += 1
            return CmapKeyword(singleByteToString(b))
        }
        return readNumberOrKeyword()
    }

    private func singleByteToString(b: UInt8): String {
        let bytes = ArrayList<UInt8>(1)
        bytes.add(b)
        cmapLatin1(bytes)
    }

    private func skipSpace(): Unit {
        while (pos < data.size) {
            let b = data[pos]
            if (cmapIsWhitespace(b)) {
                pos += 1
            } else if (b == 0x25) {
                pos += 1
                while (pos < data.size && data[pos] != CMAP_LF && data[pos] != CMAP_CR) {
                    pos += 1
                }
            } else {
                break
            }
        }
    }

    private func readRegular(): String {
        let bytes = ArrayList<UInt8>()
        while (pos < data.size && cmapIsRegular(data[pos])) {
            bytes.add(data[pos])
            pos += 1
        }
        cmapLatin1(bytes)
    }

    private func readHexString(): CmapToken {
        pos += 1
        let out = ArrayList<UInt8>()
        var high: Int64 = -1
        while (pos < data.size) {
            let b = data[pos]
            if (b == 0x3E) {
                pos += 1
                if (high >= 0) {
                    out.add(UInt8(high << 4))
                }
                return CmapHex(out.toArray())
            }
            let digit = cmapHexValue(b)
            if (digit >= 0) {
                if (high < 0) {
                    high = digit
                } else {
                    out.add(UInt8((high << 4) | digit))
                    high = -1
                }
            }
            pos += 1
        }
        throw PdfError("unterminated hex string in CMap")
    }

    private func readLiteralString(): CmapToken {
        pos += 1
        let out = ArrayList<UInt8>()
        var depth: Int64 = 1
        while (pos < data.size) {
            let b = data[pos]
            pos += 1
            if (b == 0x5C) {
                if (pos >= data.size) {
                    break
                }
                let escaped = data[pos]
                pos += 1
                match (escaped) {
                    case 0x6E => out.add(CMAP_LF)
                    case 0x72 => out.add(CMAP_CR)
                    case 0x74 => out.add(CMAP_TAB)
                    case 0x62 => out.add(8)
                    case 0x66 => out.add(CMAP_FF)
                    case 0x28 => out.add(0x28)
                    case 0x29 => out.add(0x29)
                    case 0x5C => out.add(0x5C)
                    case 0x0A => ()
                    case 0x0D => ()
                    case _ =>
                        let octal = cmapOctalValue(escaped)
                        if (octal >= 0) {
                            var value = octal
                            var count: Int64 = 1
                            while (count < 3 && pos < data.size) {
                                let next = cmapOctalValue(data[pos])
                                if (next < 0) {
                                    break
                                }
                                value = value * 8 + next
                                pos += 1
                                count += 1
                            }
                            out.add(UInt8(value & 0xFF))
                        } else {
                            out.add(escaped)
                        }
                }
            } else if (b == 0x28) {
                depth += 1
                out.add(b)
            } else if (b == 0x29) {
                depth -= 1
                if (depth == 0) {
                    return CmapHex(out.toArray())
                }
                out.add(b)
            } else {
                out.add(b)
            }
        }
        throw PdfError("unterminated literal string in CMap")
    }

    private func readNumberOrKeyword(): CmapToken {
        let b = data[pos]
        let signed = b == 0x2B || b == 0x2D
        let digit = b >= 0x30 && b <= 0x39
        if (!signed && !digit) {
            return CmapKeyword(readRegular())
        }
        var negative = false
        if (signed) {
            negative = b == 0x2D
            pos += 1
        }
        var value: Int64 = 0
        var sawDigit = false
        while (pos < data.size) {
            let c = data[pos]
            if (c >= 0x30 && c <= 0x39) {
                value = value * 10 + Int64(c - 0x30)
                sawDigit = true
                pos += 1
            } else if (c == 0x2E) {
                pos += 1
                while (pos < data.size && data[pos] >= 0x30 && data[pos] <= 0x39) {
                    pos += 1
                }
                break
            } else {
                break
            }
        }
        if (!sawDigit) {
            return CmapKeyword(readRegular())
        }
        if (negative) {
            return CmapNumber(-value)
        }
        CmapNumber(value)
    }
}

// ---------------------------------------------------------------------------
// The CMap itself

/**
 * Parsed CMap: Unicode mappings, CID mappings and the code-space ranges.
 *
 * Instances are built by [parseToUnicode]; the `add*` members are package
 * internal and exist only for that parser.
 */
public class ToUnicodeCMap {
    private let unicodeMap: HashMap<Int64, String>
    private let cidMap: HashMap<Int64, Int64>
    private let spaceLength: ArrayList<Int64>
    private let spaceLow: ArrayList<Int64>
    private let spaceHigh: ArrayList<Int64>
    private let matchLengths: ArrayList<Int64>

    init() {
        unicodeMap = HashMap<Int64, String>()
        cidMap = HashMap<Int64, Int64>()
        spaceLength = ArrayList<Int64>()
        spaceLow = ArrayList<Int64>()
        spaceHigh = ArrayList<Int64>()
        matchLengths = ArrayList<Int64>()
    }

    /** Unicode text for a character code; None when the CMap has no entry. */
    public func lookup(code: Int64): Option<String> {
        unicodeMap.get(code)
    }

    /** CID for a character code (embedded encoding CMaps only). */
    public func lookupCid(code: Int64): Option<Int64> {
        cidMap.get(code)
    }

    /** Number of mapped character codes (diagnostics/tests). */
    public prop mappedCount: Int64 {
        get() {
            unicodeMap.size
        }
    }

    /** Whether the CMap declared at least one `begincodespacerange`. */
    public prop hasCodespaces: Bool {
        get() {
            !spaceLength.isEmpty()
        }
    }

    /**
     * Byte length of the character code starting at `offset`.
     *
     * Ranges are tried longest-first ("longest match"). `0` means "not
     * determined": either there is no codespace section, or the remaining bytes
     * cannot satisfy any range, and the caller applies its own default.
     */
    public func codeByteLength(bytes: Array<UInt8>, offset: Int64): Int64 {
        if (offset < 0 || offset >= bytes.size || spaceLength.isEmpty()) {
            return 0
        }
        for (i in 0..matchLengths.size) {
            let length = matchLengths[i]
            if (offset + length > bytes.size) {
                continue
            }
            let value = cmapBigEndian(bytes, offset, length)
            for (r in 0..spaceLength.size) {
                if (spaceLength[r] == length && value >= spaceLow[r] && value <= spaceHigh[r]) {
                    return length
                }
            }
        }
        let shortest = matchLengths[matchLengths.size - 1]
        if (offset + shortest <= bytes.size) {
            return shortest
        }
        0
    }

    /** Shortest declared code-space length, or 0 when there is none. */
    public func defaultByteLength(): Int64 {
        if (matchLengths.isEmpty()) {
            return 0
        }
        matchLengths[matchLengths.size - 1]
    }

    func addCodeSpace(length: Int64, low: Int64, high: Int64): Unit {
        spaceLength.add(length)
        spaceLow.add(low)
        spaceHigh.add(high)
    }

    func addUnicode(code: Int64, text: String): Unit {
        if (unicodeMap.size >= CMAP_MAX_MAPPINGS) {
            return
        }
        unicodeMap.add(code, text)
    }

    func addCid(code: Int64, cid: Int64): Unit {
        if (cidMap.size >= CMAP_MAX_MAPPINGS) {
            return
        }
        cidMap.add(code, cid)
    }

    /** Fill the descending, de-duplicated length table used by `codeByteLength`. */
    func finish(): Unit {
        let seen = HashSet<Int64>()
        for (length in spaceLength) {
            if (!seen.contains(length)) {
                seen.add(length)
                matchLengths.add(length)
            }
        }
        // Insertion sort, descending: at most four entries in practice.
        for (i in 1..matchLengths.size) {
            let current = matchLengths[i]
            var j = i - 1
            while (j >= 0 && matchLengths[j] < current) {
                matchLengths[j + 1] = matchLengths[j]
                j -= 1
            }
            matchLengths[j + 1] = current
        }
    }
}

// ---------------------------------------------------------------------------
// Parsing

/**
 * Parse a CMap, typically a `/ToUnicode` stream.
 *
 * Failure (an unterminated hex or literal string) raises `PdfError`. Unknown
 * keywords are ignored, because a real-world CMap carries plenty of
 * PostScript noise (`def`, `usecmap`, `/CIDSystemInfo`, ...).
 */
public func parseToUnicode(bytes: Array<UInt8>): ToUnicodeCMap {
    let cmap = ToUnicodeCMap()
    let lexer = CmapLexer(bytes)
    var done = false
    while (!done) {
        let token = lexer.next()
        match (token) {
            case CmapEnd => done = true
            case CmapKeyword(word) =>
                if (word == "begincodespacerange") {
                    readCodeSpaces(lexer, cmap)
                } else if (word == "beginbfchar") {
                    readBfChars(lexer, cmap)
                } else if (word == "beginbfrange") {
                    readBfRanges(lexer, cmap)
                } else if (word == "begincidchar") {
                    readCidChars(lexer, cmap)
                } else if (word == "begincidrange") {
                    readCidRanges(lexer, cmap)
                }
            case _ => ()
        }
    }
    cmap.finish()
    cmap
}

private func readCodeSpaces(lexer: CmapLexer, cmap: ToUnicodeCMap): Unit {
    var low: Option<Array<UInt8>> = None
    while (true) {
        let token = lexer.next()
        match (token) {
            case CmapEnd => return
            case CmapKeyword(word) =>
                if (word == "endcodespacerange") {
                    return
                }
            case CmapHex(bytes) =>
                match (low) {
                    case None => low = Some(bytes)
                    case Some(first) =>
                        low = None
                        if (first.size == bytes.size && first.size >= 1 && first.size <= 4) {
                            let lowValue = cmapBigEndian(first, 0, first.size)
                            let highValue = cmapBigEndian(bytes, 0, bytes.size)
                            if (lowValue <= highValue) {
                                cmap.addCodeSpace(first.size, lowValue, highValue)
                            }
                        }
                }
            case _ => ()
        }
    }
}

private func readBfChars(lexer: CmapLexer, cmap: ToUnicodeCMap): Unit {
    var source: Option<Array<UInt8>> = None
    while (true) {
        let token = lexer.next()
        match (token) {
            case CmapEnd => return
            case CmapKeyword(word) =>
                if (word == "endbfchar") {
                    return
                }
            case CmapHex(bytes) =>
                match (source) {
                    case None => source = Some(bytes)
                    case Some(src) =>
                        source = None
                        cmap.addUnicode(cmapBigEndian(src, 0, src.size), utf16beToString(bytes))
                }
            case CmapName(glyph) =>
                match (source) {
                    case None => ()
                    case Some(src) =>
                        source = None
                        match (glyphNameToUnicode(glyph)) {
                            case Some(text) => cmap.addUnicode(cmapBigEndian(src, 0, src.size), text)
                            case None => ()
                        }
                }
            case _ => ()
        }
    }
}

private func readBfRanges(lexer: CmapLexer, cmap: ToUnicodeCMap): Unit {
    var low: Option<Array<UInt8>> = None
    var high: Option<Array<UInt8>> = None
    while (true) {
        let token = lexer.next()
        match (token) {
            case CmapEnd => return
            case CmapKeyword(word) =>
                if (word == "endbfrange") {
                    return
                }
            case CmapHex(bytes) =>
                match (low) {
                    case None => low = Some(bytes)
                    case Some(first) =>
                        match (high) {
                            case None => high = Some(bytes)
                            case Some(last) =>
                                low = None
                                high = None
                                addIncrementalRange(cmap, first, last, bytes)
                        }
                }
            case CmapArrayOpen =>
                match (low) {
                    case None => ()
                    case Some(first) =>
                        match (high) {
                            case None => ()
                            case Some(last) =>
                                low = None
                                high = None
                                readRangeArray(lexer, cmap, first, last)
                        }
                }
            case _ => ()
        }
    }
}

/** `<lo> <hi> [<d1> <d2> ...]`: one destination per code. */
private func readRangeArray(
    lexer: CmapLexer,
    cmap: ToUnicodeCMap,
    low: Array<UInt8>,
    high: Array<UInt8>
): Unit {
    let start = cmapBigEndian(low, 0, low.size)
    let last = cmapBigEndian(high, 0, high.size)
    if (last < start) {
        return
    }
    var index: Int64 = 0
    while (true) {
        let token = lexer.next()
        match (token) {
            case CmapEnd => return
            case CmapArrayClose => return
            case CmapHex(bytes) =>
                if (start + index <= last) {
                    cmap.addUnicode(start + index, utf16beToString(bytes))
                }
                index += 1
            case CmapName(glyph) =>
                if (start + index <= last) {
                    match (glyphNameToUnicode(glyph)) {
                        case Some(text) => cmap.addUnicode(start + index, text)
                        case None => ()
                    }
                }
                index += 1
            case _ => ()
        }
    }
}

/** `<lo> <hi> <dst>`: the destination code point increments across the range. */
private func addIncrementalRange(
    cmap: ToUnicodeCMap,
    low: Array<UInt8>,
    high: Array<UInt8>,
    destination: Array<UInt8>
): Unit {
    if (low.size == 0 || high.size == 0) {
        return
    }
    let first = cmapBigEndian(low, 0, low.size)
    let last = cmapBigEndian(high, 0, high.size)
    if (last < first) {
        return
    }
    let count = last - first + 1
    if (count > 65536) {
        return
    }
    var startCode: Int64 = -1
    match (cmapFirstCodepoint(destination)) {
        case Some(value) => startCode = value
        case None => return
    }
    if (startCode < 0) {
        return
    }
    var i: Int64 = 0
    while (i < count) {
        let codepoint = startCode + i
        if (codepoint > 0x10FFFF) {
            return
        }
        cmap.addUnicode(first + i, cmapFromCodepoint(codepoint))
        i += 1
    }
}

private func readCidChars(lexer: CmapLexer, cmap: ToUnicodeCMap): Unit {
    var source: Option<Array<UInt8>> = None
    while (true) {
        let token = lexer.next()
        match (token) {
            case CmapEnd => return
            case CmapKeyword(word) =>
                if (word == "endcidchar") {
                    return
                }
            case CmapHex(bytes) => source = Some(bytes)
            case CmapNumber(cid) =>
                match (source) {
                    case Some(src) =>
                        source = None
                        if (cid >= 0) {
                            cmap.addCid(cmapBigEndian(src, 0, src.size), cid)
                        }
                    case None => ()
                }
            case _ => ()
        }
    }
}

private func readCidRanges(lexer: CmapLexer, cmap: ToUnicodeCMap): Unit {
    var low: Option<Array<UInt8>> = None
    var high: Option<Array<UInt8>> = None
    while (true) {
        let token = lexer.next()
        match (token) {
            case CmapEnd => return
            case CmapKeyword(word) =>
                if (word == "endcidrange") {
                    return
                }
            case CmapHex(bytes) =>
                match (low) {
                    case None => low = Some(bytes)
                    case Some(_) =>
                        match (high) {
                            case None => high = Some(bytes)
                            case Some(_) => ()
                        }
                }
            case CmapNumber(cid) =>
                match (low) {
                    case Some(firstBytes) =>
                        match (high) {
                            case Some(lastBytes) =>
                                let first = cmapBigEndian(firstBytes, 0, firstBytes.size)
                                let last = cmapBigEndian(lastBytes, 0, lastBytes.size)
                                if (cid >= 0 && last >= first && last - first < 65536) {
                                    var i: Int64 = 0
                                    while (i <= last - first) {
                                        cmap.addCid(first + i, cid + i)
                                        i += 1
                                    }
                                }
                            case None => ()
                        }
                    case None => ()
                }
                low = None
                high = None
            case _ => ()
        }
    }
}
