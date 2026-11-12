package pdf_inspector_mcp.pdf

import std.collection.*
import std.io.*
import stdx.compress.zlib.*

/**
 * PDF stream filter chain.
 *
 * Supported decoders: FlateDecode (zlib-wrapped or raw deflate), LZWDecode,
 * ASCIIHexDecode, ASCII85Decode and RunLengthDecode, plus the PNG/TIFF
 * predictors (`/Predictor 2` and `10..15`).
 *
 * Image codecs (`/DCTDecode`, `/JPXDecode`, `/JBIG2Decode`,
 * `/CCITTFaxDecode`) and `/Crypt` are passed through unchanged on purpose: the
 * image layer needs the original payload to pick a file format / hand it back
 * via `pdf_get_image`, and failing on them here would lose the whole page.
 *
 * Unknown filter names are also passed through unchanged. That is a deliberate
 * soft-fail: a page with one exotic filter should still expose its other
 * content instead of failing entirely. Callers that care can inspect
 * `/Filter` themselves.
 */

private let MAX_DECODED_BYTES: Int64 = 256 * 1024 * 1024

private func readU8(data: Array<UInt8>, index: Int64): Int64 {
    if (index < 0 || index >= data.size) {
        -1
    } else {
        Int64(data[index])
    }
}

private func appendAll(out: ArrayList<UInt8>, bytes: Array<UInt8>): Unit {
    if (out.size + bytes.size > MAX_DECODED_BYTES) {
        throw PdfError("decoded stream exceeds the safety limit of ${MAX_DECODED_BYTES} bytes")
    }
    for (b in bytes) {
        out.add(b)
    }
}

/** `/Filter` may be one name or an array of names; missing means "no filter". */
public func filterNames(value: PdfValue): ArrayList<String> {
    let names = ArrayList<String>()
    match (value) {
        case PdfValue.PdfName(name) => names.add(name)
        case PdfValue.PdfArray(items) =>
            for (item in items) {
                match (item) {
                    case PdfValue.PdfName(name) => names.add(name)
                    case _ => ()
                }
            }
        case _ => ()
    }
    names
}

private func parmsAt(parms: PdfValue, index: Int64): Option<HashMap<String, PdfValue>> {
    match (parms) {
        case PdfValue.PdfDict(entries) => Some(entries)
        case PdfValue.PdfArray(items) =>
            if (index >= 0 && index < items.size) {
                match (items[index]) {
                    case PdfValue.PdfDict(entries) => Some(entries)
                    case _ => None
                }
            } else {
                None
            }
        case _ => None
    }
}

private func getInt(dict: Option<HashMap<String, PdfValue>>, key: String, fallback: Int64): Int64 {
    match (dict) {
        case Some(entries) =>
            match (entries.get(key)) {
                case Some(PdfValue.PdfInt(n)) => n
                case Some(PdfValue.PdfReal(f)) => Int64(f)
                case _ => fallback
            }
        case None => fallback
    }
}

/**
 * Decode `stream.raw` through its `/Filter` chain, memoising the result on the
 * stream object so each stream is decoded at most once per document.
 *
 * The parser resolves `/Filter` and `/DecodeParms` before calling this, so
 * indirect values (rare but legal) work here too.
 */
public func decodeStreamData(stream: PdfStream): Array<UInt8> {
    match (stream.decoded) {
        case Some(bytes) => return bytes
        case None => ()
    }
    let filter = match (stream.dict.get("Filter")) {
        case Some(v) => v
        case None => PdfValue.PdfNull
    }
    let parms = match (stream.dict.get("DecodeParms")) {
        case Some(v) => v
        case None => PdfValue.PdfNull
    }
    let decoded = decodeBytes(stream.raw, filter, parms)
    // If /Filter or /DecodeParms is indirect we cannot resolve it here (this
    // function has no document); leave the cache empty so the parser's
    // `decodeResolved` path can compute the real bytes.
    if (!containsIndirectRef(filter) && !containsIndirectRef(parms)) {
        stream.decoded = Some(decoded)
    }
    decoded
}

private func containsIndirectRef(value: PdfValue): Bool {
    match (value) {
        case PdfValue.PdfRef(_, _) => true
        case PdfValue.PdfArray(items) =>
            for (item in items) {
                if (containsIndirectRef(item)) {
                    return true
                }
            }
            false
        case _ => false
    }
}

