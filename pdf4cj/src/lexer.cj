package pdf4cj

import std.collection.*
import std.convert.*

/**
 * Byte-level PDF lexer and value reader.
 *
 * The lexer owns a byte array and a cursor. `parseValue` reads one complete
 * PDF value (including nested arrays/dictionaries and `n g R` references), so
 * the same code drives three callers:
 *
 * - `PdfObjectParser`, when it reads an indirect object from the file;
 * - the object-stream reader, over the decoded `/ObjStm` payload;
 * - the xref-stream reader, over the decoded `/XRef` payload (via the parser).
 *
 * Failure is always reported as a `PdfError` with a byte offset, never as an
 * empty exception.
 */

private let CH_NUL: UInt8 = 0
private let CH_TAB: UInt8 = 9
private let CH_LF: UInt8 = 10
private let CH_FF: UInt8 = 12
private let CH_CR: UInt8 = 13
private let CH_SPACE: UInt8 = 32

func isPdfWhitespace(b: UInt8): Bool {
    b == CH_NUL || b == CH_TAB || b == CH_LF || b == CH_FF || b == CH_CR || b == CH_SPACE
}

func isPdfDelimiter(b: UInt8): Bool {
    match (b) {
        case 40 | 41 | 60 | 62 | 91 | 93 | 123 | 125 | 47 | 37 => true
        case _ => false
    }
}

func isPdfRegular(b: UInt8): Bool {
    !isPdfWhitespace(b) && !isPdfDelimiter(b)
}

private func hexValue(b: UInt8): Int64 {
    if (b >= 48 && b <= 57) {
        return Int64(b - 48)
    }
    if (b >= 65 && b <= 70) {
        return Int64(b - 55)
    }
    if (b >= 97 && b <= 102) {
        return Int64(b - 87)
    }
    -1
}

private func asciiString(bytes: ArrayList<UInt8>): String {
    String.fromUtf8(bytes.toArray())
}

/**
 * Decode arbitrary name/string bytes as Latin-1 into a UTF-8 Cangjie `String`.
 *
 * PDF names are byte strings, not UTF-8. Mapping each byte to the code point
 * of the same value keeps ASCII intact (the normal case) and is lossless for
 * the rest instead of failing `String.fromUtf8` on invalid sequences.
 */
