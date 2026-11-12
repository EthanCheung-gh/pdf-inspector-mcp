package pdf_inspector_mcp.pdf

import std.collection.*
import std.convert.*

/**
 * Cross-reference table, indirect-object cache and object-stream reader.
 *
 * `PdfObjectParser` owns the raw file bytes and the cross-reference state. It
 * deliberately knows nothing about pages, fonts or content streams; the
 * document layer builds those on top of `resolve`.
 *
 * Supported xref forms:
 * - classic `xref` tables with multiple subsections and a `/Prev` chain;
 * - hybrid-reference files (`/XRefStm` inside a classic trailer);
 * - cross-reference streams (`/Type /XRef`) with `/W`, `/Index`, Flate and PNG
 *   predictors;
 * - object streams (`/Type /ObjStm`) read lazily by object number.
 *
 * When the xref is missing or unusable the parser falls back to scanning the
 * file for `n g obj` headers and for the last `trailer` dictionary that has a
 * `/Root`.
 */

enum XrefKind {
    | XrefFree
    | XrefInUse
    | XrefCompressed
}

class XrefEntry {
    let kind: XrefKind
    let offset: Int64
    let gen: Int64
    let streamObj: Int64
    let streamIndex: Int64

    init(kind: XrefKind, offset: Int64, gen: Int64, streamObj: Int64, streamIndex: Int64) {
        this.kind = kind
        this.offset = offset
        this.gen = gen
        this.streamObj = streamObj
        this.streamIndex = streamIndex
    }
}

private func isXrefInUse(entry: XrefEntry): Bool {
    match (entry.kind) {
        case XrefKind.XrefInUse => true
        case _ => false
    }
}

private func isXrefFree(entry: XrefEntry): Bool {
    match (entry.kind) {
        case XrefKind.XrefFree => true
        case _ => false
    }
}

private func isXrefCompressed(entry: XrefEntry): Bool {
    match (entry.kind) {
        case XrefKind.XrefCompressed => true
        case _ => false
    }
}

private func bytesEqualAt(data: Array<UInt8>, pos: Int64, text: String): Bool {
    if (pos < 0 || pos + text.size > data.size) {
        return false
    }
    let expected = text.toArray()
    for (i in 0..expected.size) {
        if (data[pos + i] != expected[i]) {
            return false
        }
    }
    true
}

private func keywordBoundaryAt(data: Array<UInt8>, pos: Int64, length: Int64): Bool {
    let after = pos + length
    if (after >= data.size) {
        return true
    }
    let b = data[after]
    isPdfWhitespace(b) || isPdfDelimiter(b)
}

private func indexOfBytes(data: Array<UInt8>, needle: String, from: Int64): Int64 {
    let expected = needle.toArray()
    if (expected.size == 0) {
        return from
    }
    var i = if (from < 0) { 0 } else { from }
    let last = data.size - expected.size
    while (i <= last) {
        if (data[i] == expected[0]) {
            var matched = true
            for (j in 1..expected.size) {
                if (data[i + j] != expected[j]) {
                    matched = false
                    break
                }
            }
            if (matched) {
                return i
            }
        }
        i += 1
    }
    -1
}

private func lastIndexOfBytes(data: Array<UInt8>, needle: String): Int64 {
    let expected = needle.toArray()
    if (expected.size == 0) {
        return data.size
    }
    var i = data.size - expected.size
    while (i >= 0) {
        if (data[i] == expected[0]) {
            var matched = true
            for (j in 1..expected.size) {
                if (data[i + j] != expected[j]) {
                    matched = false
                    break
                }
            }
            if (matched) {
                return i
            }
        }
        i -= 1
    }
    -1
}

/** `%PDF-x.y` from the first 1024 bytes, or `unknown` when absent. */
private func detectPdfVersion(data: Array<UInt8>): String {
    let limit = if (data.size < 1024) { data.size } else { 1024 }
    var i: Int64 = 0
    while (i + 8 <= limit) {
        if (bytesEqualAt(data, i, "%PDF-")) {
            var j = i + 5
            let out = ArrayList<UInt8>()
            while (j < limit && j < i + 16 && data[j] != 10 && data[j] != 13 && !isPdfWhitespace(data[j])) {
                out.add(data[j])
                j += 1
            }
            if (out.size > 0) {
                return String.fromUtf8(out.toArray())
            }
            return "unknown"
        }
        i += 1
    }
    "unknown"
}

