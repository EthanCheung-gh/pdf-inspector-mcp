package pdf_inspector_mcp.pdf

import std.collection.*

/**
 * Alias used inside `PdfValue` for the stream payload.
 *
 * The enum constructor is also called `PdfStream` (part of the agreed API), and
 * Cangjie resolves the bare identifier inside the enum body to the constructor,
 * which makes `PdfStream(PdfStream)` "not a type". The alias keeps the public
 * names intact: `PdfValue.PdfStream(stream)` is still how callers construct and
 * match the variant.
 */
public type PdfStreamPayload = PdfStream

/**
 * The PDF object model.
 *
 * A PDF value is one of the eight basic types (null, boolean, number, string,
 * name, array, dictionary, stream) plus the indirect-reference form. Strings
 * and names keep their raw representation at this layer:
 *
 * - [PdfString] holds the *raw bytes* of a literal or hex string. Decoding to
 *   text happens in `PdfDocument.asText` because it needs the PDFDocEncoding /
 *   UTF-16BE rules.
 * - [PdfName] holds the name without the leading `/` and with `#xx` escapes
 *   already decoded to bytes.
 * - [PdfRef] is intentionally not resolved here; `PdfDocument.resolve` follows
 *   it through the cross-reference table.
 *
 * The enum is recursive through `ArrayList`/`HashMap` (reference types), which
 * is what the Cangjie compiler requires for recursive `enum` declarations.
 */
public enum PdfValue {
    | PdfNull
    | PdfBool(Bool)
    | PdfInt(Int64)
    | PdfReal(Float64)
    | PdfString(Array<UInt8>)
    | PdfName(String)
    | PdfArray(ArrayList<PdfValue>)
    | PdfDict(HashMap<String, PdfValue>)
    | PdfRef(Int64, Int64)
    | PdfStream(PdfStreamPayload)
}

/**
 * A stream object: the dictionary plus the bytes between `stream` and
 * `endstream` (the single end-of-line marker after `stream` and before
 * `endstream` is not part of `raw`).
 *
 * `decoded` is a per-stream cache filled in by the filter chain. It is a plain
 * `var` so the parser can memoise the decoded payload without re-running the
 * filters; consumers must go through `PdfDocument.streamData` rather than
 * reading it directly.
 */
public class PdfStream {
    public let dict: HashMap<String, PdfValue>
    public let raw: Array<UInt8>
    public var decoded: Option<Array<UInt8>>

    public init(dict: HashMap<String, PdfValue>, raw: Array<UInt8>) {
        this.dict = dict
        this.raw = raw
        this.decoded = None
    }
}

/** Every recoverable problem with a PDF is reported as a `PdfError`. */
public class PdfError <: Exception {
    public init(message: String) {
        super(message)
    }

    public override func getClassName(): String {
        "PdfError"
    }
}

/** Shallow, bounded rendering of a value; for diagnostics only, never parsing. */
public func describeValue(v: PdfValue): String {
    match (v) {
        case PdfNull => "null"
        case PdfBool(b) => if (b) { "true" } else { "false" }
        case PdfInt(n) => n.toString()
        case PdfReal(f) => f.toString()
        case PdfString(bytes) => "<string ${bytes.size} bytes>"
        case PdfName(name) => "/${name}"
        case PdfArray(items) => "<array ${items.size}>"
        case PdfDict(entries) => "<dict ${entries.size}>"
        case PdfRef(num, gen) => "${num} ${gen} R"
        case PdfStream(stream) => "<stream ${stream.raw.size} bytes>"
    }
}

/** Whether a value is the PDF `null` object (after any resolution by the caller). */
public func isPdfNull(v: PdfValue): Bool {
    match (v) {
        case PdfNull => true
        case _ => false
    }
}
