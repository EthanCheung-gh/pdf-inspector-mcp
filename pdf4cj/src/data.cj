package pdf4cj

import std.collection.*

/**
 * Shared data types for the extraction layer.
 *
 * This file is deliberately *only* the data model: the content-stream
 * interpreter, font decoder and table finder that fill these objects are
 * separate work items. The field layout and the constructors below are the
 * contract those workers code against, so keep them stable.
 *
 * Coordinate conventions:
 * - `chars`, `words`, `rects`, `lines`, `curves` and `images` use PDF user
 *   space: origin at the bottom-left, y grows upwards, matching pdfplumber's
 *   `x0`/`top`/`bottom` conventions *before* its top flip.
 * - `tables` use pdfplumber's top-based coordinates:
 *   `y0 = pageHeight - yMaxPdf`, `y1 = pageHeight - yMinPdf`.
 */
public enum PdfColor {
    | Gray(Float64)
    | Rgb(Float64, Float64, Float64)
    | Cmyk(Float64, Float64, Float64, Float64)
    | Named(String)
}

/** One glyph (or glyph cluster) placed on a page, in PDF user space. */
public class CharObj {
    public var text: String
    public var x0: Float64
    public var y0: Float64
    public var x1: Float64
    public var y1: Float64
    public var fontname: String
    public var size: Float64
    public var color: PdfColor
    public var page: Int64

    public init(
        text!: String = "",
        x0!: Float64 = 0.0,
        y0!: Float64 = 0.0,
        x1!: Float64 = 0.0,
        y1!: Float64 = 0.0,
        fontname!: String = "",
        size!: Float64 = 0.0,
        color!: PdfColor = PdfColor.Named("black"),
        page!: Int64 = 0
    ) {
        this.text = text
        this.x0 = x0
        this.y0 = y0
        this.x1 = x1
        this.y1 = y1
        this.fontname = fontname
        this.size = size
        this.color = color
        this.page = page
    }
}

/** A run of characters that the word splitter considered one word. */
public class WordObj {
    public var text: String
    public var x0: Float64
    public var y0: Float64
    public var x1: Float64
    public var y1: Float64
    public var fontname: String
    public var size: Float64
    public var page: Int64

    public init(
        text!: String = "",
        x0!: Float64 = 0.0,
        y0!: Float64 = 0.0,
        x1!: Float64 = 0.0,
        y1!: Float64 = 0.0,
        fontname!: String = "",
        size!: Float64 = 0.0,
        page!: Int64 = 0
    ) {
        this.text = text
        this.x0 = x0
        this.y0 = y0
        this.x1 = x1
        this.y1 = y1
        this.fontname = fontname
        this.size = size
        this.page = page
    }
}

/** A filled and/or stroked rectangle. */
public class RectObj {
    public var x0: Float64
    public var y0: Float64
    public var x1: Float64
    public var y1: Float64
    public var fill: Bool
    public var stroke: Bool
    public var color: PdfColor
    public var width: Float64
    public var page: Int64

    public init(
        x0!: Float64 = 0.0,
        y0!: Float64 = 0.0,
        x1!: Float64 = 0.0,
        y1!: Float64 = 0.0,
        fill!: Bool = false,
        stroke!: Bool = false,
        color!: PdfColor = PdfColor.Named("black"),
        width!: Float64 = 0.0,
        page!: Int64 = 0
    ) {
        this.x0 = x0
        this.y0 = y0
        this.x1 = x1
        this.y1 = y1
        this.fill = fill
        this.stroke = stroke
        this.color = color
        this.width = width
        this.page = page
    }
}

/** A straight stroked line. */
public class LineObj {
    public var x0: Float64
    public var y0: Float64
    public var x1: Float64
    public var y1: Float64
    public var stroke: Bool
    public var color: PdfColor
    public var width: Float64
    public var page: Int64

    public init(
        x0!: Float64 = 0.0,
        y0!: Float64 = 0.0,
        x1!: Float64 = 0.0,
        y1!: Float64 = 0.0,
        stroke!: Bool = true,
        color!: PdfColor = PdfColor.Named("black"),
        width!: Float64 = 0.0,
        page!: Int64 = 0
    ) {
        this.x0 = x0
        this.y0 = y0
        this.x1 = x1
        this.y1 = y1
        this.stroke = stroke
        this.color = color
        this.width = width
        this.page = page
    }
}

/** A Bezier curve; `points` holds the control points as `[x, y]` pairs. */
public class CurveObj {
    public var x0: Float64
    public var y0: Float64
    public var x1: Float64
    public var y1: Float64
    public var points: Array<Array<Float64>>
    public var stroke: Bool
    public var page: Int64

    public init(
        x0!: Float64 = 0.0,
        y0!: Float64 = 0.0,
        x1!: Float64 = 0.0,
        y1!: Float64 = 0.0,
        points!: Array<Array<Float64>> = Array<Array<Float64>>(),
        stroke!: Bool = true,
        page!: Int64 = 0
    ) {
        this.x0 = x0
        this.y0 = y0
        this.x1 = x1
        this.y1 = y1
        this.points = points
        this.stroke = stroke
        this.page = page
    }
}