private func dictHasType(entries: HashMap<String, PdfValue>, expected: String): Bool {
    match (entries.get("Type")) {
        case Some(PdfValue.PdfName(name)) => name == expected
        case _ => false
    }
}

private func streamTypeName(stream: PdfStream): String {
    match (stream.dict.get("Type")) {
        case Some(PdfValue.PdfName(name)) => name
        case _ => ""
    }
}

private func readRequiredInt(lex: PdfLexer, context: String): Int64 {
    let token = match (lex.readKeywordToken()) {
        case Some(value) => value
        case None => throw PdfError("${context}: expected an integer at byte ${lex.position()}")
    }
    match (Int64.tryParse(token)) {
        case Some(value) => value
        case None => throw PdfError("${context}: '${token}' is not an integer at byte ${lex.position()}")
    }
}

public class PdfObjectParser {
    public let data: Array<UInt8>
    public var trailer: HashMap<String, PdfValue>
    var xref: HashMap<Int64, XrefEntry>
    var cache: HashMap<Int64, PdfValue>
    var objectStreams: HashMap<Int64, HashMap<Int64, PdfValue>>
    var visitedXref: HashSet<Int64>
    var resolving: HashSet<Int64>
    /** Last parse error per object number, so callers can explain a PdfNull. */
    var objectErrors: HashMap<Int64, String>
    var reconstructed: Bool
    var lastObjectEnd: Int64
    public var version: String

    public init(data: Array<UInt8>) {
        this.data = data
        this.trailer = HashMap<String, PdfValue>()
        this.xref = HashMap<Int64, XrefEntry>()
        this.cache = HashMap<Int64, PdfValue>()
        this.objectStreams = HashMap<Int64, HashMap<Int64, PdfValue>>()
        this.visitedXref = HashSet<Int64>()
        this.resolving = HashSet<Int64>()
        this.objectErrors = HashMap<Int64, String>()
        this.reconstructed = false
        this.lastObjectEnd = 0
        this.version = detectPdfVersion(data)
        loadCrossReference()
    }

    // ------------------------------------------------------------------
    // Cross-reference loading

    private func addXref(num: Int64, entry: XrefEntry, overwrite: Bool): Unit {
        if (overwrite || !xref.contains(num)) {
            xref.add(num, entry)
        }
    }

    private func mergeTrailer(entries: HashMap<String, PdfValue>, overwrite: Bool): Unit {
        for ((key, value) in entries) {
            if (overwrite || !trailer.contains(key)) {
                trailer.add(key, value)
            }
        }
    }

    private func loadCrossReference(): Unit {
        var loaded = false
        let start = findStartXref()
        if (start >= 0) {
            loaded = try {
                loadXrefAt(start)
            } catch (e: Exception) {
                false
            }
        }
        var usableCatalog = false
        if (loaded && !xref.isEmpty() && trailer.contains("Root")) {
            match (rootValue()) {
                case Some(PdfValue.PdfDict(_)) => usableCatalog = true
                case _ => ()
            }
        }
        if (!usableCatalog) {
            // Missing xref, missing trailer, or an xref whose offsets do not
            // reach a readable catalog: fall back to a full-file scan.
            let rebuilt = try {
                rebuildFromScan()
            } catch (e: Exception) {
                false
            }
            if (!rebuilt && xref.isEmpty()) {
                throw PdfError("cannot read this PDF: no usable cross-reference table or objects")
            }
            match (rootValue()) {
                case Some(PdfValue.PdfDict(_)) => usableCatalog = true
                case _ => ()
            }
        }
        if (usableCatalog) {
            return
        }
        // Last resort: the trailer is gone but a catalog object exists.
        findCatalogWithoutTrailer()
    }

    private func findStartXref(): Int64 {
        let marker = lastIndexOfBytes(data, "startxref")
        if (marker < 0) {
            return -1
        }
        let lex = PdfLexer(data, pos: marker + 9)
        let token = match (lex.readKeywordToken()) {
            case Some(value) => value
            case None => return -1
        }
        match (Int64.tryParse(token)) {
            case Some(value) =>
                if (value <= 0 || value >= data.size) {
                    return -1
                }
                value
            case None => -1
        }
    }

