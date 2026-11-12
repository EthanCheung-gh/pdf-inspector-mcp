package pdf_inspector_mcp.pdf

import std.collection.*

/**
 * One page of a document.
 *
 * Inheritable page attributes (`/Resources`, `/MediaBox`, `/CropBox`,
 * `/Rotate`) are resolved by the document's page-tree walk and stored in a
 * [PageNodeInfo]; the page object exposes the effective values.
 *
 * `width`/`height` come from `/CropBox` when it is present and valid, else from
 * `/MediaBox`, else from the PDF default `[0 0 612 792]`. `/Rotate` is exposed
 * separately and does not swap width/height, matching the agreed contract.
 */
class PageNodeInfo {
    let dict: HashMap<String, PdfValue>
    let resources: HashMap<String, PdfValue>
    let mediaBox: Option<PdfValue>
    let cropBox: Option<PdfValue>
    let rotate: Int64

    init(
        dict: HashMap<String, PdfValue>,
        resources: HashMap<String, PdfValue>,
        mediaBox: Option<PdfValue>,
        cropBox: Option<PdfValue>,
        rotate: Int64
    ) {
        this.dict = dict
        this.resources = resources
        this.mediaBox = mediaBox
        this.cropBox = cropBox
        this.rotate = rotate
    }
}

public class PdfPage {
    let document: PdfDocument
    let pageNumber: Int64
    let info: PageNodeInfo

    init(document: PdfDocument, pageNumber: Int64, info: PageNodeInfo) {
        this.document = document
        this.pageNumber = pageNumber
        this.info = info
    }

    public prop number: Int64 {
        get() {
            pageNumber
        }
    }

    public prop width: Float64 {
        get() {
            match (effectiveDimensions()) {
                case Some(dimensions) => dimensions[0]
                case None => 612.0
            }
        }
    }

    public prop height: Float64 {
        get() {
            match (effectiveDimensions()) {
                case Some(dimensions) => dimensions[1]
                case None => 792.0
            }
        }
    }

    public prop rotate: Int64 {
        get() {
            info.rotate
        }
    }

    public prop resources: HashMap<String, PdfValue> {
        get() {
            info.resources
        }
    }

    /**
     * Decoded content streams, concatenated with a newline between segments.
     * A page without `/Contents` yields an empty array.
     */
    public prop contents: Array<UInt8> {
        get() {
            let out = ArrayList<UInt8>()
            let contents = match (info.dict.get("Contents")) {
                case Some(value) => value
                case None => return Array<UInt8>()
            }
            let resolved = document.resolve(contents)
            match (resolved) {
                case PdfValue.PdfStream(stream) => appendContentStream(out, stream)
                case PdfValue.PdfArray(items) =>
                    for (item in items) {
                        match (document.resolve(item)) {
                            case PdfValue.PdfStream(stream) => appendContentStream(out, stream)
                            case PdfValue.PdfNull =>
                                // An explicit `null` entry means "no content";
                                // a reference that resolved to null is damage.
                                if (!isPdfNull(item)) {
                                    throw contentError(item)
                                }
                            case _ =>
                                throw PdfError(
                                    "cannot read page ${pageNumber} contents: a /Contents array entry is not a stream"
                                )
                        }
                    }
                case PdfValue.PdfNull =>
                    // `/Contents null` is tolerated as an empty page, but a
                    // reference that failed to resolve is not.
                    if (isPdfNull(contents)) {
                        return Array<UInt8>()
                    }
                    throw contentError(contents)
                case _ =>
                    throw PdfError(
                        "cannot read page ${pageNumber} contents: /Contents is not a stream or an array of streams"
                    )
            }
            out.toArray()
        }
    }

    /**
     * The page has `/Contents`, but it did not resolve to a stream. Include the
     * parser's underlying reason (for example a stream whose `/Length` runs past
     * the end of the file) so callers do not mistake the damage for a blank page.
     */
    private func contentError(value: PdfValue): PdfError {
        let detail = match (document.resolutionError(value)) {
            case Some(reason) => ": " + reason
            case None => ""
        }
        PdfError(
            "cannot read page ${pageNumber} contents: the /Contents stream is missing or unreadable" + detail
        )
    }

    private func appendContentStream(out: ArrayList<UInt8>, stream: PdfStream): Unit {
        let bytes = document.streamData(stream)
        if (out.size > 0) {
            out.add(10)
        }
        for (b in bytes) {
            out.add(b)
        }
    }

    /** Effective page box as `[x0, y0, x1, y1]`, when one is present. */
    public func box(): Array<Float64> {
        match (boxRect(info.cropBox)) {
            case Some(rect) => return rect
            case None => ()
        }
        match (boxRect(info.mediaBox)) {
            case Some(rect) => rect
            case None => [0.0, 0.0, 612.0, 792.0]
        }
    }

    /** CropBox wins when it parses; otherwise fall back to MediaBox. */
    private func effectiveDimensions(): Option<Array<Float64>> {
        match (boxDimensions(info.cropBox)) {
            case Some(dimensions) => Some(dimensions)
            case None => boxDimensions(info.mediaBox)
        }
    }

    private func boxDimensions(box: Option<PdfValue>): Option<Array<Float64>> {
        match (boxRect(box)) {
            case Some(rect) =>
                let w = if (rect[2] > rect[0]) { rect[2] - rect[0] } else { rect[0] - rect[2] }
                let h = if (rect[3] > rect[1]) { rect[3] - rect[1] } else { rect[1] - rect[3] }
                Some([w, h])
            case None => None
        }
    }

    private func boxRect(box: Option<PdfValue>): Option<Array<Float64>> {
        let value = match (box) {
            case Some(item) => document.resolve(item)
            case None => return None
        }
        let items = match (value) {
            case PdfValue.PdfArray(entries) => entries
            case _ => return None
        }
        if (items.size < 4) {
            return None
        }
        let numbers = ArrayList<Float64>()
        for (i in 0..4) {
            let resolved = document.resolve(items[i])
            let number = match (resolved) {
                case PdfValue.PdfInt(n) => Float64(n)
                case PdfValue.PdfReal(f) => f
                case _ => return None
            }
            numbers.add(number)
        }
        Some(numbers.toArray())
    }
}