/**
 * An image XObject drawn on the page.
 *
 * `streamId` is a stable identifier for the image within its page, so a caller
 * that wants the bytes later can name them without re-walking the document;
 * `imageData` is the internal handle (raw payload, never serialised into output).
 * `imageStream` keeps the underlying stream dictionary so [imagePayload] can pick
 * a decoder without re-walking the page.
 */
public class ImageObj {
    public var x0: Float64
    public var y0: Float64
    public var x1: Float64
    public var y1: Float64
    public var width: Float64
    public var height: Float64
    public var streamId: String
    public var format: String
    public var page: Int64
    public var imageData: Option<Array<UInt8>>
    public var imageStream: Option<PdfStream>

    public init(
        x0!: Float64 = 0.0,
        y0!: Float64 = 0.0,
        x1!: Float64 = 0.0,
        y1!: Float64 = 0.0,
        width!: Float64 = 0.0,
        height!: Float64 = 0.0,
        streamId!: String = "",
        format!: String = "",
        page!: Int64 = 0,
        imageData!: Option<Array<UInt8>> = None,
        imageStream!: Option<PdfStream> = None
    ) {
        this.x0 = x0
        this.y0 = y0
        this.x1 = x1
        this.y1 = y1
        this.width = width
        this.height = height
        this.streamId = streamId
        this.format = format
        this.page = page
        this.imageData = imageData
        this.imageStream = imageStream
    }
}

/** A detected table. Row/column bounds and cell strings are already final. */
public class TableObj {
    public var x0: Float64
    public var y0: Float64
    public var x1: Float64
    public var y1: Float64
    public var rows: Int64
    public var cols: Int64
    public var cells: Array<Array<String>>
    public var page: Int64

    public init(
        x0!: Float64 = 0.0,
        y0!: Float64 = 0.0,
        x1!: Float64 = 0.0,
        y1!: Float64 = 0.0,
        rows!: Int64 = 0,
        cols!: Int64 = 0,
        cells!: Array<Array<String>> = Array<Array<String>>(),
        page!: Int64 = 0
    ) {
        this.x0 = x0
        this.y0 = y0
        this.x1 = x1
        this.y1 = y1
        this.rows = rows
        this.cols = cols
        this.cells = cells
        this.page = page
    }
}

/** Everything the extractor produces for one page. */
public class PageData {
    public var width: Float64
    public var height: Float64
    public var chars: ArrayList<CharObj>
    public var words: ArrayList<WordObj>
    public var rects: ArrayList<RectObj>
    public var lines: ArrayList<LineObj>
    public var curves: ArrayList<CurveObj>
    public var images: ArrayList<ImageObj>
    public var tables: ArrayList<TableObj>

    public init(width!: Float64 = 0.0, height!: Float64 = 0.0) {
        this.width = width
        this.height = height
        this.chars = ArrayList<CharObj>()
        this.words = ArrayList<WordObj>()
        this.rects = ArrayList<RectObj>()
        this.lines = ArrayList<LineObj>()
        this.curves = ArrayList<CurveObj>()
        this.images = ArrayList<ImageObj>()
        this.tables = ArrayList<TableObj>()
    }
}

/** Per-font aggregate over every page of a document. */
public class FontStat {
    public var fontname: String
    public var pages: ArrayList<Int64>
    public var charCount: Int64
    public var sizeMin: Float64
    public var sizeMax: Float64
    public var colors: ArrayList<String>

    public init(
        fontname!: String = "",
        pages!: ArrayList<Int64> = ArrayList<Int64>(),
        charCount!: Int64 = 0,
        sizeMin!: Float64 = 0.0,
        sizeMax!: Float64 = 0.0,
        colors!: ArrayList<String> = ArrayList<String>()
    ) {
        this.fontname = fontname
        this.pages = pages
        this.charCount = charCount
        this.sizeMin = sizeMin
        this.sizeMax = sizeMax
        this.colors = colors
    }
}

/** Document-level facts: page count, geometry, encoder version and document info. */
public class PdfMetadata {
    public var pages: Int64
    public var version: String
    public var encrypted: Bool
    public var pageW: Float64
    public var pageH: Float64
    public var title: String
    public var author: String
    public var producer: String
    public var fonts: ArrayList<String>

    public init(
        pages!: Int64 = 0,
        version!: String = "unknown",
        encrypted!: Bool = false,
        pageW!: Float64 = 0.0,
        pageH!: Float64 = 0.0,
        title!: String = "",
        author!: String = "",
        producer!: String = "",
        fonts!: ArrayList<String> = ArrayList<String>()
    ) {
        this.pages = pages
        this.version = version
        this.encrypted = encrypted
        this.pageW = pageW
        this.pageH = pageH
        this.title = title
        this.author = author
        this.producer = producer
        this.fonts = fonts
    }
}