    /** Returns true when the section at `offset` was understood. */
    private func loadXrefAt(offset: Int64): Bool {
        if (offset < 0 || offset >= data.size || visitedXref.contains(offset)) {
            return false
        }
        visitedXref.add(offset)
        let lex = PdfLexer(data, pos: offset)
        lex.skipWhitespace()
        var ok = false
        if (lex.peekKeyword("xref")) {
            ok = parseClassicXref(lex)
        } else {
            ok = parseXrefStream(offset, false)
        }
        ok
    }

    private func parseClassicXref(lex: PdfLexer): Bool {
        if (!lex.matchKeyword("xref")) {
            return false
        }
        while (true) {
            lex.skipWhitespace()
            if (lex.eof()) {
                return false
            }
            if (lex.peekKeyword("trailer")) {
                break
            }
            let first = readRequiredInt(lex, "xref subsection")
            let count = readRequiredInt(lex, "xref subsection")
            if (count < 0 || count > data.size) {
                throw PdfError("xref subsection has implausible object count ${count}")
            }
            for (i in 0..count) {
                let entryOffset = readRequiredInt(lex, "xref entry")
                let generation = readRequiredInt(lex, "xref entry")
                let flag = match (lex.readKeywordToken()) {
                    case Some(value) => value
                    case None => throw PdfError("xref entry ${first + i} has no type flag")
                }
                if (flag == "n") {
                    addXref(first + i, XrefEntry(XrefKind.XrefInUse, entryOffset, generation, 0, 0), false)
                } else if (flag == "f") {
                    addXref(first + i, XrefEntry(XrefKind.XrefFree, 0, generation, 0, 0), false)
                } else {
                    throw PdfError("xref entry ${first + i} has unknown type '${flag}'")
                }
            }
        }
        lex.requireKeyword("trailer", "xref")
        let dict = match (lex.parseValue()) {
            case PdfValue.PdfDict(entries) => entries
            case _ => throw PdfError("trailer is not a dictionary at byte ${lex.position()}")
        }
        // A hybrid-reference file keeps compressed objects in /XRefStm; that
        // section must win over the "free" placeholders of the classic table.
        match (dict.get("XRefStm")) {
            case Some(PdfValue.PdfInt(streamOffset)) =>
                let saved = visitedXref.contains(streamOffset)
                if (!saved) {
                    visitedXref.add(streamOffset)
                    try {
                        parseXrefStream(streamOffset, true)
                    } catch (e: Exception) {
                        // A broken /XRefStm must not discard the classic table.
                    }
                }
            case _ => ()
        }
        mergeTrailer(dict, false)
        followPreviousFrom(dict)
        true
    }