/** Decode `raw` through one filter value plus its (optional) decode parameters. */
public func decodeBytes(raw: Array<UInt8>, filterValue: PdfValue, parmsValue: PdfValue): Array<UInt8> {
    let names = filterNames(filterValue)
    if (names.isEmpty()) {
        return raw
    }
    var data = raw
    for (i in 0..names.size) {
        data = applyFilter(data, names[i], parmsAt(parmsValue, i))
    }
    data
}

private func applyFilter(data: Array<UInt8>, name: String, parms: Option<HashMap<String, PdfValue>>): Array<UInt8> {
    match (name) {
        case "FlateDecode" | "Fl" => inflateWithPredictor(data, parms)
        case "LZWDecode" | "LZW" => lzwWithPredictor(data, parms)
        case "ASCIIHexDecode" | "AHx" => asciiHexDecode(data)
        case "ASCII85Decode" | "A85" => ascii85Decode(data)
        case "RunLengthDecode" | "RL" => runLengthDecode(data)
        case "DCTDecode" | "JPXDecode" | "JBIG2Decode" | "CCITTFaxDecode" | "CCF" | "DCT" | "Crypt" => data
        case _ => data
    }
}

// ---------------------------------------------------------------------------
// Flate

private func inflateRaw(data: Array<UInt8>, wrap: WrapType): Array<UInt8> {
    if (data.size == 0) {
        return Array<UInt8>()
    }
    let input = ByteBuffer(data)
    let stream = DecompressInputStream(input, wrap: wrap)
    let out = ArrayList<UInt8>()
    let buf = Array<UInt8>(16384, repeat: 0)
    try {
        while (true) {
            let n = stream.read(buf)
            if (n <= 0) {
                break
            }
            if (out.size + n > MAX_DECODED_BYTES) {
                throw PdfError("decoded stream exceeds the safety limit of ${MAX_DECODED_BYTES} bytes")
            }
            for (i in 0..n) {
                out.add(buf[i])
            }
        }
    } finally {
        stream.close()
    }
    out.toArray()
}

private func inflateWithPredictor(data: Array<UInt8>, parms: Option<HashMap<String, PdfValue>>): Array<UInt8> {
    if (data.size == 0) {
        return data
    }
    var decoded = try {
        inflateRaw(data, WrapType.DeflateFormat)
    } catch (e: Exception) {
        // PDF files in the wild carry zlib-wrapped streams (the common case)
        // and occasionally raw deflate. The stdx decoder only understands raw
        // deflate, so strip the 2-byte zlib header and retry, then try gzip.
        let first = readU8(data, 0)
        let second = readU8(data, 1)
        // zlib header: CMF low nibble 8 (deflate) and (CMF<<8|FLG) % 31 == 0.
        let isZlib = data.size > 2 && (first & 0x0F) == 8 && ((first << 8) + second) % 31 == 0
        if (first == 0x1F && second == 0x8B) {
            inflateRaw(data, WrapType.GzipFormat)
        } else if (isZlib) {
            inflateRaw(data[2..data.size].toArray(), WrapType.DeflateFormat)
        } else {
            throw e
        }
    }
    applyPredictor(decoded, parms)
}

// ---------------------------------------------------------------------------
// Predictors

private func applyPredictor(data: Array<UInt8>, parms: Option<HashMap<String, PdfValue>>): Array<UInt8> {
    let predictor = getInt(parms, "Predictor", 1)
    if (predictor <= 1) {
        return data
    }
    if (predictor == 2) {
        return tiffPredictor(data, parms)
    }
    if (predictor >= 10 && predictor <= 15) {
        return pngPredictor(data, parms)
    }
    data
}

private func tiffPredictor(data: Array<UInt8>, parms: Option<HashMap<String, PdfValue>>): Array<UInt8> {
    let colors = getInt(parms, "Colors", 1)
    let bits = getInt(parms, "BitsPerComponent", 8)
    let columns = getInt(parms, "Columns", 1)
    if (bits != 8 || colors <= 0 || columns <= 0) {
        // TIFF predictor 2 is only defined for 8-bit components here; leave
        // the payload untouched rather than corrupting it.
        return data
    }
    let rowLength = columns * colors
    let out = data.clone()
    var rowStart: Int64 = 0
    while (rowStart + rowLength <= out.size) {
        for (i in 1..rowLength) {
            let index = rowStart + i
            out[index] = UInt8((Int64(out[index]) + Int64(out[index - colors])) & 0xFF)
        }
        rowStart += rowLength
    }
    out
}