private func latin1ToString(bytes: Array<UInt8>): String {
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

public class PdfLexer {
    public let data: Array<UInt8>
    public var pos: Int64

    public init(data: Array<UInt8>, pos!: Int64 = 0) {
        this.data = data
        this.pos = pos
    }

    public func size(): Int64 {
        data.size
    }

    public func eof(): Bool {
        pos >= data.size
    }

    public func position(): Int64 {
        pos
    }

    public func setPosition(value: Int64): Unit {
        pos = value
    }

    /** Current byte as `0..255`, or `-1` at end of input. */
    public func peek(): Int64 {
        if (pos >= data.size) {
            return -1
        }
        Int64(data[pos])
    }

    public func peekAt(offset: Int64): Int64 {
        let index = pos + offset
        if (index < 0 || index >= data.size) {
            return -1
        }
        Int64(data[index])
    }

    public func advance(): Unit {
        if (pos < data.size) {
            pos += 1
        }
    }

    /** Skip whitespace and `%` comments (a comment runs to the next EOL). */
    public func skipWhitespace(): Unit {
        while (pos < data.size) {
            let b = data[pos]
            if (isPdfWhitespace(b)) {
                pos += 1
            } else if (b == 37) {
                pos += 1
                while (pos < data.size) {
                    let c = data[pos]
                    if (c == CH_LF || c == CH_CR) {
                        break
                    }
                    pos += 1
                }
            } else {
                break
            }
        }
    }

    private func readRegularToken(): String {
        let bytes = ArrayList<UInt8>()
        while (pos < data.size && isPdfRegular(data[pos])) {
            bytes.add(data[pos])
            pos += 1
        }
        asciiString(bytes)
    }

    public func peekKeyword(keyword: String): Bool {
        let saved = pos
        skipWhitespace()
        let result = matchKeywordOnly(keyword)
        pos = saved
        result
    }

    private func matchKeywordOnly(keyword: String): Bool {
        if (pos + keyword.size > data.size) {
            return false
        }
        let keyBytes = keyword.toArray()
        for (i in 0..keyBytes.size) {
            if (data[pos + i] != keyBytes[i]) {
                return false
            }
        }
        let after = pos + keyword.size
        if (after < data.size) {
            let b = data[after]
            if (!isPdfWhitespace(b) && !isPdfDelimiter(b)) {
                return false
            }
        }
        pos = after
        true
    }

    /** Skip whitespace, then consume `keyword` if it is the next token. */
    public func matchKeyword(keyword: String): Bool {
        skipWhitespace()
        matchKeywordOnly(keyword)
    }

    public func requireKeyword(keyword: String, context: String): Unit {
        if (!matchKeyword(keyword)) {
            throw PdfError("${context}: expected '${keyword}' at byte ${pos}")
        }
    }

    /**
     * Read a bare keyword token (for example `obj`, `stream`, `R`).
     * Returns `None` when the next byte does not start a regular-char token.
     */
    public func readKeywordToken(): Option<String> {
        skipWhitespace()
        if (eof() || !isPdfRegular(data[pos])) {
            return None
        }
        Some(readRegularToken())
    }

    /** Scan a number token: sign, digits, at most one decimal point. */
    private func scanNumberToken(): String {
        let start = pos
        if (pos < data.size && (data[pos] == 43 || data[pos] == 45)) {
            pos += 1
        }
        var digits = false
        while (pos < data.size && data[pos] >= 48 && data[pos] <= 57) {
            digits = true
            pos += 1
        }
        if (pos < data.size && data[pos] == 46) {
            pos += 1
            while (pos < data.size && data[pos] >= 48 && data[pos] <= 57) {
                digits = true
                pos += 1
            }
        }
        if (!digits) {
            throw PdfError("invalid number at byte ${start}")
        }
        String.fromUtf8(data[start..pos].toArray())
    }

    private func scanIntegerToken(): Option<Int64> {
        skipWhitespace()
        if (eof() || !isPdfRegular(data[pos])) {
            return None
        }
        let start = pos
        var negative = false
        if (data[pos] == 43 || data[pos] == 45) {
            negative = data[pos] == 45
            pos += 1
        }
        let digitStart = pos
        while (pos < data.size && data[pos] >= 48 && data[pos] <= 57) {
            pos += 1
        }
        if (pos == digitStart) {
            pos = start
            return None
        }
        let digits = String.fromUtf8(data[digitStart..pos].toArray())
        let value = match (Int64.tryParse(digits)) {
            case Some(n) => n
            case None =>
                pos = start
                return None
        }
        if (negative) {
            return Some(-value)
        }
        Some(value)
    }

    private func parseRealToken(token: String): Float64 {
        // Decimal PDF numbers only; no exponent syntax in the spec.
        var index = 0
        let bytes = token.toArray()
        var negative = false
        if (index < bytes.size && (bytes[index] == 43 || bytes[index] == 45)) {
            negative = bytes[index] == 45
            index += 1
        }
        var value: Float64 = 0.0
        while (index < bytes.size && bytes[index] != 46) {
            value = value * 10.0 + Float64(Int64(bytes[index] - 48))
            index += 1
        }
        if (index < bytes.size && bytes[index] == 46) {
            index += 1
            var scale: Float64 = 0.1
            while (index < bytes.size) {
                value = value + Float64(Int64(bytes[index] - 48)) * scale
                scale = scale / 10.0
                index += 1
            }
        }
        if (negative) {
            -value
        } else {
            value
        }
    }

    private func parseNumberOrRef(): PdfValue {
        let token = scanNumberToken()
        if (token.contains(".")) {
            return PdfValue.PdfReal(parseRealToken(token))
        }
        let intValue = match (Int64.tryParse(token)) {
            case Some(n) => n
            case None => return PdfValue.PdfReal(parseRealToken(token))
        }
        if (intValue < 0) {
            return PdfValue.PdfInt(intValue)
        }
        // Lookahead for an indirect reference: `num gen R`.
        let afterFirst = pos
        let genValue = scanIntegerToken()
        match (genValue) {
            case Some(gen) =>
                if (gen >= 0) {
                    skipWhitespace()
                    if (matchKeywordOnly("R")) {
                        return PdfValue.PdfRef(intValue, gen)
                    }
                }
            case None => ()
        }
        pos = afterFirst
        PdfValue.PdfInt(intValue)
    }

    /**
     * Parse one complete value. The caller is responsible for any syntactic
     * context (dictionary key, top-level object, `endobj`, ...).
     */
    public func parseValue(): PdfValue {
        skipWhitespace()
        if (eof()) {
            throw PdfError("unexpected end of input while reading a PDF value")
        }
        let b = data[pos]
        if (b == 47) {
            return PdfValue.PdfName(parseName())
        }
        if (b == 40) {
            return PdfValue.PdfString(parseLiteralString())
        }
        if (b == 60) {
            if (peekAt(1) == 60) {
                return PdfValue.PdfDict(parseDictionary())
            }
            return PdfValue.PdfString(parseHexString())
        }
        if (b == 91) {
            return PdfValue.PdfArray(parseArray())
        }
        if (b == 93 || b == 62 || b == 123 || b == 125) {
            throw PdfError("unexpected '${charAt(b)}' at byte ${pos}")
        }
        if ((b >= 48 && b <= 57) || b == 43 || b == 45 || b == 46) {
            return parseNumberOrRef()
        }
        if (isPdfRegular(b)) {
            let start = pos
            let word = readRegularToken()
            match (word) {
                case "true" => return PdfValue.PdfBool(true)
                case "false" => return PdfValue.PdfBool(false)
                case "null" => return PdfValue.PdfNull
                case _ => throw PdfError("unexpected keyword '${word}' at byte ${start}")
            }
        }
        throw PdfError("unexpected byte ${b} at byte ${pos}")
    }

    private func charAt(b: UInt8): String {
        latin1ToString([b])
    }

    /** Parse a name after consuming `/`; `#xx` escapes are decoded. */
    public func parseName(): String {
        skipWhitespace()
        if (eof() || data[pos] != 47) {
            throw PdfError("expected a name at byte ${pos}")
        }
        pos += 1
        let bytes = ArrayList<UInt8>()
        while (pos < data.size) {
            let b = data[pos]
            if (!isPdfRegular(b)) {
                break
            }
            if (b == 35) {
                let hi = if (pos + 1 < data.size) { hexValue(data[pos + 1]) } else { -1 }
                let lo = if (pos + 2 < data.size) { hexValue(data[pos + 2]) } else { -1 }
                if (hi >= 0 && lo >= 0) {
                    bytes.add(UInt8(hi * 16 + lo))
                    pos += 3
                    continue
                }
            }
            bytes.add(b)
            pos += 1
        }
        latin1ToString(bytes.toArray())
    }

    /** Parse a literal string after seeing `(`; returns the raw bytes. */
    public func parseLiteralString(): Array<UInt8> {
        if (eof() || data[pos] != 40) {
            throw PdfError("expected '(' at byte ${pos}")
        }
        pos += 1
        let out = ArrayList<UInt8>()
        var depth = 1
        while (pos < data.size) {
            let b = data[pos]
            if (b == 92) {
                pos += 1
                if (pos >= data.size) {
                    break
                }
                let esc = data[pos]
                match (esc) {
                    case 110 => out.add(10)
                    case 114 => out.add(13)
                    case 116 => out.add(9)
                    case 98 => out.add(8)
                    case 102 => out.add(12)
                    case 40 => out.add(40)
                    case 41 => out.add(41)
                    case 92 => out.add(92)
                    case 10 =>
                        pos += 1
                        continue
                    case 13 =>
                        pos += 1
                        if (pos < data.size && data[pos] == 10) {
                            pos += 1
                        }
                        continue
                    case 48 | 49 | 50 | 51 | 52 | 53 | 54 | 55 =>
                        var value: Int64 = 0
                        var count = 0
                        while (count < 3 && pos < data.size && data[pos] >= 48 && data[pos] <= 55) {
                            value = value * 8 + Int64(data[pos] - 48)
                            pos += 1
                            count += 1
                        }
                        out.add(UInt8(value & 0xFF))
                        continue
                    case _ => out.add(esc)
                }
                pos += 1
                continue
            }
            if (b == 40) {
                depth += 1
                out.add(b)
                pos += 1
                continue
            }
            if (b == 41) {
                depth -= 1
                pos += 1
                if (depth == 0) {
                    return out.toArray()
                }
                out.add(b)
                continue
            }
            if (b == CH_CR) {
                pos += 1
                if (pos < data.size && data[pos] == CH_LF) {
                    pos += 1
                }
                out.add(CH_LF)
                continue
            }
            out.add(b)
            pos += 1
        }
        throw PdfError("unterminated literal string (started before byte ${pos})")
    }

    /** Parse a hex string after seeing `<`; odd digit counts are zero padded. */
    public func parseHexString(): Array<UInt8> {
        if (eof() || data[pos] != 60) {
            throw PdfError("expected '<' at byte ${pos}")
        }
        pos += 1
        let out = ArrayList<UInt8>()
        var high: Int64 = -1
        while (pos < data.size) {
            let b = data[pos]
            if (b == 62) {
                pos += 1
                if (high >= 0) {
                    out.add(UInt8(high * 16))
                }
                return out.toArray()
            }
            if (isPdfWhitespace(b)) {
                pos += 1
                continue
            }
            let nibble = hexValue(b)
            if (nibble < 0) {
                throw PdfError("invalid hex digit '${charAt(b)}' at byte ${pos}")
            }
            if (high < 0) {
                high = nibble
            } else {
                out.add(UInt8(high * 16 + nibble))
                high = -1
            }
            pos += 1
        }
        throw PdfError("unterminated hex string (started before byte ${pos})")
    }

    /** Parse an array after seeing `[`. */
    public func parseArray(): ArrayList<PdfValue> {
        if (eof() || data[pos] != 91) {
            throw PdfError("expected '[' at byte ${pos}")
        }
        pos += 1
        let items = ArrayList<PdfValue>()
        while (true) {
            skipWhitespace()
            if (eof()) {
                throw PdfError("unterminated array (started before byte ${pos})")
            }
            if (data[pos] == 93) {
                pos += 1
                return items
            }
            items.add(parseValue())
        }
        items
    }

    /** Parse a dictionary after seeing `<<`. */
    public func parseDictionary(): HashMap<String, PdfValue> {
        if (eof() || data[pos] != 60 || peekAt(1) != 60) {
            throw PdfError("expected '<<' at byte ${pos}")
        }
        pos += 2
        let entries = HashMap<String, PdfValue>()
        while (true) {
            skipWhitespace()
            if (eof()) {
                throw PdfError("unterminated dictionary (started before byte ${pos})")
            }
            if (data[pos] == 62 && peekAt(1) == 62) {
                pos += 2
                return entries
            }
            if (data[pos] != 47) {
                throw PdfError("dictionary key must be a name at byte ${pos}")
            }
            let key = parseName()
            skipWhitespace()
            if (!eof() && data[pos] == 62 && peekAt(1) == 62) {
                // Tolerate a trailing key with no value in the wild.
                entries.add(key, PdfValue.PdfNull)
                continue
            }
            entries.add(key, parseValue())
        }
        entries
    }
}