    private func parseXrefStream(offset: Int64, overwrite: Bool): Bool {
        let value = parseIndirectObjectAt(offset)
        let stream = match (value) {
            case PdfValue.PdfStream(item) => item
            case _ => return false
        }
        let typeName = match (stream.dict.get("Type")) {
            case Some(PdfValue.PdfName(name)) => name
            case _ => ""
        }
        if (typeName != "XRef") {
            return false
        }
        let decoded = decodeResolved(stream)
        let widths = match (resolveDictEntry(stream.dict, "W")) {
            case Some(PdfValue.PdfArray(items)) =>
                let values = ArrayList<Int64>()
                for (item in items) {
                    values.add(match (resolve(item)) {
                        case PdfValue.PdfInt(n) => n
                        case PdfValue.PdfReal(f) => Int64(f)
                        case _ => 0
                    })
                }
                values
            case _ => throw PdfError("xref stream has no /W array")
        }
        if (widths.size < 3) {
            throw PdfError("xref stream /W must hold three integers")
        }
        let w0 = widths[0]
        let w1 = widths[1]
        let w2 = widths[2]
        if (w0 < 0 || w1 < 0 || w2 < 0 || w0 > 8 || w1 > 8 || w2 > 8) {
            throw PdfError("xref stream /W values are out of range")
        }
        let rowLength = w0 + w1 + w2
        if (rowLength <= 0) {
            throw PdfError("xref stream /W describes zero-width entries")
        }
        let size = match (resolveDictEntry(stream.dict, "Size")) {
            case Some(PdfValue.PdfInt(n)) => n
            case Some(PdfValue.PdfReal(f)) => Int64(f)
            case _ => 0
        }
        let indexEntries = match (resolveDictEntry(stream.dict, "Index")) {
            case Some(PdfValue.PdfArray(items)) =>
                let values = ArrayList<Int64>()
                for (item in items) {
                    values.add(match (resolve(item)) {
                        case PdfValue.PdfInt(n) => n
                        case PdfValue.PdfReal(f) => Int64(f)
                        case _ => 0
                    })
                }
                values
            case _ =>
                let defaults = ArrayList<Int64>()
                defaults.add(0)
                defaults.add(size)
                defaults
        }
        var position: Int64 = 0
        var pair = 0
        while (pair + 1 < indexEntries.size) {
            let first = indexEntries[pair]
            let count = indexEntries[pair + 1]
            pair += 2
            for (i in 0..count) {
                if (position + rowLength > decoded.size) {
                    break
                }
                let kind = if (w0 == 0) { 1 } else { readBigEndian(decoded, position, w0) }
                let field1 = readBigEndian(decoded, position + w0, w1)
                let field2 = readBigEndian(decoded, position + w0 + w1, w2)
                position += rowLength
                let num = first + i
                if (kind == 0) {
                    addXref(num, XrefEntry(XrefKind.XrefFree, 0, field2, 0, 0), overwrite)
                } else if (kind == 1) {
                    addXref(num, XrefEntry(XrefKind.XrefInUse, field1, field2, 0, 0), overwrite)
                } else if (kind == 2) {
                    addXref(num, XrefEntry(XrefKind.XrefCompressed, 0, 0, field1, 0), overwrite)
                }
            }
        }
        mergeTrailer(stream.dict, false)
        followPreviousFrom(stream.dict)
        true
    }

    private func readBigEndian(data: Array<UInt8>, start: Int64, width: Int64): Int64 {
        var value: Int64 = 0
        for (i in 0..width) {
            if (start + i >= data.size) {
                return value
            }
            value = (value << 8) | Int64(data[start + i])
        }
        value
    }

    /**
     * Follow the `/Prev` pointer of *this* section (not of the merged trailer,
     * which would keep pointing at the newest section and stall a longer
     * incremental-update chain after the first hop).
     */
    private func followPreviousFrom(entries: HashMap<String, PdfValue>): Unit {
        match (entries.get("Prev")) {
            case Some(PdfValue.PdfInt(previous)) =>
                if (previous > 0 && previous < data.size && !visitedXref.contains(previous)) {
                    try {
                        loadXrefAt(previous)
                    } catch (e: Exception) {
                        // An unreadable /Prev section leaves the newer xref usable.
                    }
                }
            case _ => ()
        }
    }