private func paeth(a: Int64, b: Int64, c: Int64): Int64 {
    let p = a + b - c
    let pa = if (p > a) { p - a } else { a - p }
    let pb = if (p > b) { p - b } else { b - p }
    let pc = if (p > c) { p - c } else { c - p }
    if (pa <= pb && pa <= pc) {
        a
    } else if (pb <= pc) {
        b
    } else {
        c
    }
}

private func pngPredictor(data: Array<UInt8>, parms: Option<HashMap<String, PdfValue>>): Array<UInt8> {
    let colors = getInt(parms, "Colors", 1)
    let bits = getInt(parms, "BitsPerComponent", 8)
    let columns = getInt(parms, "Columns", 1)
    let bitsPerPixel = colors * bits
    var rowLength = (columns * bitsPerPixel + 7) / 8
    if (rowLength <= 0) {
        return data
    }
    var bpp = (bitsPerPixel + 7) / 8
    if (bpp <= 0) {
        bpp = 1
    }
    let out = ArrayList<UInt8>()
    var previous = Array<UInt8>(rowLength, repeat: 0)
    var position: Int64 = 0
    while (position < data.size) {
        let filterType = Int64(data[position])
        position += 1
        let available = data.size - position
        var count = rowLength
        if (available < count) {
            count = available
        }
        let row = ArrayList<UInt8>(count)
        for (i in 0..count) {
            row.add(data[position + i])
        }
        position += count
        let current = Array<UInt8>(rowLength, repeat: 0)
        for (i in 0..count) {
            let raw = Int64(row[i])
            let left = if (i >= bpp) { Int64(current[i - bpp]) } else { 0 }
            let up = Int64(previous[i])
            let upLeft = if (i >= bpp) { Int64(previous[i - bpp]) } else { 0 }
            let value = match (filterType) {
                case 0 => raw
                case 1 => raw + left
                case 2 => raw + up
                case 3 => raw + (left + up) / 2
                case 4 => raw + paeth(left, up, upLeft)
                case _ => raw
            }
            current[i] = UInt8(value & 0xFF)
        }
        // A truncated final row is unusual but possible; emit only the bytes
        // that were actually present instead of padding its tail with zeros.
        for (i in 0..count) {
            out.add(current[i])
        }
        previous = current
    }
    out.toArray()
}

// ---------------------------------------------------------------------------
// ASCIIHex

public func asciiHexDecode(data: Array<UInt8>): Array<UInt8> {
    let out = ArrayList<UInt8>()
    var high: Int64 = -1
    for (b in data) {
        if (b == 62) {
            break
        }
        if (isPdfWhitespace(b)) {
            continue
        }
        let digit = hexDigit(b)
        if (digit < 0) {
            throw PdfError("ASCIIHexDecode: invalid byte ${Int64(b)}")
        }
        if (high < 0) {
            high = digit
        } else {
            out.add(UInt8(high * 16 + digit))
            high = -1
        }
    }
    if (high >= 0) {
        out.add(UInt8(high * 16))
    }
    out.toArray()
}