    /**
     * Rebuild the object index by scanning for `n g obj` headers.
     *
     * Incremental updates append objects, so later occurrences overwrite
     * earlier ones. Trailer dictionaries are also re-scanned; the last one that
     * carries a `/Root` wins.
     */
    private func rebuildFromScan(): Bool {
        reconstructed = true
        xref.clear()
        cache.clear()
        objectErrors.clear()
        var i: Int64 = 0
        var lastTrailer: Option<HashMap<String, PdfValue>> = None
        var lastXrefTrailer: Option<HashMap<String, PdfValue>> = None
        var catalogNumber: Int64 = -1
        var catalogGeneration: Int64 = 0
        while (i < data.size) {
            if (data[i] >= 48 && data[i] <= 57) {
                let atBoundary = i == 0 || isPdfWhitespace(data[i - 1]) || isPdfDelimiter(data[i - 1])
                if (atBoundary) {
                    let objectStart = i
                    let headerLex = PdfLexer(data, pos: i)
                    let numberToken = headerLex.readKeywordToken()
                    let genToken = headerLex.readKeywordToken()
                    let objectKeyword = headerLex.readKeywordToken()
                    var matched = false
                    match ((numberToken, genToken, objectKeyword)) {
                        case (Some(numberText), Some(genText), Some(keyword)) =>
                            if (keyword == "obj") {
                                match ((Int64.tryParse(numberText), Int64.tryParse(genText))) {
                                    case (Some(num), Some(gen)) =>
                                        // Parse the candidate for real; a header
                                        // inside a stream or a comment must not
                                        // overwrite a real object's entry.
                                        try {
                                            let value = parseIndirectObjectAt(objectStart)
                                            addXref(num, XrefEntry(XrefKind.XrefInUse, objectStart, gen, 0, 0), true)
                                            cache.add(num, value)
                                            match (value) {
                                                case PdfValue.PdfDict(entries) =>
                                                    if (dictHasType(entries, "Catalog")) {
                                                        catalogNumber = num
                                                        catalogGeneration = gen
                                                    }
                                                case PdfValue.PdfStream(stream) =>
                                                    let streamType = streamTypeName(stream)
                                                    if (streamType == "ObjStm") {
                                                        // A scan cannot see objects that
                                                        // live inside an object stream;
                                                        // expand it now so they resolve.
                                                        for ((innerNumber, innerValue) in safeLoadObjectStream(num)) {
                                                            match (innerValue) {
                                                                case PdfValue.PdfDict(entries) =>
                                                                    if (dictHasType(entries, "Catalog")) {
                                                                        catalogNumber = innerNumber
                                                                        catalogGeneration = 0
                                                                    }
                                                                case _ => ()
                                                            }
                                                        }
                                                    } else if (streamType == "XRef") {
                                                        // An orphan xref stream is still a
                                                        // usable index for the offsets it
                                                        // describes.
                                                        lastXrefTrailer = Some(stream.dict)
                                                        try {
                                                            parseXrefStream(objectStart, true)
                                                        } catch (e: Exception) {
                                                            ()
                                                        }
                                                    }
                                                case _ => ()
                                            }
                                            matched = true
                                        } catch (e: Exception) {
                                            ()
                                        }
                                    case _ => ()
                                }
                            }
                        case _ => ()
                    }
                    if (matched && lastObjectEnd > objectStart) {
                        i = lastObjectEnd
                        continue
                    }
                }
            }
            // Trailer dictionaries: parse each and remember the last with /Root.
            let atTrailerWord = data[i] == 116 && bytesEqualAt(data, i, "trailer")
            let trailerBoundary = i == 0 || isPdfWhitespace(data[i - 1]) || isPdfDelimiter(data[i - 1])
            if (atTrailerWord) {
              if (trailerBoundary && keywordBoundaryAt(data, i, 7)) {
                let lex = PdfLexer(data, pos: i + 7)
                try {
                    match (lex.parseValue()) {
                        case PdfValue.PdfDict(entries) =>
                            if (entries.contains("Root")) {
                                lastTrailer = Some(entries)
                            }
                        case _ => ()
                    }
                } catch (e: Exception) {
                    // Keep scanning other trailers.
                }
              }
            }
            i += 1
        }
        // In an incremental-update chain the newest xref stream/trailer wins.
        match (lastXrefTrailer) {
            case Some(entries) => mergeTrailer(entries, true)
            case None => ()
        }
        match (lastTrailer) {
            case Some(entries) => mergeTrailer(entries, true)
            case None =>
                if (catalogNumber >= 0) {
                    trailer.add("Root", PdfValue.PdfRef(catalogNumber, catalogGeneration))
                }
        }
        !xref.isEmpty()
    }

    private func findCatalogWithoutTrailer(): Unit {
        let numbers = ArrayList<Int64>()
        for (num in xref.keys()) {
            numbers.add(num)
        }
        for (num in numbers) {
            if (trailer.contains("Root")) {
                return
            }
            match (xref.get(num)) {
                case Some(entry) =>
                    if (isXrefInUse(entry)) {
                        try {
                            let value = parseIndirectObjectAt(entry.offset)
                            match (value) {
                                case PdfValue.PdfDict(entries) =>
                                    match (entries.get("Type")) {
                                        case Some(PdfValue.PdfName("Catalog")) =>
                                            trailer.add("Root", PdfValue.PdfRef(num, entry.gen))
                                        case _ => ()
                                    }
                                case _ => ()
                            }
                        } catch (e: Exception) {
                            ()
                        }
                    }
                case None => ()
            }
        }
    }

    // ------------------------------------------------------------------
    // Indirect objects

    /** Parse the `n g obj ... endobj` unit starting at `offset`. */
    public func parseIndirectObjectAt(offset: Int64): PdfValue {
        let lex = PdfLexer(data, pos: offset)
        lex.skipWhitespace()
        let objectNumber = readRequiredInt(lex, "indirect object")
        let generation = readRequiredInt(lex, "indirect object")
        lex.requireKeyword("obj", "indirect object ${objectNumber} ${generation}")
        let value = lex.parseValue()
        lex.skipWhitespace()
        if (lex.peekKeyword("stream")) {
            match (value) {
                case PdfValue.PdfDict(entries) =>
                    if (lex.matchKeyword("stream")) {
                        let stream = readStream(lex, entries)
                        lastObjectEnd = lex.position()
                        return PdfValue.PdfStream(stream)
                    }
                case _ => ()
            }
        }
        lex.skipWhitespace()
        if (lex.peekKeyword("endobj")) {
            lex.matchKeyword("endobj")
        }
        lastObjectEnd = lex.position()
        value
    }

    private func readStream(lex: PdfLexer, entries: HashMap<String, PdfValue>): PdfStream {
        // Tolerate spaces/tabs before the EOL; the EOL itself is not data.
        while (lex.peek() == 32 || lex.peek() == 9) {
            lex.advance()
        }
        if (lex.peek() == 13) {
            lex.advance()
            if (lex.peek() == 10) {
                lex.advance()
            }
        } else if (lex.peek() == 10) {
            lex.advance()
        }
        let start = lex.position()
        let declared = declaredStreamLength(entries)
        // Overflow-safe "does the declared length fit in the file?" test: a
        // hostile /Length such as Int64.max would otherwise wrap.
        let remaining = data.size - start
        let declaredFits = declared >= 0 && declared <= remaining
        if (declaredFits && endstreamAfter(start + declared)) {
            let raw = data[start..start + declared].toArray()
            lex.setPosition(start + declared)
            lex.skipWhitespace()
            if (!lex.matchKeyword("endstream")) {
                // `endstream` after the declared length was consumed by the
                // whitespace skip; only the keyword remains.
                throw PdfError("stream at byte ${start} has a /Length that does not reach 'endstream'")
            }
            return PdfStream(entries, raw)
        }
        // /Length is missing, indirect, wrong, or the stream is truncated.
        // Search for an `endstream` keyword: this keeps files whose /Length is
        // merely wrong readable, while a stream that truly runs off the end of
        // the file is reported instead of being silently returned as empty.
        var end = findEndstreamKeyword(start)
        if (end < 0) {
            if (declared >= 0 && declared > remaining) {
                throw PdfError(
                    "stream at byte ${start} declares /Length ${declared}, which exceeds the " +
                    "${remaining} bytes left in the file and no 'endstream' marker was found"
                )
            }
            throw PdfError("stream at byte ${start} is truncated: no 'endstream' marker was found")
        }
        var rawEnd = end
        if (rawEnd > start && data[rawEnd - 1] == 10) {
            rawEnd -= 1
            if (rawEnd > start && data[rawEnd - 1] == 13) {
                rawEnd -= 1
            }
        } else if (rawEnd > start && data[rawEnd - 1] == 13) {
            rawEnd -= 1
        }
        let raw = data[start..rawEnd].toArray()
        lex.setPosition(end)
        lex.matchKeyword("endstream")
        PdfStream(entries, raw)
    }

    /**
     * Locate a real `endstream` keyword, starting at `from`.
     *
     * `indexOfBytes` alone can match the word inside binary stream data. A real
     * keyword ends at a PDF whitespace/delimiter boundary and is not part of a
     * longer token; that is enough to keep the compatibility fallback for wrong
     * `/Length` values without accepting arbitrary bytes as a marker.
     */
    private func findEndstreamKeyword(from: Int64): Int64 {
        var position = if (from < 0) { 0 } else { from }
        while (position < data.size) {
            let found = indexOfBytes(data, "endstream", position)
            if (found < 0) {
                return -1
            }
            if (keywordBoundaryAt(data, found, 9)) {
                return found
            }
            position = found + 1
        }
        -1
    }