private func hexDigit(b: UInt8): Int64 {
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

// ---------------------------------------------------------------------------
// ASCII85

public func ascii85Decode(data: Array<UInt8>): Array<UInt8> {
    let out = ArrayList<UInt8>()
    let group = ArrayList<Int64>()
    var index: Int64 = 0
    while (index < data.size) {
        let b = data[index]
        index += 1
        if (isPdfWhitespace(b)) {
            continue
        }
        if (b == 126) {
            // `~>` terminates the stream.
            if (index < data.size && data[index] == 62) {
                index += 1
            }
            break
        }
        if (b == 122 && group.isEmpty()) {
            out.add(0)
            out.add(0)
            out.add(0)
            out.add(0)
            continue
        }
        if (b < 33 || b > 117) {
            throw PdfError("ASCII85Decode: invalid byte ${Int64(b)} at offset ${index - 1}")
        }
        group.add(Int64(b) - 33)
        if (group.size == 5) {
            emitAscii85Group(out, group, 4)
            group.clear()
        }
    }
    if (!group.isEmpty()) {
        let count = group.size
        while (group.size < 5) {
            group.add(84)
        }
        emitAscii85Group(out, group, count - 1)
    }
    out.toArray()
}

private func emitAscii85Group(out: ArrayList<UInt8>, group: ArrayList<Int64>, take: Int64): Unit {
    var value: Int64 = 0
    for (digit in group) {
        value = value * 85 + digit
    }
    let b0 = UInt8((value >> 24) & 0xFF)
    let b1 = UInt8((value >> 16) & 0xFF)
    let b2 = UInt8((value >> 8) & 0xFF)
    let b3 = UInt8(value & 0xFF)
    if (take >= 1) {
        out.add(b0)
    }
    if (take >= 2) {
        out.add(b1)
    }
    if (take >= 3) {
        out.add(b2)
    }
    if (take >= 4) {
        out.add(b3)
    }
}

// ---------------------------------------------------------------------------
// RunLength

public func runLengthDecode(data: Array<UInt8>): Array<UInt8> {
    let out = ArrayList<UInt8>()
    var index: Int64 = 0
    while (index < data.size) {
        let length = Int64(data[index])
        index += 1
        if (length == 128) {
            break
        }
        if (length < 128) {
            let count = length + 1
            for (_ in 0..count) {
                if (index >= data.size) {
                    break
                }
                out.add(data[index])
                index += 1
            }
        } else {
            if (index >= data.size) {
                break
            }
            let value = data[index]
            index += 1
            let count = 257 - length
            for (_ in 0..count) {
                out.add(value)
            }
        }
    }
    out.toArray()
}

// ---------------------------------------------------------------------------
// LZW

private class LzwBitReader {
    let data: Array<UInt8>
    var bitPosition: Int64

    init(data: Array<UInt8>) {
        this.data = data
        this.bitPosition = 0
    }

    func readBits(width: Int64): Option<Int64> {
        if (bitPosition + width > data.size * 8) {
            return None
        }
        var value: Int64 = 0
        for (_ in 0..width) {
            let byteIndex = bitPosition / 8
            let bitIndex = 7 - (bitPosition % 8)
            let bit = (Int64(data[byteIndex]) >> bitIndex) & 1
            value = (value << 1) | bit
            bitPosition += 1
        }
        Some(value)
    }
}

private func lzwWithPredictor(data: Array<UInt8>, parms: Option<HashMap<String, PdfValue>>): Array<UInt8> {
    let earlyChange = getInt(parms, "EarlyChange", 1)
    let decoded = lzwDecode(data, earlyChange)
    applyPredictor(decoded, parms)
}

public func lzwDecode(data: Array<UInt8>, earlyChange: Int64): Array<UInt8> {
    let reader = LzwBitReader(data)
    let out = ArrayList<UInt8>()
    var dictionary = ArrayList<Array<UInt8>>()
    var width: Int64 = 9
    var previous: Option<Array<UInt8>> = None

    func reset(): Unit {
        dictionary = ArrayList<Array<UInt8>>(4096)
        for (i in 0..256) {
            dictionary.add([UInt8(i)])
        }
        dictionary.add(Array<UInt8>()) // 256 clear
        dictionary.add(Array<UInt8>()) // 257 EOD
        width = 9
        previous = None
    }

    reset()
    while (true) {
        let code = match (reader.readBits(width)) {
            case Some(value) => value
            case None => break
        }
        if (code == 256) {
            reset()
            continue
        }
        if (code == 257) {
            break
        }
        var entry: Array<UInt8>
        if (code < dictionary.size) {
            entry = dictionary[code]
        } else if (code == dictionary.size) {
            match (previous) {
                case Some(prev) =>
                    let extended = ArrayList<UInt8>(prev.size + 1)
                    for (b in prev) {
                        extended.add(b)
                    }
                    extended.add(prev[0])
                    entry = extended.toArray()
                case None => throw PdfError("LZWDecode: invalid first code ${code}")
            }
        } else {
            throw PdfError("LZWDecode: code ${code} is outside the dictionary")
        }
        appendAll(out, entry)
        match (previous) {
            case Some(prev) =>
                if (dictionary.size < 4096) {
                    let combined = ArrayList<UInt8>(prev.size + 1)
                    for (b in prev) {
                        combined.add(b)
                    }
                    combined.add(entry[0])
                    dictionary.add(combined.toArray())
                    let threshold = (1 << width) - earlyChange
                    if (dictionary.size >= threshold && width < 12) {
                        width += 1
                    }
                }
            case None => ()
        }
        previous = Some(entry)
    }
    out.toArray()
}