    private func declaredStreamLength(entries: HashMap<String, PdfValue>): Int64 {
        let value = match (entries.get("Length")) {
            case Some(item) => item
            case None => return -1
        }
        match (value) {
            case PdfValue.PdfInt(n) => n
            case PdfValue.PdfReal(f) => Int64(f)
            case PdfValue.PdfRef(num, gen) =>
                match (resolveRef(num, gen)) {
                    case PdfValue.PdfInt(n) => n
                    case PdfValue.PdfReal(f) => Int64(f)
                    case _ => -1
                }
            case _ => -1
        }
    }

    private func endstreamAfter(position: Int64): Bool {
        var pos = position
        var skipped: Int64 = 0
        while (pos < data.size && skipped < 32 && isPdfWhitespace(data[pos])) {
            pos += 1
            skipped += 1
        }
        bytesEqualAt(data, pos, "endstream") && keywordBoundaryAt(data, pos, 9)
    }

    // ------------------------------------------------------------------
    // Resolution

    public func resolve(value: PdfValue): PdfValue {
        match (value) {
            case PdfValue.PdfRef(num, gen) => resolveRef(num, gen)
            case _ => value
        }
    }

    /** Follow an indirect reference, including ref-to-ref chains, up to 32 hops. */
    public func resolveRef(num: Int64, gen: Int64): PdfValue {
        var currentNumber = num
        var currentGeneration = gen
        var depth: Int64 = 0
        while (depth < 32) {
            let value = resolveInternal(currentNumber, currentGeneration, depth)
            match (value) {
                case PdfValue.PdfRef(nextNumber, nextGeneration) =>
                    currentNumber = nextNumber
                    currentGeneration = nextGeneration
                    depth += 1
                case PdfValue.PdfNull =>
                    // If the final object could not be parsed, remember why
                    // against the reference the caller actually holds.
                    match (objectErrors.get(currentNumber)) {
                        case Some(reason) =>
                            if (!objectErrors.contains(num)) {
                                objectErrors.add(num, reason)
                            }
                        case None => ()
                    }
                    return value
                case _ => return value
            }
        }
        PdfValue.PdfNull
    }

    /** Error recorded while resolving `value`, if it resolved to a broken object. */
    public func resolutionError(value: PdfValue): Option<String> {
        match (value) {
            case PdfValue.PdfRef(num, _) => objectErrors.get(num)
            case _ => None
        }
    }

    private func resolveInternal(num: Int64, gen: Int64, depth: Int64): PdfValue {
        if (gen < 0 || depth > 32) {
            return PdfValue.PdfNull
        }
        let key = num
        match (cache.get(key)) {
            case Some(value) => return value
            case None => ()
        }
        if (resolving.contains(key)) {
            // Reference cycle: stop instead of recursing forever.
            return PdfValue.PdfNull
        }
        let entry = match (xref.get(num)) {
            case Some(item) => item
            case None =>
                if (!reconstructed) {
                    // A broken xref may still be recoverable; try once.
                    try {
                        rebuildFromScan()
                    } catch (e: Exception) {
                        ()
                    }
                    match (xref.get(num)) {
                        case Some(item) => item
                        case None => return PdfValue.PdfNull
                    }
                } else {
                    return PdfValue.PdfNull
                }
        }
        if (isXrefFree(entry)) {
            cache.add(key, PdfValue.PdfNull)
            return PdfValue.PdfNull
        }
        resolving.add(key)
        let value = try {
            if (isXrefCompressed(entry)) {
                let objectMap = loadObjectStream(entry.streamObj)
                match (objectMap.get(num)) {
                    case Some(item) => item
                    case None => PdfValue.PdfNull
                }
            } else {
                parseIndirectObjectAt(entry.offset)
            }
        } catch (e: PdfError) {
            objectErrors.add(key, e.message)
            PdfValue.PdfNull
        } catch (e: Exception) {
            objectErrors.add(key, e.message)
            PdfValue.PdfNull
        } finally {
            resolving.remove(key)
        }
        cache.add(key, value)
        value
    }

    private func safeLoadObjectStream(streamNumber: Int64): HashMap<Int64, PdfValue> {
        try {
            loadObjectStream(streamNumber)
        } catch (e: Exception) {
            HashMap<Int64, PdfValue>()
        }
    }

    private func loadObjectStream(streamNumber: Int64): HashMap<Int64, PdfValue> {
        match (objectStreams.get(streamNumber)) {
            case Some(items) => return items
            case None => ()
        }
        let objects = HashMap<Int64, PdfValue>()
        objectStreams.add(streamNumber, objects)
        let streamValue = resolveInternal(streamNumber, 0, 0)
        let stream = match (streamValue) {
            case PdfValue.PdfStream(item) => item
            case _ => return objects
        }
        let count = match (resolveDictEntry(stream.dict, "N")) {
            case Some(PdfValue.PdfInt(n)) => n
            case _ => return objects
        }
        let first = match (resolveDictEntry(stream.dict, "First")) {
            case Some(PdfValue.PdfInt(n)) => n
            case _ => return objects
        }
        if (count < 0 || count > 10000000 || first < 0) {
            return objects
        }
        let decoded = decodeResolved(stream)
        let header = PdfLexer(decoded)
        let numbers = ArrayList<Int64>()
        let offsets = ArrayList<Int64>()
        for (_ in 0..count) {
            let numberToken = header.readKeywordToken()
            let offsetToken = header.readKeywordToken()
            match ((numberToken, offsetToken)) {
                case (Some(numberText), Some(offsetText)) =>
                    match ((Int64.tryParse(numberText), Int64.tryParse(offsetText))) {
                        case (Some(number), Some(offset)) =>
                            numbers.add(number)
                            offsets.add(offset)
                        case _ => ()
                    }
                case _ => break
            }
        }
        for (i in 0..numbers.size) {
            let objectNumber = numbers[i]
            let position = first + offsets[i]
            if (position < 0 || position >= decoded.size) {
                continue
            }
            try {
                let lex = PdfLexer(decoded, pos: position)
                let value = lex.parseValue()
                objects.add(objectNumber, value)
                cache.add(objectNumber, value)
            } catch (e: Exception) {
                // Skip one unreadable object, but remember why: a page-tree or
                // content reference to it must be able to report the failure.
                objectErrors.add(objectNumber, e.message)
            }
        }
        objects
    }

    public func resolveDictEntry(entries: HashMap<String, PdfValue>, key: String): Option<PdfValue> {
        match (entries.get(key)) {
            case Some(value) =>
                let resolved = resolve(value)
                match (resolved) {
                    case PdfValue.PdfNull => None
                    case _ => Some(resolved)
                }
            case None => None
        }
    }

    /** Decode a stream through its filter chain, resolving `/Filter` first. */
    public func decodeResolved(stream: PdfStream): Array<UInt8> {
        match (stream.decoded) {
            case Some(bytes) => return bytes
            case None => ()
        }
        let filter = match (resolveDictEntry(stream.dict, "Filter")) {
            case Some(value) => value
            case None => PdfValue.PdfNull
        }
        let parms = match (resolveDictEntry(stream.dict, "DecodeParms")) {
            case Some(value) => value
            case None => PdfValue.PdfNull
        }
        let bytes = decodeBytes(stream.raw, filter, parms)
        stream.decoded = Some(bytes)
        bytes
    }

    public func cacheSize(): Int64 {
        cache.size
    }

    public func xrefSize(): Int64 {
        xref.size
    }

    public func rootValue(): Option<PdfValue> {
        match (trailer.get("Root")) {
            case Some(value) => Some(resolve(value))
            case None => None
        }
    }

    public func infoEntries(): HashMap<String, PdfValue> {
        match (trailer.get("Info")) {
            case Some(PdfValue.PdfRef(num, gen)) =>
                match (resolveRef(num, gen)) {
                    case PdfValue.PdfDict(entries) => entries
                    case _ => HashMap<String, PdfValue>()
                }
            case Some(PdfValue.PdfDict(entries)) => entries
            case _ => HashMap<String, PdfValue>()
        }
    }
}
